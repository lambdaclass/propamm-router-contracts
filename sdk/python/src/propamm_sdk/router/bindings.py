"""``PropAMMRouter`` bindings, built on a web3 contract object.

web3 encodes calldata, decodes return values and events, and builds/signs
transactions. Method names drop the on-chain ``V1`` suffix: ``router.swap(...)``
calls ``swapV1``, and so on.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from eth_abi import decode as abi_decode
from eth_typing import ChecksumAddress
from eth_utils import to_checksum_address
from web3.constants import ADDRESS_ZERO
from web3.logs import DISCARD

from ..client import ContractClient
from ..common.tokens import ETH_SENTINEL
from ..error import InvalidInputError, MissingEventError, RevertError, TransactionRevertedError
from ..overrides import (
    OverridesSnapshot,
    OverridesSource,
    OverridesWsSource,
    to_state_override,
)
from .abi import ERC20_ABI, ROUTER_ABI, name_error

#: Maximum frontend fee accepted by the router, in bps.
MAX_FEE_BPS = 100

# Sentinel for "use the router's attached overrides source" (the default).
_ATTACHED = object()


@dataclass
class FrontendFee:
    """Frontend fee skimmed from a swap's output — pass via ``SwapOptions.frontend_fee``."""

    bps: int
    recipient: str


@dataclass
class SwapParams:
    """Common parameters shared by every swap entrypoint."""

    #: Token being sold, or ``ETH_SENTINEL`` for native ETH.
    token_in: str
    #: Token being bought, or ``ETH_SENTINEL`` for native ETH.
    token_out: str
    #: Exact amount of ``token_in`` to sell, in atomic units.
    amount_in: int
    #: Minimum acceptable amount of ``token_out`` (net of the frontend fee, when one is passed).
    amount_out_min: int
    #: Address that receives ``token_out``.
    recipient: str
    #: Unix timestamp after which the swap is no longer valid (see ``deadline_in``).
    deadline: int

    def _values(self) -> list:
        return [
            self.token_in,
            self.token_out,
            self.amount_in,
            self.amount_out_min,
            self.recipient,
            self.deadline,
        ]


@dataclass
class Quote:
    """Result of an on-chain quote: best output and the venue that produced it."""

    amount_out: int
    venue: ChecksumAddress


@dataclass
class FeeCharged:
    """Frontend fee actually charged by a swap."""

    recipient: ChecksumAddress
    amount: int


@dataclass
class SwapResult:
    """Decoded outcome of a mined swap (from the ``Swapped`` event)."""

    hash: str
    receipt: Any
    amount_in: int
    amount_out: int
    #: The venue that filled, or the Uniswap fallback router address.
    executed_venue: ChecksumAddress
    recipient: ChecksumAddress
    #: Present when the swap charged a frontend fee (``FrontendFeeCharged``).
    fee: FeeCharged | None = None


@dataclass
class QuoteOptions:
    """Per-call quote options; defaults mirror the plain :meth:`PropAmmRouter.quote`."""

    #: Override source for this call: the default uses the router's attached
    #: source; ``None`` quotes without overrides; an ``OverridesSource`` or a
    #: fixed ``OverridesSnapshot`` overrides just this call.
    overrides: Any = _ATTACHED
    #: Inject the Bebop default slot when no Bebop entry is present.
    bebop_default: bool = True
    #: Restrict the quote to these venues: a single entry quotes that venue
    #: directly, several pick the best among them. Must be non-empty when
    #: present; ``None`` quotes across every whitelisted venue.
    venues: list[str] | None = None


@dataclass
class SwapOptions:
    """Per-swap options; defaults mirror the plain :meth:`PropAmmRouter.swap`."""

    #: Restrict the swap to these venues (same semantics as ``QuoteOptions.venues``).
    venues: list[str] | None = None
    #: Optional frontend fee skimmed from the output; routes through the
    #: contract's ``WithFee`` selector (validated before sending).
    frontend_fee: FrontendFee | None = None


# Quote function name per venue-restriction mode.
_QUOTE_FUNCS = {
    "all": "quoteV1",
    "single": "quoteVenueV1",
    "selected": "quoteSelectedVenuesV1",
}

# Swap function names (plain / frontend-fee) per venue-restriction mode.
_SWAP_FUNCS = {
    "all": ("swapV1", "swapWithFeeV1"),
    "single": ("swapViaVenueV1", "swapViaVenueWithFeeV1"),
    "selected": ("swapViaSelectedVenuesV1", "swapViaSelectedVenuesWithFeeV1"),
}


class PropAmmRouter:
    """Typed ``PropAMMRouter`` bindings.

    Quotes apply pAMM state overrides from the attached source by default (a
    streaming :class:`OverridesWsSource` unless one is provided).
    """

    def __init__(
        self,
        client: ContractClient,
        address: str,
        overrides: OverridesSource | None = None,
    ) -> None:
        self.client = client
        self.address = to_checksum_address(address)
        self.overrides: OverridesSource = overrides or OverridesWsSource()
        self._contract = client.contract(self.address, ROUTER_ABI)

    # ------ Quotes ------
    # The quote functions are nonpayable on-chain, so they go through
    # `eth_call` simulation. By default the simulation carries the latest pAMM
    # state overrides (plus their block number/timestamp) so venues quote fresh
    # off-chain liquidity — and that block override is the one thing web3's
    # `.call()` can't do, so override-carrying quotes go through the raw path.

    async def quote(
        self,
        token_in: str,
        token_out: str,
        amount_in: int,
        opts: QuoteOptions | None = None,
    ) -> Quote:
        """Best quote across all whitelisted venues and the Uniswap V3 fallback.

        ``opts.venues`` restricts the quote; restricted quotes fall back to the
        Uniswap V3 quote (reporting the fallback router as ``venue``) when no
        listed venue can be priced.
        """
        opts = opts or QuoteOptions()
        mode, venue_args = _venue_dispatch(opts.venues)
        function = getattr(self._contract.functions, _QUOTE_FUNCS[mode])(
            *venue_args, token_in, token_out, amount_in
        )
        overrides = await self._resolve_overrides(opts)
        if overrides is None:
            amount_out, venue = await function.call()
        else:
            try:
                raw = await self.client.call_with_overrides(function, **overrides)
            except RevertError as error:
                raise _named_revert(error) from error
            amount_out, venue = abi_decode(["uint256", "address"], raw)
        return Quote(amount_out=amount_out, venue=to_checksum_address(venue))

    # ------ Swaps ------
    # ETH input: when `token_in` is `ETH_SENTINEL` the router expects
    # `msg.value == amount_in`; the bindings attach it automatically. ERC-20
    # input requires a prior allowance for the router (see `approve`).

    async def swap(self, params: SwapParams, opts: SwapOptions | None = None) -> str:
        """Swap through the best-quoting venue, or through ``opts.venues`` only.

        ``opts.frontend_fee`` routes the call through the contract's ``WithFee``
        selector, which skims the fee from the output.
        """
        opts = opts or SwapOptions()
        mode, venue_args = _venue_dispatch(opts.venues)
        args = [*venue_args, *params._values()]

        fee = opts.frontend_fee
        if fee is not None:
            _validate_fee(fee)
            # The `WithFee` selectors take the same tuple plus the fee struct last.
            args.append((fee.bps, to_checksum_address(fee.recipient)))

        plain, with_fee = _SWAP_FUNCS[mode]
        function = getattr(self._contract.functions, with_fee if fee else plain)(*args)
        # Native-ETH input is signalled by the sentinel and paid via msg.value.
        value = params.amount_in if _eq(params.token_in, ETH_SENTINEL) else None
        return await self.client.send(function, value)

    async def swap_and_wait(
        self, params: SwapParams, opts: SwapOptions | None = None
    ) -> SwapResult:
        """Same as :meth:`swap`, but waits for the receipt and decodes the result."""
        return await self.wait_for_swap(await self.swap(params, opts))

    async def wait_for_swap(self, tx_hash: str) -> SwapResult:
        """Wait until a swap is mined and decode its outcome from the router's events.

        Decodes ``Swapped`` (and, when present, ``FrontendFeeCharged``). Raises
        if the transaction reverted or emitted no ``Swapped`` event.
        """
        receipt = await self.client.wait_for_transaction(tx_hash)
        if receipt["status"] != 1:
            raise TransactionRevertedError(tx_hash, receipt)

        swapped = self._own_event("Swapped", receipt)
        if swapped is None:
            raise MissingEventError(tx_hash, "Swapped")

        fee_event = self._own_event("FrontendFeeCharged", receipt)
        fee = (
            FeeCharged(
                recipient=to_checksum_address(fee_event["args"]["feeRecipient"]),
                amount=fee_event["args"]["feeAmount"],
            )
            if fee_event is not None
            else None
        )

        args = swapped["args"]
        return SwapResult(
            hash=tx_hash,
            receipt=receipt,
            amount_in=args["amountIn"],
            amount_out=args["amountOut"],
            executed_venue=to_checksum_address(args["marketMaker"]),
            recipient=to_checksum_address(args["recipient"]),
            fee=fee,
        )

    # ------ ERC-20 ------

    async def approve(self, token: str, amount: int) -> str:
        """Approve the router to pull ``amount`` of ``token`` from the signer."""
        erc20 = self.client.contract(token, ERC20_ABI)
        return await self.client.send(erc20.functions.approve(self.address, amount))

    async def allowance(self, token: str, owner: str) -> int:
        """Current router allowance of ``token`` granted by ``owner``."""
        erc20 = self.client.contract(token, ERC20_ABI)
        return await erc20.functions.allowance(to_checksum_address(owner), self.address).call()

    # ------ Views ------

    async def fallback_swap_router(self) -> ChecksumAddress:
        """The Uniswap fallback "venue" address (dynamic router configuration)."""
        return await self._contract.functions.fallbackSwapRouter().call()

    async def fallback_quoter(self) -> ChecksumAddress:
        return await self._contract.functions.fallbackQuoter().call()

    async def fallback_fee(self) -> int:
        return await self._contract.functions.fallbackFee().call()

    async def get_pair_fee(self, token_a: str, token_b: str) -> int:
        """Raw per-pair fee override (0 if unset). Order-independent."""
        return await self._contract.functions.getPairFee(token_a, token_b).call()

    async def resolved_fee(self, token_in: str, token_out: str) -> int:
        """Effective Uniswap V3 fallback tier for a pair (override or global)."""
        return await self._contract.functions.resolvedFee(token_in, token_out).call()

    async def is_whitelisted_venue(self, venue: str) -> bool:
        return await self._contract.functions.isWhitelistedVenue(venue).call()

    async def get_whitelisted_venues(self) -> list[ChecksumAddress]:
        """Every whitelisted propAMM venue (excludes the Uniswap fallback)."""
        return await self._contract.functions.getWhitelistedVenues().call()

    async def paused(self) -> bool:
        return await self._contract.functions.paused().call()

    # ------ Internals ------

    def _own_event(self, name: str, receipt: Any) -> dict | None:
        """First log of ``name`` emitted by this router (web3 decodes the args)."""
        events = getattr(self._contract.events, name)().process_receipt(receipt, errors=DISCARD)
        return next((ev for ev in events if _eq(ev["address"], self.address)), None)

    async def _resolve_overrides(self, opts: QuoteOptions) -> dict[str, Any] | None:
        """Resolve a quote's override options into ``eth_call`` override kwargs.

        Returns ``None`` when no overrides apply (the quote runs via web3's
        plain ``.call()``). The snapshot's block number and timestamp are
        attached only alongside overrides — venues revert when the simulated
        block context doesn't match their pushed state.
        """
        chosen = opts.overrides
        if chosen is None:
            return None
        if chosen is _ATTACHED:
            snapshot = await self.overrides.get_overrides()
        elif isinstance(chosen, OverridesSource):
            snapshot = await chosen.get_overrides()
        elif isinstance(chosen, OverridesSnapshot):
            snapshot = chosen
        else:
            snapshot = await self.overrides.get_overrides()

        if snapshot is None:
            return None
        state = to_state_override(snapshot, bebop_default=opts.bebop_default)
        if not state:
            return None

        overrides: dict[str, Any] = {"state_override": state, "block_number": snapshot.block_number}
        if snapshot.timestamp_ns is not None:
            overrides["block_timestamp"] = snapshot.timestamp_ns // 1_000_000_000
        return overrides


def _venue_dispatch(venues: list[str] | None) -> tuple[str, list]:
    """Resolve a venue restriction into the selector mode and its leading args.

    A single venue targets the direct ``Venue`` entrypoint, several the
    ``SelectedVenues`` one. Empty restrictions raise — omit ``venues`` instead.
    """
    if venues is None:
        return "all", []
    if len(venues) == 0:
        raise InvalidInputError("venues must not be empty — omit it to use every whitelisted venue")
    if len(venues) == 1:
        return "single", [to_checksum_address(venues[0])]
    return "selected", [[to_checksum_address(v) for v in venues]]


def _validate_fee(fee: FrontendFee) -> None:
    """Raises unless the fee has bps in [1, MAX_FEE_BPS] and a non-zero recipient."""
    if not isinstance(fee.bps, int) or fee.bps < 1 or fee.bps > MAX_FEE_BPS:
        raise InvalidInputError(f"fee bps must be an integer in [1, {MAX_FEE_BPS}], got {fee.bps}")
    if fee.recipient.lower() == ADDRESS_ZERO:
        raise InvalidInputError("fee recipient must not be the zero address")


def _named_revert(error: RevertError) -> RevertError:
    """Name a raw-path revert against the contract's custom errors, if possible."""
    if error.data is None:
        return error
    named = name_error(error.data)
    if named is None:
        return error
    return RevertError(f"{error.message} ({named})", error.data)


def _eq(a: str, b: str) -> bool:
    return a.lower() == b.lower()
