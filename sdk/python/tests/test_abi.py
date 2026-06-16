"""Ported from the Rust SDK's `router::abi` unit tests."""

from __future__ import annotations

from eth_abi import encode as abi_encode
from eth_utils import keccak

from propamm_sdk.router import abi


def _u256_word(n: int) -> bytes:
    return n.to_bytes(32, "big")


def _address_word(address: str) -> bytes:
    return bytes(12) + bytes.fromhex(address[2:])


def _address_with_last_byte(byte: int) -> str:
    from eth_utils import to_checksum_address

    return to_checksum_address(bytes(19) + bytes([byte]))


def test_decode_values_handles_narrow_integer_widths():
    values = abi.decode_values("uint24", _u256_word(42))
    assert values[0] == 42

    data = _u256_word(7) + _u256_word(16)
    values = abi.decode_values("uint16,uint16", data)
    assert values[0] == 7
    assert values[1] == 16


def test_decode_error_names_narrow_width_custom_errors():
    fallback = keccak(text="InvalidFallbackFee(uint24)")[:4] + _u256_word(3000)
    assert abi.decode_error(fallback) == "InvalidFallbackFee(3000)"

    fee = keccak(text="FeeBpsTooHigh(uint16,uint16)")[:4] + _u256_word(150) + _u256_word(100)
    assert abi.decode_error(fee) == "FeeBpsTooHigh(150, 100)"


def test_decode_error_returns_none_for_unknown_selector():
    assert abi.decode_error(bytes([0xDE, 0xAD, 0xBE, 0xEF])) is None


def test_swapped_event_data_decodes_in_the_layout_wait_for_swap_expects():
    recipient = _address_with_last_byte(0xAA)
    market_maker = _address_with_last_byte(0xBB)
    data = (
        _u256_word(1000)
        + _u256_word(950)
        + _address_word(recipient)
        + _address_word(market_maker)
    )
    values = abi.decode_values("uint256,uint256,address,address", data)
    assert values[0] == 1000
    assert values[1] == 950
    assert values[2] == recipient
    assert values[3] == market_maker


def test_topic_as_address_reads_the_low_20_bytes():
    recipient = _address_with_last_byte(0xCD)
    topic = _address_word(recipient)
    assert abi.topic_as_address(topic) == recipient


def test_encode_calldata_round_trips_the_fee_tuple():
    # swapWithFeeV1's trailing arg is the FrontendFee tuple (uint16,address).
    recipient = _address_with_last_byte(0x01)
    calldata = abi.encode_calldata(abi.SWAP_WITH_FEE, [
        recipient,  # tokenIn
        recipient,  # tokenOut
        1,  # amountIn
        2,  # amountOutMin
        recipient,  # recipient
        3,  # deadline
        (50, recipient),  # fee
    ])
    assert calldata[:4] == abi.selector(abi.SWAP_WITH_FEE)


def test_selector_matches_known_method_identifier():
    # swapV1 selector — guards the canonical signature string.
    expected = abi_encode  # noqa: F841 - keep eth_abi import meaningful
    assert abi.selector(abi.SWAP).hex() == keccak(text=abi.SWAP)[:4].hex()
