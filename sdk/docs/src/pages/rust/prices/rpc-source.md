# PriceLevelsRpcSource

Fetch-on-demand source for pAMM price levels: one `titan_getPammPriceLevels`
call per `get_price_levels`. Also exposes the quote helpers directly. Simplest
for sporadic use.

## Usage

```rust
use propamm::prices::{PriceLevels, PriceLevelsRpcSource};
use std::sync::Arc;

// custom endpoint — snapshot and quotes both use it
let prices = PriceLevels::with_source(Arc::new(
    PriceLevelsRpcSource::new("https://us.rpc.titanbuilder.xyz"),
));
```

## Constructors

### PriceLevelsRpcSource::new()

```rust
pub fn new(url: impl Into<String>) -> Self
```

### PriceLevelsRpcSource::default()

```rust
impl Default for PriceLevelsRpcSource
```

Equivalent to `new(DEFAULT_PRICE_LEVELS_RPC_URL)`.

## Methods

Implements [`PriceLevelsSource`](/rust/types#pricelevelsource).

### get_price_levels()

```rust
async fn get_price_levels(&self) -> Result<Arc<PriceLevelsSnapshot>>
```

Fresh snapshot via `titan_getPammPriceLevels`. Errors on HTTP or JSON-RPC failure.

### get_quote()

```rust
pub async fn get_quote(
    &self,
    token_in: Address,
    token_out: Address,
    amount_in: U256,
) -> Result<TitanQuote>
```

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
