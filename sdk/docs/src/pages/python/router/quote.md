# quote

Best quote across all whitelisted venues and the Uniswap V3 fallback.

The router's quote functions are nonpayable on-chain, so the SDK calls them
through `eth_call` simulation — by default carrying the latest pAMM state
overrides plus their block number/timestamp, so venues quote fresh off-chain
liquidity.

```python
async def quote(
    self,
    token_in: str,
    token_out: str,
    amount_in: int,
    opts: QuoteOptions | None = None,
) -> Quote
```

## Usage

::: code-group

```python [example.py]
from propamm_sdk.common.helpers import parse_ether
from propamm_sdk.common.tokens import ETH_SENTINEL, USDC
from config import router

quote = await router.quote(ETH_SENTINEL, USDC, parse_ether("1"))
```

```python [config.py]
from propamm_sdk import ContractClient, PropAmmRouter

client = ContractClient("https://...")
router = PropAmmRouter(client, "0x...")  # router proxy
```

:::

## Returns

[`Quote`](/python/types#quote)

The best output amount and the venue that produced it; pin `venue` in a
follow-up [`swap`](/python/router/swap) via its `venues` option.

## Parameters

### token_in

- **Type:** `str`

Address of the token being sold, or `ETH_SENTINEL` for native ETH.

### token_out

- **Type:** `str`

Address of the token being bought, or `ETH_SENTINEL` for native ETH.

### amount_in

- **Type:** `int`

Exact input amount, in atomic units.

### opts (optional)

- **Type:** [`QuoteOptions`](/python/types#quoteoptions)

Per-call quote options.

```python
from propamm_sdk import QuoteOptions

stale = await router.quote(
    ETH_SENTINEL, USDC, parse_ether("1"), QuoteOptions(overrides=None)
)
```

`venues` restricts the quote: a single entry quotes that venue directly,
several pick the best among them (must be non-empty when present). When no
listed venue can be priced, the call does **not** raise: it falls back to the
Uniswap V3 quote and reports the fallback router as `venue`.

```python
from propamm_sdk.common.pamms import BEBOP, FERMI

pinned = await router.quote(
    ETH_SENTINEL, USDC, parse_ether("1"), QuoteOptions(venues=[FERMI])
)
subset = await router.quote(
    ETH_SENTINEL, USDC, parse_ether("1"), QuoteOptions(venues=[FERMI, BEBOP])
)
```
