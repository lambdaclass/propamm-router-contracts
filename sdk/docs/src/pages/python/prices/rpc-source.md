# PriceLevelsRpcSource

Fetch-on-demand source for pAMM price levels: one `titan_getPammBooks`
call per `get_price_levels`. Also exposes the quote helpers directly. Simplest
for sporadic use.

## Usage

```python
from propamm.prices import PriceLevels, PriceLevelsRpcSource

# custom endpoint — snapshot and quotes both use it
prices = PriceLevels(source=PriceLevelsRpcSource("https://us.data.titanbuilder.xyz/data"))
```

## Constructor

```python
PriceLevelsRpcSource(
    url: str = DEFAULT_PRICE_LEVELS_RPC_URL,
    *,
    decimals: dict[str, int] | None = None,
)
```

### decimals (optional)

Decimals of tokens missing from `TOKEN_DECIMALS`, by token address (an entry
also overrides the built-in value). Titan's v2 feed sends amounts in human
units, so a book quoting a token without known decimals is skipped.
Each value must be an integer from 0 to 255, or the constructor raises
`PricesError`.

## Methods

### get_price_levels()

```python
async def get_price_levels() -> PriceLevelsSnapshot
```

**Returns** [`PriceLevelsSnapshot`](/python/types#pricelevelsnapshot). Raises on HTTP or JSON-RPC error.

### get_quote()

```python
async def get_quote(token_in: str, token_out: str, amount_in: int) -> TitanQuote
```

### get_quote_venue()

```python
async def get_quote_venue(venue: str, token_in: str, token_out: str, amount_in: int) -> TitanQuote
```
