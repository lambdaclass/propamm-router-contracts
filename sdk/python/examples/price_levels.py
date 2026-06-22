"""pAMM price levels: Titan's pre-quoted prices for a range of trade sizes.

Grouped per pAMM and served from Titan's latest snapshot over HTTP (no node
RPC, no key), unlike `router.quote`, which runs an on-chain `eth_call`.

Install the SDK first, then run:

    pip install -e .
    python3 examples/price_levels.py

Set PRICE_LEVELS_URL to use a specific HTTP endpoint.
"""

from __future__ import annotations

import asyncio
import os

from propamm import PriceLevels, PriceLevelsRpcSource
from propamm.common.helpers import format_units, parse_address
from propamm.common.pamms import PAMMS
from propamm.common.tokens import USDC, USDT, WETH

# Known tokens, for readable amounts. Unknown tokens print raw (0 decimals).
_WBTC = parse_address("0x2260fac5e5542a773aa44fbcfedf7c193bc2c599")
_TOKENS = {USDC: ("USDC", 6), USDT: ("USDT", 6), WETH: ("WETH", 18), _WBTC: ("WBTC", 8)}
# Venue address -> readable pAMM name.
_VENUE_NAMES = {address: name for name, address in PAMMS.items()}


def _token_info(token: str) -> tuple[str, int]:
    return _TOKENS.get(token, (token, 0))


def _fmt(amount: int, token: str) -> str:
    symbol, decimals = _token_info(token)
    return f"{format_units(amount, decimals)} {symbol}"


def _venue_name(address: str) -> str:
    return _VENUE_NAMES.get(address, address)


async def main() -> None:
    # PriceLevels defaults to a one-shot HTTP snapshot source. Set
    # PRICE_LEVELS_URL to point snapshots and quotes at a specific endpoint.
    url = os.getenv("PRICE_LEVELS_URL")
    prices = PriceLevels(PriceLevelsRpcSource(url)) if url else PriceLevels()

    # 1. Full snapshot: every pAMM's order book.
    snapshot = await prices.get_price_levels()
    block = snapshot.block_number if snapshot.block_number is not None else "?"
    print(f"snapshot @ block {block} — {len(snapshot.pamms)} pAMM(s)")

    # Pick the first pAMM/pair that carries an order book to display.
    chosen = next(
        (
            (entry.pamm, pair)
            for entry in snapshot.pamms
            for pair in entry.pairs
            if pair.order_book
        ),
        None,
    )
    if chosen is None:
        raise SystemExit("snapshot carried no order books")
    pamm, pair = chosen

    print(
        f"\n{_venue_name(pamm)} order book: "
        f"{_token_info(pair.token_in)[0]} -> {_token_info(pair.token_out)[0]}"
    )
    for level in pair.order_book:
        print(
            f"  {_fmt(level.amount_in, pair.token_in)} -> "
            f"{_fmt(level.amount_out, pair.token_out)}  [{level.variant}]"
        )

    # 2. Quote helpers, for that pair and a mid-ladder size. `get_quote` returns
    # the best across all pAMMs; `get_quote_venue` pins to one.
    size = pair.order_book[len(pair.order_book) // 2].amount_in

    best = await prices.get_quote(pair.token_in, pair.token_out, size)
    print(
        f"\nbest quote:  {_fmt(best.amount_in, best.token_in)} -> "
        f"{_fmt(best.amount_out, best.token_out)} via {_venue_name(best.pamm)}"
    )

    pinned = await prices.get_quote_venue(pamm, pair.token_in, pair.token_out, size)
    print(
        f"{_venue_name(pamm)} quote: {_fmt(pinned.amount_in, pinned.token_in)} -> "
        f"{_fmt(pinned.amount_out, pinned.token_out)}"
    )

    await prices.close()


if __name__ == "__main__":
    asyncio.run(main())
