"""Thin wrapper around ``AsyncWeb3`` for reading from and writing to contracts.

web3.py does the heavy lifting — contract calls, ABI encode/decode, event
decoding, transaction building/signing. The one thing it doesn't expose is
``eth_call`` with a *block* override (the 4th RPC parameter), which on-chain
quotes need so venues see a matching block context; :meth:`call_with_overrides`
fills that gap with a raw request and re-shapes reverts into :class:`RevertError`.
"""

from __future__ import annotations

from typing import Any

from eth_account.signers.local import LocalAccount
from eth_typing import ChecksumAddress
from eth_utils import to_checksum_address
from web3 import AsyncWeb3
from web3.contract import AsyncContract
from web3.contract.async_contract import AsyncContractFunction

from ._tls import ssl_context
from .common.accounts import account_from_key
from .error import ClientError, RevertError

#: How long ``wait_for_transaction`` polls before giving up, in seconds.
RECEIPT_TIMEOUT_SECONDS = 120


class ContractClient:
    """JSON-RPC contract client.

    Construct read-only with ``ContractClient(rpc_url)`` (quotes and views
    work; sends don't) or signing with ``ContractClient(rpc_url, account=...)``
    / :meth:`connect_with_signer`.
    """

    def __init__(self, rpc_url: str, account: LocalAccount | None = None) -> None:
        # Verify TLS against certifi's CA bundle rather than the (sometimes empty)
        # system store, so an https RPC works regardless of how Python was installed.
        request_kwargs = {"ssl": ssl_context()} if rpc_url.startswith("https") else {}
        self.w3 = AsyncWeb3(AsyncWeb3.AsyncHTTPProvider(rpc_url, request_kwargs=request_kwargs))
        self.account = account

    @classmethod
    def connect(cls, rpc_url: str) -> ContractClient:
        """Read-only client."""
        return cls(rpc_url)

    @classmethod
    def connect_with_signer(cls, rpc_url: str, private_key: str) -> ContractClient:
        """Signing client from a 0x-prefixed (or bare) private key."""
        return cls(rpc_url, account_from_key(private_key))

    @property
    def signer_address(self) -> ChecksumAddress | None:
        """Address of the configured signer, if any."""
        return self.account.address if self.account else None

    def contract(self, address: str, abi: list) -> AsyncContract:
        """A web3 contract bound to ``address`` and ``abi``."""
        return self.w3.eth.contract(address=to_checksum_address(address), abi=abi)

    async def call_with_overrides(
        self,
        function: AsyncContractFunction,
        *,
        state_override: dict[str, Any] | None = None,
        block_number: int | None = None,
        block_timestamp: int | None = None,
    ) -> bytes:
        """``eth_call`` a function with state and/or block overrides; return raw data.

        web3's ``ContractFunction.call`` supports state overrides but not block
        overrides, so this issues the raw request. The caller decodes the
        result with the function's ABI.
        """
        tx: dict[str, Any] = {
            "to": function.address,
            "data": function._encode_transaction_data(),
        }
        if self.signer_address is not None:
            tx["from"] = self.signer_address

        params: list[Any] = [tx, "latest"]
        block_overrides: dict[str, str] = {}
        if block_number is not None:
            block_overrides["number"] = hex(block_number)
        if block_timestamp is not None:
            block_overrides["time"] = hex(block_timestamp)
        if block_overrides:
            params.extend([state_override or {}, block_overrides])
        elif state_override:
            params.append(state_override)

        response = await self.w3.provider.make_request("eth_call", params)
        if response.get("error"):
            raise _revert_from_rpc_error(response["error"])
        result = response.get("result")
        if result is None:
            raise ClientError("eth_call returned no result")
        return bytes(self.w3.to_bytes(hexstr=result))

    async def send(self, function: AsyncContractFunction, value: int | None = None) -> str:
        """Build, sign, and send ``function`` as a transaction. Returns the tx hash.

        web3 fills nonce, gas, fees, and chain id via ``build_transaction``.
        """
        if self.account is None:
            raise ClientError("ContractClient was created without a signer; sends are unavailable")
        # web3 fills gas, fees, and chain id in `build_transaction`, but not the
        # nonce — supply it ourselves (pending, so back-to-back sends don't collide).
        nonce = await self.w3.eth.get_transaction_count(self.account.address, "pending")
        tx = await function.build_transaction(
            {"from": self.account.address, "value": value or 0, "nonce": nonce}
        )
        signed = self.account.sign_transaction(tx)
        raw = getattr(signed, "raw_transaction", None) or signed.rawTransaction
        return self.w3.to_hex(await self.w3.eth.send_raw_transaction(raw))

    async def wait_for_transaction(self, tx_hash: str) -> Any:
        """Wait until a transaction is mined and return its receipt."""
        return await self.w3.eth.wait_for_transaction_receipt(
            tx_hash, timeout=RECEIPT_TIMEOUT_SECONDS
        )


def _revert_from_rpc_error(error: dict[str, Any]) -> RevertError:
    """Re-shape a JSON-RPC ``error`` object into a :class:`RevertError`.

    The revert payload arrives in ``error.data`` (a hex string, sometimes
    nested) on reverts; recover it so the router can name the custom error.
    """
    message = error.get("message", "execution reverted")
    raw = error.get("data")
    if isinstance(raw, dict):
        raw = raw.get("data") or raw.get("result")
    data: bytes | None = None
    if isinstance(raw, str) and raw.startswith("0x") and len(raw) > 2:
        try:
            data = bytes.fromhex(raw[2:])
        except ValueError:
            data = None
    return RevertError(message, data)
