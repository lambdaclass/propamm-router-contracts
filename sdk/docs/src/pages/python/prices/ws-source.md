# PriceLevelsWsSource

Streaming source for pAMM price levels. Each frame is a complete snapshot (not
a delta), so a new frame replaces the cached one outright. Connects lazily,
reconnects with backoff, and auto-closes when idle.

## Usage

```python
from propamm.prices import PriceLevels, PriceLevelsWsSource

prices = PriceLevels(
    source=PriceLevelsWsSource(url="wss://eu.rpc.titanbuilder.xyz/ws/pamm_price_levels"),
)
snapshot = await prices.get_price_levels()
await prices.close()  # optional — idle timeout handles cleanup
```

## Constructor

```python
PriceLevelsWsSource(
    url: str = DEFAULT_PRICE_LEVELS_WS_URL,
    *,
    first_frame_timeout: float = 5.0,
    idle_timeout: float = 30.0,
)
```

## Methods

### get_price_levels()

```python
async def get_price_levels() -> PriceLevelsSnapshot
```

**Returns** [`PriceLevelsSnapshot`](/python/types#pricelevelsnapshot) — the latest cached snapshot.
Connects lazily on first use and waits for the first frame. After an idle
close, reconnects and waits for a fresh frame. Raises on first-frame timeout
or after `close()`.

### close()

```python
async def close() -> None
```

Immediate, permanent teardown. Not needed for process exit — the idle timeout
handles that.

## Parameters

### url

- **Default:** `wss://eu.rpc.titanbuilder.xyz/ws/pamm_price_levels`

Stream endpoint. The stream is served from regional hosts (`eu.`, `ap.`,
`us.`); pick the nearest.

### first_frame_timeout

- **Default:** `5.0`

Seconds to wait for the first frame before raising `TimeoutError`.

### idle_timeout

- **Default:** `30.0`

Close the socket after this many seconds without a `get_price_levels` call;
the next call reconnects transparently.
