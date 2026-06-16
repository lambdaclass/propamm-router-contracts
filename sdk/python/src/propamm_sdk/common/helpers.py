"""Decimal/unit conversion and small numeric helpers.

Amounts are plain Python ``int`` (arbitrary precision), so they map directly
onto Solidity ``uint256``.
"""

from __future__ import annotations

import time

from eth_typing import ChecksumAddress
from eth_utils import to_checksum_address

from ..error import InvalidInputError

BPS_DENOMINATOR = 10_000


def apply_slippage(amount: int, bps: int) -> int:
    """Shave ``bps`` basis points off ``amount``.

    E.g. derive ``amount_out_min`` from a quote: ``apply_slippage(quote, 50)``
    accepts up to 0.5% less than quoted. The fee floors, so the min-out rounds
    up (stricter for the user).
    """
    if not isinstance(bps, int) or bps < 0 or bps > BPS_DENOMINATOR:
        raise InvalidInputError(
            f"slippage bps must be an integer in [0, {BPS_DENOMINATOR}], got {bps}"
        )
    fee = (amount * bps) // BPS_DENOMINATOR
    return amount - fee


def deadline_in(seconds: int) -> int:
    """Unix-timestamp deadline ``seconds`` from now, for swap ``deadline`` params."""
    return int(time.time()) + seconds


def parse_address(value: str) -> ChecksumAddress:
    """Parse a 0x-prefixed (or bare) 20-byte hex address into a checksum address."""
    raw = value[2:] if value.startswith(("0x", "0X")) else value
    try:
        data = bytes.fromhex(raw)
    except ValueError as exc:
        raise InvalidInputError(f"invalid address {value}: {exc}") from exc
    if len(data) != 20:
        raise InvalidInputError(f"invalid address {value}: expected 20 bytes, got {len(data)}")
    return to_checksum_address(data)


def parse_units(amount: str, decimals: int) -> int:
    """Parse a decimal amount into atomic units: ``parse_units("1.5", 6)`` -> 1500000."""
    int_part, _, frac_part = amount.partition(".")
    if len(frac_part) > decimals:
        raise InvalidInputError(f"{amount} has more than {decimals} decimal places")

    def _to_int(text: str) -> int:
        if not text.isdigit():
            raise InvalidInputError(f"invalid amount {amount}")
        return int(text)

    value = (_to_int(int_part) if int_part else 0) * (10**decimals)
    if frac_part:
        value += _to_int(frac_part) * (10 ** (decimals - len(frac_part)))
    return value


def format_units(value: int, decimals: int) -> str:
    """Format atomic units as a decimal amount, trimming trailing zeros.

    ``format_units(1500000, 6)`` -> ``"1.5"``.
    """
    scale = 10**decimals
    int_part, frac = divmod(value, scale)
    if frac == 0:
        return str(int_part)
    frac_str = str(frac).rjust(decimals, "0").rstrip("0")
    return f"{int_part}.{frac_str}"


def parse_ether(amount: str) -> int:
    """``parse_units`` with 18 decimals: ``parse_ether("1")`` -> 10**18."""
    return parse_units(amount, 18)


def format_ether(value: int) -> str:
    """``format_units`` with 18 decimals."""
    return format_units(value, 18)
