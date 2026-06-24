# PriceLevels

Entry point for Titan's pAMM price levels. Wraps a snapshot source and exposes
quote helpers, mirroring the structure of `PropAmmRouter`.

## Usage

```rust
use propamm::prices::{PriceLevels, PriceLevelsWsSource, PriceLevelsWsSourceConfig};
use ethrex_common::Address;
use std::str::FromStr;
use std::sync::Arc;

// one-shot HTTP snapshot (default)
let prices = PriceLevels::new();
let snapshot = prices.get_price_levels().await?;

// live stream
let prices = PriceLevels::with_source(Arc::new(PriceLevelsWsSource::new(
    PriceLevelsWsSourceConfig {
        url: "wss://eu.rpc.titanbuilder.xyz/ws/pamm_price_levels".into(),
        ..Default::default()
    },
)));
let snapshot = prices.get_price_levels().await?;
prices.close();
```

## Constructors

### PriceLevels::new()

```rust
pub fn new() -> Self
```

Client with the default one-shot HTTP snapshot source (`DEFAULT_PRICE_LEVELS_RPC_URL`).

### PriceLevels::with_source()

```rust
pub fn with_source(source: Arc<dyn PriceLevelsSource>) -> Self
```

Client with an explicit snapshot source. When `source` is a
[`PriceLevelsRpcSource`](/rust/prices/rpc-source), the quote helpers reuse its
URL so a custom endpoint covers both. Otherwise quotes fall back to the default
HTTP endpoint.

### PriceLevels::with_source_and_rpc_url()

```rust
pub fn with_source_and_rpc_url(source: Arc<dyn PriceLevelsSource>, rpc_url: impl Into<String>) -> Self
```

Client with an explicit snapshot source and a specific RPC URL for the quote
helpers. Use this when pairing a [`PriceLevelsWsSource`](/rust/prices/ws-source)
with a private or regional deployment so quotes go to the same host as the
stream:

```rust
use propamm::prices::{PriceLevels, PriceLevelsWsSource, PriceLevelsWsSourceConfig};
use std::sync::Arc;

let prices = PriceLevels::with_source_and_rpc_url(
    Arc::new(PriceLevelsWsSource::new(PriceLevelsWsSourceConfig {
        url: "wss://us.rpc.titanbuilder.xyz/ws/pamm_price_levels".into(),
        ..Default::default()
    })),
    "https://us.rpc.titanbuilder.xyz",
);
```

When `source` is a `PriceLevelsRpcSource`, `rpc_url` is ignored and the
source's own URL is reused.

## Methods

### get_price_levels()

```rust
pub async fn get_price_levels(&self) -> Result<Arc<PriceLevelsSnapshot>>
```

Latest price-level snapshot from the configured source.

**Returns** `Arc<`[`PriceLevelsSnapshot`](/rust/types#pricelevelsnapshot)`>`. Cheap to clone — the streaming source hands out a pointer, not a deep copy.

### get_quote()

```rust
pub async fn get_quote(
    &self,
    token_in: Address,
    token_out: Address,
    amount_in: U256,
) -> Result<TitanQuote>
```

Best quote across all pAMMs for a size (`titan_getPammQuote`). Served from
Titan's latest snapshot over HTTP, skipping the on-chain `eth_call` that
`router.quote` runs.

**Returns** [`TitanQuote`](/rust/types#titanquote).

### get_quote_venue()

```rust
pub async fn get_quote_venue(
    &self,
    venue: Address,
    token_in: Address,
    token_out: Address,
    amount_in: U256,
) -> Result<TitanQuote>
```

Quote from a specific venue for a size (`titan_getPammQuoteVenue`).

**Returns** [`TitanQuote`](/rust/types#titanquote).

### close()

```rust
pub fn close(&self)
```

Tear down the snapshot source. Closes the stream socket when the source is a
`PriceLevelsWsSource`; no-op for `PriceLevelsRpcSource`.
