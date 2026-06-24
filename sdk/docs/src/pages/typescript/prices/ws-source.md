# PriceLevelsWsSource

Streaming source for pAMM price levels. Each frame is a complete snapshot (not
a delta), so a new frame replaces the cached one outright. Connects lazily,
reconnects with backoff, and auto-closes when idle.

```ts
new PriceLevelsWsSource(options?: PriceLevelsWsSourceOptions)
```

## Usage

```ts
import { PriceLevels, PriceLevelsWsSource } from "propamm/prices";

const prices = new PriceLevels({
  source: new PriceLevelsWsSource({ url: "wss://eu.rpc.titanbuilder.xyz/ws/pamm_price_levels" }),
});
const snapshot = await prices.getPriceLevels();
prices.close(); // optional — idle timeout handles cleanup
```

## Methods

### getPriceLevels()

```ts
getPriceLevels(): Promise<PriceLevelsSnapshot>
```

**Returns** [`Promise<PriceLevelsSnapshot>`](/typescript/types#pricelevelsnapshot) — the latest cached snapshot.
Connects lazily on first use and waits for the first frame. After an idle
close, reconnects and waits for a fresh frame. Throws on first-frame timeout
or after `close()`.

### close()

```ts
close(): void
```

Immediate, permanent teardown. Not needed for process exit — the idle timeout
handles that.

## Options

### url (optional)

- **Type:** `string`
- **Default:** `wss://eu.rpc.titanbuilder.xyz/ws/pamm_price_levels`

Stream endpoint. The stream is served from regional hosts (`eu.`, `ap.`,
`us.`); pick the nearest.

### firstFrameTimeoutMs (optional)

- **Type:** `number`
- **Default:** `5000`

How long `getPriceLevels` waits for the first frame before throwing.

### idleTimeoutMs (optional)

- **Type:** `number`
- **Default:** `30000`

Close the socket after this long without a `getPriceLevels` call; the next
call reconnects transparently. `0` closes right after each call; `Infinity`
keeps the stream open until `close()`.
