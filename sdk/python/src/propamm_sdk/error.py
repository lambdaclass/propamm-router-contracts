"""Exception hierarchy, mirroring the Rust SDK's ``Error`` enum.

All SDK errors derive from :class:`PropAmmError`, so callers can catch the
whole family with a single ``except``.
"""

from __future__ import annotations


class PropAmmError(Exception):
    """Base class for every error raised by the SDK."""


class ClientError(PropAmmError):
    """JSON-RPC client failure (transport, node errors, tx building/sending)."""


class RevertError(PropAmmError):
    """An ``eth_call`` reverted.

    ``data`` carries the raw revert payload when the node provided one; the
    router bindings decode it into named contract errors.
    """

    def __init__(self, message: str, data: bytes | None = None) -> None:
        super().__init__(f"call reverted: {message}")
        self.message = message
        self.data = data


class TransactionRevertedError(PropAmmError):
    """A mined transaction reverted on-chain.

    Carries the receipt so callers can inspect status, gas, and logs without
    another RPC round-trip.
    """

    def __init__(self, tx_hash: str, receipt: object) -> None:
        super().__init__(f"transaction {tx_hash} reverted")
        self.tx_hash = tx_hash
        self.receipt = receipt


class MissingEventError(PropAmmError):
    """A mined, successful transaction emitted no expected event.

    Usually the wrong router address or ABI drift (e.g. a swap with no
    ``Swapped`` log).
    """

    def __init__(self, tx_hash: str, event: str) -> None:
        super().__init__(f"transaction {tx_hash} emitted no {event} event")
        self.tx_hash = tx_hash
        self.event = event


class AbiError(PropAmmError):
    """ABI encoding/decoding failure."""


class OverridesError(PropAmmError):
    """Failure while fetching or parsing pAMM state overrides."""


class TimeoutError(PropAmmError):  # noqa: A001 - intentional parity with the Rust enum
    """An operation did not complete within its deadline."""


class InvalidInputError(PropAmmError):
    """Invalid caller-supplied input (addresses, fee bounds, keys, URLs, ...)."""
