# PriceLevelsRpcSource

Fetch-on-demand source for pAMM price levels: one `titan_getPammBooks`
call per `get_price_levels`. Also exposes the quote helpers directly. Simplest
for sporadic use.

## Usage

```rust
use propamm::prices::{PriceLevels, PriceLevelsRpcSource};
use std::sync::Arc;

// custom endpoint — snapshot and quotes both use it
let prices = PriceLevels::with_source(Arc::new(
    PriceLevelsRpcSource::new("https://us.data.titanbuilder.xyz/data"),
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

### PriceLevelsRpcSource::with_decimals()

```rust
pub fn with_decimals(self, decimals: HashMap<Address, u8>) -> Self
```

Decimals of tokens missing from `TOKEN_DECIMALS`, by token address (an entry
also overrides the built-in value). Titan's v2 feed sends amounts in human
units, so a book quoting a token without known decimals is skipped.

## Methods

Implements [`PriceLevelsSource`](/rust/types#pricelevelsource).

### get_price_levels()

```rust
async fn get_price_levels(&self) -> Result<Arc<PriceLevelsSnapshot>>
```

Fresh snapshot via `titan_getPammBooks`. Errors on HTTP or JSON-RPC failure.

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
