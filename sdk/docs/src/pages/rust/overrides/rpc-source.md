# OverridesRpcSource

Fetch-on-demand source for pAMM state overrides: one
`titan_getPammStateOverrides` HTTP call per `get_overrides()`. Nothing to
manage; simplest for sporadic quoting.

```rust
pub fn new(url: impl Into<String>) -> Self
```

## Usage

```rust
use std::sync::Arc;
use propamm::overrides::OverridesRpcSource;
use propamm::PropAmmRouter;

let source = Arc::new(OverridesRpcSource::default());
let router = PropAmmRouter::with_overrides(client, address, source.clone());

// or per call
use propamm::router::{QuoteOptions, QuoteOverrides};
let opts = QuoteOptions {
    overrides: QuoteOverrides::Source(source),
    ..Default::default()
};
```

## Methods

### get_overrides()

```rust
pub async fn get_overrides(&self) -> Result<OverridesSnapshot>
```

**Returns** [`Result<OverridesSnapshot>`](/rust/types#overridessnapshot) — a fresh snapshot fetched from the
endpoint. Fails on HTTP or JSON-RPC errors.

## Construction

### OverridesRpcSource::new(url)

- `url: impl Into<String>` — JSON-RPC endpoint.

### OverridesRpcSource::default()

Uses the public endpoint `https://rpc.titanbuilder.xyz`.
