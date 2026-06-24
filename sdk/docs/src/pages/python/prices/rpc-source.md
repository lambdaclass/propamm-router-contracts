# PriceLevelsRpcSource

Fetch-on-demand source for pAMM price levels: one `titan_getPammPriceLevels`
call per `get_price_levels`. Also exposes the quote helpers directly. Simplest
for sporadic use.

## Usage

```python
from propamm.prices import PriceLevels, PriceLevelsRpcSource

# custom endpoint — snapshot and quotes both use it
prices = PriceLevels(source=PriceLevelsRpcSource("https://us.rpc.titanbuilder.xyz"))
```

## Constructor

```python
PriceLevelsRpcSource(url: str = DEFAULT_PRICE_LEVELS_RPC_URL)
```

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
