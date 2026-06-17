# OverridesWsSource

Streaming source for pAMM state overrides — the router default. Caches
per-pAMM entries across frames (a frame only carries the pAMMs it updates),
reconnects with backoff, and auto-closes when idle.

```python
OverridesWsSource(
    url: str = "wss://rpc.titanbuilder.xyz/ws/pamm_quote_stream",
    *,
    first_frame_timeout: float = 5.0,
    idle_timeout: float = 30.0
)
```

## Usage

```python
from propamm_sdk import PropAmmRouter
from propamm_sdk.overrides import OverridesWsSource

# the default: a router without an overrides argument creates one internally
router = PropAmmRouter(client, "0x...")

# or configure explicitly
source = OverridesWsSource(idle_timeout=0)
router2 = PropAmmRouter(client, "0x...", overrides=source)
```

## Methods

### get_overrides()

```python
async def get_overrides(self) -> OverridesSnapshot
```

**Returns** [`OverridesSnapshot`](/python/types#overridessnapshot) — the
accumulated snapshot. Connects lazily on first use and waits for the first
frame; after an idle close it reconnects and waits for a fresh frame instead
of serving stale data. Raises on first-frame timeout or after `close()`.

### close()

```python
async def close(self) -> None
```

Immediate, permanent teardown. Not needed for process exit — the idle timeout
handles that.

## Parameters

### url (optional)

- **Type:** `str`
- **Default:** `wss://rpc.titanbuilder.xyz/ws/pamm_quote_stream`

Stream endpoint.

### first_frame_timeout (optional)

- **Type:** `float` (seconds)
- **Default:** `5.0`

How long `get_overrides` waits for the first frame before raising.

### idle_timeout (optional)

- **Type:** `float` (seconds)
- **Default:** `30.0`

Close the socket after this long without a `get_overrides` call; the next call
reconnects transparently. `0` closes right after each call.
