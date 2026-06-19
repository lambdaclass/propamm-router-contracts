"""Unit tests for the conversion and numeric helpers."""

from __future__ import annotations

import pytest

from propamm.common.helpers import (
    apply_slippage,
    deadline_in,
    format_ether,
    format_units,
    parse_address,
    parse_ether,
    parse_units,
)
from propamm.error import InvalidInputError


def test_apply_slippage_shaves_bps_and_floors_in_the_users_favor():
    # 0.5% off 1_000_000 -> 5_000 fee.
    assert apply_slippage(1_000_000, 50) == 995_000
    # 0 bps is a no-op; the full denominator zeroes the amount.
    assert apply_slippage(123_456, 0) == 123_456
    assert apply_slippage(123_456, 10_000) == 0
    # The fee floors, so the min-out rounds UP (stricter for the user):
    # 10_001 * 1bps = 1.0001 -> fee 1 -> 10_000.
    assert apply_slippage(10_001, 1) == 10_000


def test_apply_slippage_rejects_bps_above_denominator():
    with pytest.raises(InvalidInputError):
        apply_slippage(1, 10_001)


def test_apply_slippage_does_not_overflow_for_huge_amounts():
    huge = 2**256 - 1
    out = apply_slippage(huge, 100)
    assert 0 < out < huge


def test_parse_units_handles_integers_fractions_and_leading_zeros():
    assert parse_units("1.5", 6) == 1_500_000
    assert parse_units("1", 6) == 1_000_000
    assert parse_units("0.0015", 6) == 1_500
    assert parse_ether("1") == 10**18


def test_parse_units_rejects_excess_precision():
    with pytest.raises(InvalidInputError):
        parse_units("1.9999995", 6)


def test_format_units_trims_zeros_and_round_trips_parse_units():
    assert format_units(1_500_000, 6) == "1.5"
    assert format_units(1_000_000, 6) == "1"
    assert format_units(1_500, 6) == "0.0015"
    assert format_units(0, 6) == "0"
    assert format_ether(10**18) == "1"
    assert format_units(parse_units("1234.567", 6), 6) == "1234.567"


def test_parse_address_validates_length_and_hex():
    one = "0x0000000000000000000000000000000000000001"
    assert parse_address(one) == one
    # The 0x prefix is optional.
    assert parse_address("0000000000000000000000000000000000000001") == one
    # Wrong length and non-hex are rejected.
    with pytest.raises(InvalidInputError):
        parse_address("0x1234")
    with pytest.raises(InvalidInputError):
        parse_address("0xZZ00000000000000000000000000000000000001")


def test_deadline_in_returns_future_unix_seconds():
    base = deadline_in(0)
    assert base >= 1_700_000_000
    assert deadline_in(1_000) > base
