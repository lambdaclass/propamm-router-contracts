# get_quotes

Every whitelisted venue that actually prices a pair right now, best output
first.

Each venue is quoted on its own through `quoteVenueV1`, which propagates the
venue's revert. Quoting them together would go through
`quoteSelectedVenuesV1`, which falls back to Uniswap and would report every
venue as alive. Venues that revert or quote zero are dropped, so the result
doubles as the venue list for a
[`swap`](/python/router/swap) restricted with `venues` — the gas saving of
skipping the venues that cannot serve the pair.

All venues price against a single overrides snapshot, so their outputs are
comparable; resolving overrides per venue would mix blocks.

```python
async def get_quotes(
    self,
    token_in: str,
    token_out: str,
    amount_in: int,
    opts: QuoteOptions | None = None,
) -> list[Quote]
```

## Usage

::: code-group

```python [example.py]
from propamm.common.helpers import parse_ether
from propamm.common.tokens import ETH_SENTINEL, USDC
from config import router

quotes = await router.get_quotes(ETH_SENTINEL, USDC, parse_ether("1"))
venues = [quote.venue for quote in quotes]

# Swap through only the venues that can serve the pair.
from propamm import SwapOptions, SwapParams

await router.swap(
    SwapParams(
        token_in=ETH_SENTINEL,
        token_out=USDC,
        amount_in=parse_ether("1"),
        amount_out_min=quotes[0].amount_out,
        recipient="0x...",
    ),
    SwapOptions(venues=venues),
)
```

```python [config.py]
from propamm import ContractClient, PropAmmRouter

client = ContractClient("https://...")
router = PropAmmRouter(client, "0x...")  # router proxy
```

:::

## Returns

`list[`[`Quote`](/python/types#quote)`]`

One entry per venue that priced the pair, sorted by `amount_out` descending.
Empty when no venue serves it — unlike [`quote`](/python/router/quote), this
never falls back to Uniswap, so an empty list means exactly that.

A venue that fails for any reason other than a revert — a transport error, a
node failure — raises instead of being dropped, so the list never silently
shortens.

## Parameters

### token_in

- **Type:** `str`

Address of the token being sold, or `ETH_SENTINEL` for native ETH.

### token_out

- **Type:** `str`

Address of the token being bought, or `ETH_SENTINEL` for native ETH.

### amount_in

- **Type:** `int`

Exact input amount, in atomic units. Venues quote against depth, so the set
that answers depends on the size.

### opts (optional)

- **Type:** [`QuoteOptions`](/python/types#quoteoptions)

Per-call quote options, with the same `overrides` and `bebop_default`
semantics as [`quote`](/python/router/quote).

`venues` narrows the candidates instead of restricting a single quote: each
listed venue is still quoted on its own.

```python
from propamm import QuoteOptions
from propamm.common.pamms import BEBOP, FERMI

quotes = await router.get_quotes(
    ETH_SENTINEL, USDC, parse_ether("1"), QuoteOptions(venues=[FERMI, BEBOP])
)
```
