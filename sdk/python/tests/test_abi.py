"""Tests for the router ABI surface and custom-error naming."""

from __future__ import annotations

from eth_utils import function_signature_to_4byte_selector

from propamm.router import abi


def _u256(n: int) -> bytes:
    return n.to_bytes(32, "big")


def test_router_abi_loads_with_the_expected_entrypoints():
    names = {entry["name"] for entry in abi.ROUTER_ABI if entry.get("type") == "function"}
    assert {"swapV1", "swapWithFeeV1", "quoteV1", "quoteSelectedVenuesV1", "paused"} <= names


def test_name_error_names_narrow_width_custom_errors():
    fallback = function_signature_to_4byte_selector("InvalidFallbackFee(uint24)") + _u256(3000)
    assert abi.name_error(fallback) == "InvalidFallbackFee(3000)"

    fee = (
        function_signature_to_4byte_selector("FeeBpsTooHigh(uint16,uint16)")
        + _u256(150)
        + _u256(100)
    )
    assert abi.name_error(fee) == "FeeBpsTooHigh(150, 100)"


def test_name_error_handles_zero_arg_errors():
    expired = function_signature_to_4byte_selector("Expired()")
    assert abi.name_error(expired) == "Expired()"


def test_name_error_returns_none_for_unknown_or_short_payloads():
    assert abi.name_error(bytes([0xDE, 0xAD, 0xBE, 0xEF])) is None
    assert abi.name_error(b"\x00\x00") is None
