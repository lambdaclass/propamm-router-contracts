# PriceLevels

Entry point for Titan's pAMM price levels. Wraps a snapshot source and exposes
quote helpers, mirroring the structure of `PropAmmRouter`.

## Usage

```python
from propamm.prices import PriceLevels, PriceLevelsWsSource

# one-shot HTTP snapshot (default)
prices = PriceLevels()
snapshot = await prices.get_price_levels()

# live stream
prices = PriceLevels(
    source=PriceLevelsWsSource(url="wss://eu.rpc.titanbuilder.xyz/ws/pamm_price_levels"),
)
snapshot = await prices.get_price_levels()
await prices.close()
```

## Constructor

```python
PriceLevels(
    source: PriceLevelsSource | None = None,
    *,
    rpc_url: str | None = None,
)
```

### source (optional)

Source the snapshot is pulled from. Defaults to a `PriceLevelsRpcSource`.
Pass a [`PriceLevelsWsSource`](/python/prices/ws-source) for a live stream.

### rpc_url (optional)

Titan JSON-RPC endpoint used by the quote helpers. Ignored when `source` is a
[`PriceLevelsRpcSource`](/python/prices/rpc-source) (its URL is reused).
Set this when pairing a `PriceLevelsWsSource` with a private or regional
deployment so quotes go to the same host:

```python
prices = PriceLevels(
    source=PriceLevelsWsSource(url="wss://us.rpc.titanbuilder.xyz/ws/pamm_price_levels"),
    rpc_url="https://us.rpc.titanbuilder.xyz",
)
```

## Methods

### get_price_levels()

```python
async def get_price_levels() -> PriceLevelsSnapshot
```

Latest price-level snapshot from the configured source.

**Returns** [`PriceLevelsSnapshot`](/python/types#pricelevelsnapshot).

### get_quote()

```python
async def get_quote(token_in: str, token_out: str, amount_in: int) -> TitanQuote
```

Best quote across all pAMMs for a size (`titan_getPammQuote`). Served from
Titan's latest snapshot over HTTP, skipping the on-chain `eth_call` that
`router.quote` runs.

**Returns** [`TitanQuote`](/python/types#titanquote).

### get_quote_venue()

```python
async def get_quote_venue(venue: str, token_in: str, token_out: str, amount_in: int) -> TitanQuote
```

Quote from a specific venue for a size (`titan_getPammQuoteVenue`).

**Returns** [`TitanQuote`](/python/types#titanquote).

### close()

```python
async def close() -> None
```

Tear down the snapshot source. Closes the stream socket when the source is a
`PriceLevelsWsSource`; no-op for `PriceLevelsRpcSource`.
