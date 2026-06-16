"""``PropAMMRouter`` bindings, built on the generic :class:`ContractClient`.

Method names drop the on-chain ``V1`` suffix: ``router.swap(...)`` calls
``swapV1``, and so on.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from eth_typing import ChecksumAddress
from eth_utils import to_checksum_address

from ..client import ContractClient
from ..common.tokens import ETH_SENTINEL
from ..error import InvalidInputError, MissingEventError, RevertError, TransactionRevertedError
from ..overrides import (
    OverridesSnapshot,
    OverridesSource,
    OverridesWsSource,
    to_state_override,
)
from . import abi

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


# Quote selector per venue-restriction mode.
_QUOTE_SELECTORS = {
    "all": abi.QUOTE,
    "single": abi.QUOTE_VENUE,
    "selected": abi.QUOTE_SELECTED_VENUES,
}

# Swap selector pairs (plain / frontend-fee) per venue-restriction mode.
_SWAP_SELECTORS = {
    "all": (abi.SWAP, abi.SWAP_WITH_FEE),
    "single": (abi.SWAP_VIA_VENUE, abi.SWAP_VIA_VENUE_WITH_FEE),
    "selected": (abi.SWAP_VIA_SELECTED_VENUES, abi.SWAP_VIA_SELECTED_VENUES_WITH_FEE),
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

    # ------ Quotes ------
    # The quote functions are nonpayable on-chain, so they go through
    # `ContractClient.call` (eth_call simulation). By default the simulation
    # carries the latest pAMM state overrides (plus their block
    # number/timestamp) so venues quote fresh off-chain liquidity.

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
        args = [*venue_args, token_in, token_out, amount_in]
        overrides = await self._resolve_overrides(opts)
        data = await self._call_router(_QUOTE_SELECTORS[mode], args, overrides)
        amount_out, venue = abi.decode_values("uint256,address", data)
        return Quote(amount_out=amount_out, venue=venue)

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

        plain, with_fee = _SWAP_SELECTORS[mode]
        signature = with_fee if fee is not None else plain
        # Native-ETH input is signalled by the sentinel and paid via msg.value.
        value = params.amount_in if _eq(params.token_in, ETH_SENTINEL) else None
        return await self.client.send(self.address, abi.encode_calldata(signature, args), value)

    async def swap_and_wait(self, params: SwapParams, opts: SwapOptions | None = None) -> SwapResult:
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

        swapped_topic = abi.event_topic(abi.SWAPPED_EVENT)
        fee_topic = abi.event_topic(abi.FRONTEND_FEE_CHARGED_EVENT)

        swapped: tuple[int, int, ChecksumAddress, ChecksumAddress] | None = None
        fee: FeeCharged | None = None
        for log in receipt["logs"]:
            if not _eq(log["address"], self.address):
                continue
            topics = log["topics"]
            if not topics:
                continue
            topic0 = bytes(topics[0])
            if topic0 == swapped_topic and swapped is None:
                # Swapped data fields: (amountIn, amountOut, recipient, marketMaker).
                amount_in, amount_out, recipient, market_maker = abi.decode_values(
                    "uint256,uint256,address,address", bytes(log["data"])
                )
                swapped = (amount_in, amount_out, recipient, market_maker)
            elif topic0 == fee_topic and fee is None and len(topics) > 1:
                # FrontendFeeCharged: feeRecipient is indexed (topic 1),
                # feeAmount is the only data field.
                (amount,) = abi.decode_values("uint256", bytes(log["data"]))
                fee = FeeCharged(recipient=abi.topic_as_address(topics[1]), amount=amount)

        if swapped is None:
            raise MissingEventError(tx_hash, "Swapped")

        amount_in, amount_out, recipient, market_maker = swapped
        return SwapResult(
            hash=tx_hash,
            receipt=receipt,
            amount_in=amount_in,
            amount_out=amount_out,
            executed_venue=market_maker,
            recipient=recipient,
            fee=fee,
        )

    # ------ ERC-20 ------

    async def approve(self, token: str, amount: int) -> str:
        """Approve the router to pull ``amount`` of ``token`` from the signer."""
        calldata = abi.encode_calldata(abi.ERC20_APPROVE, [self.address, amount])
        return await self.client.send(token, calldata)

    async def allowance(self, token: str, owner: str) -> int:
        """Current router allowance of ``token`` granted by ``owner``."""
        calldata = abi.encode_calldata(abi.ERC20_ALLOWANCE, [owner, self.address])
        data = await self.client.call(token, calldata)
        (value,) = abi.decode_values("uint256", data)
        return value

    # ------ Views ------

    async def fallback_swap_router(self) -> ChecksumAddress:
        """The Uniswap fallback "venue" address (dynamic router configuration)."""
        return await self._view_address(abi.FALLBACK_SWAP_ROUTER)

    async def fallback_quoter(self) -> ChecksumAddress:
        return await self._view_address(abi.FALLBACK_QUOTER)

    async def fallback_fee(self) -> int:
        return await self._view_uint(abi.FALLBACK_FEE, "uint24")

    async def get_pair_fee(self, token_a: str, token_b: str) -> int:
        """Raw per-pair fee override (0 if unset). Order-independent."""
        return await self._view_uint(abi.GET_PAIR_FEE, "uint24", [token_a, token_b])

    async def resolved_fee(self, token_in: str, token_out: str) -> int:
        """Effective Uniswap V3 fallback tier for a pair (override or global)."""
        return await self._view_uint(abi.RESOLVED_FEE, "uint24", [token_in, token_out])

    async def is_whitelisted_venue(self, venue: str) -> bool:
        data = await self._call_router(abi.IS_WHITELISTED_VENUE, [venue])
        (value,) = abi.decode_values("bool", data)
        return value

    async def get_whitelisted_venues(self) -> list[ChecksumAddress]:
        """Every whitelisted propAMM venue (excludes the Uniswap fallback)."""
        data = await self._call_router(abi.GET_WHITELISTED_VENUES)
        (venues,) = abi.decode_values("address[]", data)
        return venues

    async def paused(self) -> bool:
        data = await self._call_router(abi.PAUSED)
        (value,) = abi.decode_values("bool", data)
        return value

    # ------ Internals ------

    async def _call_router(
        self,
        signature: str,
        args: list | None = None,
        overrides: dict[str, Any] | None = None,
    ) -> bytes:
        """Encode + ``eth_call`` against the router, decoding reverts into named errors."""
        calldata = abi.encode_calldata(signature, args or [])
        try:
            return await self.client.call(self.address, calldata, **(overrides or {}))
        except RevertError as error:
            raise _decode_revert(error) from error

    async def _view_address(self, signature: str) -> ChecksumAddress:
        data = await self._call_router(signature)
        (value,) = abi.decode_values("address", data)
        return value

    async def _view_uint(self, signature: str, type_name: str, args: list | None = None) -> int:
        data = await self._call_router(signature, args)
        (value,) = abi.decode_values(type_name, data)
        return value

    async def _resolve_overrides(self, opts: QuoteOptions) -> dict[str, Any]:
        """Resolve a quote's override options into ``eth_call`` parameters.

        The snapshot's block number and timestamp are attached only alongside
        overrides — venues revert when the simulated block context doesn't
        match their pushed state.
        """
        chosen = opts.overrides
        if chosen is None:
            return {}
        if chosen is _ATTACHED:
            snapshot = await self.overrides.get_overrides()
        elif isinstance(chosen, OverridesSource):
            snapshot = await chosen.get_overrides()
        elif isinstance(chosen, OverridesSnapshot):
            snapshot = chosen
        else:
            snapshot = await self.overrides.get_overrides()

        if snapshot is None:
            return {}

        state = to_state_override(snapshot, bebop_default=opts.bebop_default)
        if not state:
            return {}

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
        raise InvalidInputError(
            "venues must not be empty — omit it to use every whitelisted venue"
        )
    if len(venues) == 1:
        return "single", [to_checksum_address(venues[0])]
    return "selected", [[to_checksum_address(v) for v in venues]]


def _validate_fee(fee: FrontendFee) -> None:
    """Raises unless the fee has bps in [1, MAX_FEE_BPS] and a non-zero recipient."""
    if not isinstance(fee.bps, int) or fee.bps < 1 or fee.bps > MAX_FEE_BPS:
        raise InvalidInputError(f"fee bps must be an integer in [1, {MAX_FEE_BPS}], got {fee.bps}")
    if int(fee.recipient, 16) == 0:
        raise InvalidInputError("fee recipient must not be the zero address")


def _decode_revert(error: RevertError) -> RevertError:
    """Re-shape a raw revert into the contract's named error when the data matches one."""
    if error.data is None:
        return error
    decoded = abi.decode_error(error.data)
    if decoded is None:
        return error
    return RevertError(f"{error.message} ({decoded})", error.data)


def _eq(a: str, b: str) -> bool:
    return a.lower() == b.lower()
