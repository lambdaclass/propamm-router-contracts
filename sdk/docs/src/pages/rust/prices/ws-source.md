# PriceLevelsWsSource

Streaming source for pAMM price levels. Each frame is a complete snapshot (not
a delta), so a new frame replaces the cached one outright. Connects lazily,
reconnects with backoff, and auto-closes when idle.

## Usage

```rust
use propamm::prices::{PriceLevels, PriceLevelsWsSource, PriceLevelsWsSourceConfig};
use std::sync::Arc;

let source = PriceLevelsWsSource::new(PriceLevelsWsSourceConfig {
    url: "wss://eu.rpc.titanbuilder.xyz/ws/pamm_price_levels".into(),
    ..Default::default()
});
let prices = PriceLevels::with_source(Arc::new(source));
let snapshot = prices.get_price_levels().await?;
prices.close(); // optional — idle timeout handles cleanup
```

## Constructors

### PriceLevelsWsSource::new()

```rust
pub fn new(config: PriceLevelsWsSourceConfig) -> Self
```

### PriceLevelsWsSource::default()

```rust
impl Default for PriceLevelsWsSource
```

Equivalent to `new(PriceLevelsWsSourceConfig::default())`.

## Methods

Implements [`PriceLevelsSource`](/rust/types#pricelevelsource):

### get_price_levels()

```rust
async fn get_price_levels(&self) -> Result<Arc<PriceLevelsSnapshot>>
```

The latest cached snapshot. Connects lazily on first use and waits for the
first frame. After an idle close, reconnects and waits for a fresh frame.
Errors on first-frame timeout or after `close()`.

### close()

```rust
fn close(&self)
```

Immediate, permanent teardown. Not needed for process exit — the idle timeout
handles that.

## Config: PriceLevelsWsSourceConfig

```rust
pub struct PriceLevelsWsSourceConfig {
    pub url: String,
    pub first_frame_timeout: Duration,
    pub idle_timeout: Duration,
}
```

### url

- **Default:** `wss://eu.rpc.titanbuilder.xyz/ws/pamm_price_levels`

Stream endpoint. The stream is served from regional hosts (`eu.`, `ap.`,
`us.`); pick the nearest.

### first_frame_timeout

- **Default:** `Duration::from_secs(5)`

How long `get_price_levels` waits for the first frame before returning an error.

### idle_timeout

- **Default:** `Duration::from_secs(30)`

Close the socket after this long without a `get_price_levels` call; the next
call reconnects transparently.
