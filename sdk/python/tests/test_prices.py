"""Unit tests for pAMM price-level parsing."""

from __future__ import annotations

import pytest
from eth_utils import to_checksum_address

from propamm.error import PricesError
from propamm.prices import (
    _extract_rpc_result,
    _parse_titan_quote,
    parse_price_levels_message,
)


def test_parse_price_levels_message_extracts_pamms_pairs_and_rungs():
    pamm = "0x5979458912f80b96d30d4220af8e2e4925a33320"
    token_in = "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599"
    token_out = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    raw = {
        "slot": 14_581_462,
        "blockNumber": 25_345_763,
        "timestamp": 1_781_801_564_588_230_787,
        "pamms": [
            {
                "pamm": pamm,
                "pairs": [
                    {
                        "tokenIn": token_in,
                        "tokenOut": token_out,
                        "orderBook": [
                            {
                                "amountIn": "0x989680",
                                "amountOut": "0x174b67393",
                                "variant": "Simulated",
                            },
                            {
                                "amountIn": "0xaa810a",
                                "amountOut": "0x1a0781260",
                                "variant": "Interpolated",
                            },
                        ],
                    }
                ],
            }
        ],
    }

    snapshot = parse_price_levels_message(raw)
    assert snapshot.block_number == 25_345_763
    assert snapshot.slot == 14_581_462
    assert snapshot.timestamp_ns == 1_781_801_564_588_230_787
    assert len(snapshot.pamms) == 1

    entry = snapshot.pamms[0]
    assert entry.pamm == to_checksum_address(pamm)
    assert len(entry.pairs) == 1

    pair = entry.pairs[0]
    assert pair.token_in == to_checksum_address(token_in)
    assert pair.token_out == to_checksum_address(token_out)
    assert len(pair.order_book) == 2
    assert pair.order_book[0].amount_in == 0x989680
    assert pair.order_book[0].amount_out == 0x174B67393
    assert pair.order_book[0].variant == "Simulated"
    assert pair.order_book[1].variant == "Interpolated"


def test_parse_price_levels_message_drops_unknown_variants_and_malformed_rungs():
    raw = {
        "pamms": [
            {
                "pamm": "0x0000000000000000000000000000000000000abc",
                "pairs": [
                    {
                        "tokenIn": "0x0000000000000000000000000000000000000011",
                        "tokenOut": "0x0000000000000000000000000000000000000022",
                        "orderBook": [
                            {"amountIn": "0x1", "amountOut": "0x2", "variant": "Bogus"},
                            {"amountIn": "0x3", "variant": "Simulated"},  # missing amountOut
                            {"amountIn": "0x4", "amountOut": "0x5", "variant": "Simulated"},
                        ],
                    }
                ],
            }
        ],
    }
    snapshot = parse_price_levels_message(raw)
    book = snapshot.pamms[0].pairs[0].order_book
    # Only the one well-formed, known-variant rung survives.
    assert len(book) == 1
    assert book[0].amount_in == 4


def test_parse_price_levels_message_tolerates_missing_pamms():
    snapshot = parse_price_levels_message({"slot": 1})
    assert snapshot.pamms == []
    assert snapshot.slot == 1


def test_parse_price_levels_message_rejects_non_object():
    with pytest.raises(PricesError):
        parse_price_levels_message([1, 2, 3])


def test_parse_titan_quote_parses_a_full_result():
    raw = {
        "tokenIn": "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599",
        "tokenOut": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        "amountIn": "0xde0b6b3a7640000",
        "amountOut": "0xd09dc300",
        "pamm": "0x5979458912f80b96d30d4220af8e2e4925a33320",
        "router": "0x4ddf368080cd7946db5b459ad591c350158175e1",
        "blockNumber": 25_051_224,
        "slot": 14_285_824,
        "timestamp": 1_778_253_913_749_564_761,
    }
    quote = _parse_titan_quote(raw)
    assert quote.amount_in == 10**18
    assert quote.amount_out == 0xD09DC300
    assert quote.pamm == to_checksum_address("0x5979458912f80b96d30d4220af8e2e4925a33320")
    assert quote.block_number == 25_051_224
    assert quote.timestamp_ns == 1_778_253_913_749_564_761


def test_parse_titan_quote_fails_when_a_field_is_missing():
    raw = {
        "tokenIn": "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599",
        "tokenOut": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        "amountIn": "0x1",
        # amountOut, pamm, router missing
    }
    with pytest.raises(PricesError, match="missing required fields"):
        _parse_titan_quote(raw)


def test_extract_rpc_result_treats_null_error_as_success():
    body = {"error": None, "result": {"pamms": []}}
    assert _extract_rpc_result(body) == {"pamms": []}


def test_extract_rpc_result_surfaces_a_real_error_object():
    with pytest.raises(PricesError):
        _extract_rpc_result({"error": {"code": -32000, "message": "boom"}})


def test_extract_rpc_result_errors_without_result_or_error():
    with pytest.raises(PricesError, match="neither a result nor an error"):
        _extract_rpc_result({"jsonrpc": "2.0", "id": 1})
