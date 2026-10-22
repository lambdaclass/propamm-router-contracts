"""Unit tests for the router bindings that need no node.

``get_quotes`` is the one with a trap worth pinning down: it must quote each
venue on its own, because a multi-venue quote goes through
``quoteSelectedVenuesV1``, which falls back to Uniswap and would report every
venue as alive.
"""

from __future__ import annotations

import pytest
from eth_utils import to_checksum_address

from propamm.error import ClientError, RevertError
from propamm.overrides import OverridesSnapshot
from propamm.router import Quote
from propamm.router.bindings import PropAmmRouter, QuoteOptions

TOKEN_IN = to_checksum_address("0x" + "11" * 20)
TOKEN_OUT = to_checksum_address("0x" + "22" * 20)
VENUES = [to_checksum_address("0x" + f"{n:02x}" * 20) for n in (0xAA, 0xBB, 0xCC)]


def _router(outcomes, venues=None):
    """A router whose `quote` replays `outcomes` keyed by venue, recording calls."""
    router = object.__new__(PropAmmRouter)
    snapshot = OverridesSnapshot(block_number=100, timestamp_ns=None, per_pamm={})
    calls = []

    async def get_whitelisted_venues():
        return venues if venues is not None else VENUES

    async def resolve_snapshot(opts):
        return snapshot

    async def quote(token_in, token_out, amount_in, opts=None):
        calls.append(opts)
        outcome = outcomes[opts.venues[0]]
        if isinstance(outcome, Exception):
            raise outcome
        return Quote(amount_out=outcome, venue=opts.venues[0])

    router.get_whitelisted_venues = get_whitelisted_venues
    router._resolve_snapshot = resolve_snapshot
    router.quote = quote
    return router, calls, snapshot


async def test_quotes_each_venue_on_its_own():
    router, calls, _ = _router({v: 10 for v in VENUES})
    await router.get_quotes(TOKEN_IN, TOKEN_OUT, 1)
    assert [opts.venues for opts in calls] == [[v] for v in VENUES]


async def test_all_venues_share_one_snapshot():
    router, calls, snapshot = _router({v: 10 for v in VENUES})
    await router.get_quotes(TOKEN_IN, TOKEN_OUT, 1)
    assert all(opts.overrides is snapshot for opts in calls)


async def test_drops_reverting_venues_and_sorts_by_output():
    router, _, _ = _router(
        {VENUES[0]: 5, VENUES[1]: RevertError("StalePrices()", None), VENUES[2]: 9}
    )
    quotes = await router.get_quotes(TOKEN_IN, TOKEN_OUT, 1)
    assert [(q.venue, q.amount_out) for q in quotes] == [(VENUES[2], 9), (VENUES[0], 5)]


async def test_drops_zero_quotes():
    router, _, _ = _router({VENUES[0]: 0, VENUES[1]: 0, VENUES[2]: 7})
    quotes = await router.get_quotes(TOKEN_IN, TOKEN_OUT, 1)
    assert [q.venue for q in quotes] == [VENUES[2]]


async def test_non_revert_errors_surface():
    """A transport failure must not silently shorten the list."""
    router, _, _ = _router({VENUES[0]: 5, VENUES[1]: ClientError("node down"), VENUES[2]: 9})
    with pytest.raises(ClientError):
        await router.get_quotes(TOKEN_IN, TOKEN_OUT, 1)


async def test_opts_venues_narrows_the_candidates():
    router, calls, _ = _router({VENUES[0]: 5, VENUES[1]: 6, VENUES[2]: 7})
    await router.get_quotes(TOKEN_IN, TOKEN_OUT, 1, QuoteOptions(venues=[VENUES[1]]))
    assert [opts.venues for opts in calls] == [[VENUES[1]]]
