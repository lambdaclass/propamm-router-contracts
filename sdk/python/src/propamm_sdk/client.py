"""Thin wrapper around ``AsyncWeb3`` for reading from and writing to contracts.

This module owns the JSON-RPC transport, including ``eth_call`` simulations
with state and block overrides; ABI encoding/decoding lives in ``router.abi``.

``eth_call`` with a block override (the 4th RPC parameter) is not exposed by
web3.py's ``eth.call``, so override-carrying calls go through a raw
``make_request`` and decode/handle errors here. Reverts are re-shaped into
:class:`RevertError` carrying the raw payload so the router bindings can decode
named contract errors from it.
"""

from __future__ import annotations

from typing import Any

from eth_account.signers.local import LocalAccount
from eth_typing import ChecksumAddress
from eth_utils import to_checksum_address
from web3 import AsyncWeb3

from .common.accounts import account_from_key
from .error import ClientError, RevertError

#: How long ``wait_for_transaction`` polls before giving up, in seconds.
RECEIPT_TIMEOUT_SECONDS = 120


def _to_0x(data: bytes) -> str:
    return "0x" + bytes(data).hex()


class ContractClient:
    """JSON-RPC contract client.

    Construct read-only with ``ContractClient(rpc_url)`` (quotes and views
    work; sends don't) or signing with ``ContractClient(rpc_url, account=...)``
    / :meth:`connect_with_signer`.
    """

    def __init__(self, rpc_url: str, account: LocalAccount | None = None) -> None:
        self.w3 = AsyncWeb3(AsyncWeb3.AsyncHTTPProvider(rpc_url))
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

    async def call(
        self,
        to: str,
        calldata: bytes,
        *,
        value: int | None = None,
        state_override: dict[str, Any] | None = None,
        block_number: int | None = None,
        block_timestamp: int | None = None,
    ) -> bytes:
        """Simulate a call via ``eth_call`` and return its raw return data.

        Optionally applies state and block overrides. Useful for nonpayable
        functions that are effectively queries (e.g. on-chain quotes).
        """
        tx: dict[str, Any] = {"to": to_checksum_address(to), "data": _to_0x(calldata)}
        if self.signer_address is not None:
            tx["from"] = self.signer_address
        if value is not None:
            tx["value"] = hex(value)

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
        return bytes.fromhex(result[2:] if result.startswith("0x") else result)

    async def send(self, to: str, calldata: bytes, value: int | None = None) -> str:
        """Sign and send a contract call as an EIP-1559 transaction.

        Gas and nonce are filled by the node. Returns the transaction hash.
        """
        if self.account is None:
            raise ClientError(
                "ContractClient was created without a signer; sends are unavailable"
            )

        sender = self.account.address
        tx: dict[str, Any] = {
            "to": to_checksum_address(to),
            "from": sender,
            "data": _to_0x(calldata),
            "value": value or 0,
            "nonce": await self.w3.eth.get_transaction_count(sender),
            "chainId": await self.w3.eth.chain_id,
        }

        latest = await self.w3.eth.get_block("latest")
        base_fee = latest.get("baseFeePerGas")
        if base_fee is not None:
            priority_fee = await self.w3.eth.max_priority_fee
            tx["type"] = 2
            tx["maxPriorityFeePerGas"] = priority_fee
            tx["maxFeePerGas"] = base_fee * 2 + priority_fee
        else:
            tx["gasPrice"] = await self.w3.eth.gas_price

        tx["gas"] = await self.w3.eth.estimate_gas(tx)

        signed = self.account.sign_transaction(tx)
        raw = getattr(signed, "raw_transaction", None) or signed.rawTransaction
        tx_hash = await self.w3.eth.send_raw_transaction(raw)
        return self.w3.to_hex(tx_hash)

    async def wait_for_transaction(self, tx_hash: str) -> Any:
        """Wait until a transaction is mined and return its receipt."""
        return await self.w3.eth.wait_for_transaction_receipt(
            tx_hash, timeout=RECEIPT_TIMEOUT_SECONDS
        )


def _revert_from_rpc_error(error: dict[str, Any]) -> RevertError:
    """Re-shape a JSON-RPC ``error`` object into a :class:`RevertError`.

    The revert payload arrives in ``error.data`` (a hex string, sometimes
    nested) on reverts; recover it so the router can decode named errors.
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
