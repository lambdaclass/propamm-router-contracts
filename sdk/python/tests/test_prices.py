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


# One real Tempest WETH/USDT book from the v2 stream, captured in the same
# Titan snapshot (slot 15445198) as the v1 payload, whose exact rungs were:
#   WETH -> USDT: (5000000000000000, 12155777), (8118883695943608, 19738268)
#   USDT -> WETH: (10000000, 4112431530672673), (17040037, 7007598544262898)
_WETH = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"
_USDT = "0xdac17f958d2ee523a2206206994597c13d831ec7"
_USDC = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
_V2_BOOK = {
    "maker": "Tempest",
    "quoteAddress": "0x00000003f1ec2379e79f58e12ec6c4f51ee92149",
    "token1": "WETH",
    "token2": "USDT",
    "token1Address": _WETH,
    "token2Address": _USDT,
    "bids": [
        {"price": 2431.1554, "cumVolume": 0.005},
        {"price": 2431.155407468359, "cumVolume": 0.008118883695943609},
    ],
    "asks": [
        {"price": 2431.6514270000002, "cumVolume": 0.004112431530672673},
        {"price": 2431.6514270000002, "cumVolume": 0.007007598544262898},
    ],
}


def _rungs(snapshot, pamm, token_in, token_out):
    entry = next(p for p in snapshot.pamms if p.pamm == to_checksum_address(pamm))
    pair = next(
        p
        for p in entry.pairs
        if p.token_in == to_checksum_address(token_in)
        and p.token_out == to_checksum_address(token_out)
    )
    return [(level.amount_in, level.amount_out) for level in pair.order_book]


def test_parse_v2_books_rebuilds_the_v1_base_unit_rungs():
    raw = {"slot": 15445198, "block": 26206152, "ts": 1792166395085440933, "books": [_V2_BOOK]}
    snapshot = parse_price_levels_message(raw)

    assert snapshot.slot == 15445198
    assert snapshot.block_number == 26206152
    assert snapshot.timestamp_ns == 1792166395085440933
    pamm = _V2_BOOK["quoteAddress"]
    # Bids sell token1 for token2; one amount lands 1 wei off v1 (Titan's float).
    assert _rungs(snapshot, pamm, _WETH, _USDT) == [
        (5000000000000000, 12155777),
        (8118883695943609, 19738268),
    ]
    # Asks buy token1 with token2.
    assert _rungs(snapshot, pamm, _USDT, _WETH) == [
        (10000000, 4112431530672673),
        (17040037, 7007598544262898),
    ]
    assert all(level.variant is None for p in snapshot.pamms[0].pairs for level in p.order_book)


def test_parse_v2_books_files_books_under_the_router_venue():
    from propamm.common.pamms import KIPSELI, METRIC

    books = [
        {**_V2_BOOK, "quoteAddress": "0xc9a956b5196dfe110debe8781857bc8b97d32091"},
        {**_V2_BOOK, "quoteAddress": "0xe844701934d9c6085b292e428f41b911cc0b3872"},
        {**_V2_BOOK, "quoteAddress": "0x30a88bf894d1b806125a23ebf23d715496fd7102"},
    ]
    snapshot = parse_price_levels_message({"books": books})
    # Metric's two quote addresses collapse into one venue, one book per pair.
    assert [p.pamm for p in snapshot.pamms] == [KIPSELI, METRIC]
    assert [len(p.pairs) for p in snapshot.pamms] == [2, 2]


def test_parse_v2_books_skips_unknown_tokens_and_empty_sides():
    unknown = {**_V2_BOOK, "token1Address": "0x6b175474e89094c44da98b954eedeac495271d0f"}
    one_sided = {**_V2_BOOK, "token2Address": _USDC, "bids": []}
    snapshot = parse_price_levels_message({"books": [unknown, one_sided]})

    pairs = snapshot.pamms[0].pairs
    assert [(p.token_in, p.token_out) for p in pairs] == [
        (to_checksum_address(_USDC), to_checksum_address(_WETH))
    ]
    # A caller-supplied decimals table makes the unknown token's book parse.
    with_dai = parse_price_levels_message(
        {"books": [unknown]},
        {"0x6b175474e89094c44da98b954eedeac495271d0f": 18, _USDT: 6},
    )
    assert len(with_dai.pamms[0].pairs) == 2
