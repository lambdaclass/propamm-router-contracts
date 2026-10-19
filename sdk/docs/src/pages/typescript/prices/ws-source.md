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
  source: new PriceLevelsWsSource({ url: "wss://eu.data.titanbuilder.xyz/ws/pamm_price_levels_v2" }),
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
- **Default:** `wss://eu.data.titanbuilder.xyz/ws/pamm_price_levels_v2`

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

### decimals (optional)

- **Type:** `Record<string, number>`

Decimals of tokens missing from `TOKEN_DECIMALS`, by token address (an entry
also overrides the built-in value). Titan's v2 feed sends amounts in human
units, so a book quoting a token without known decimals is skipped.
Each value must be an integer from 0 to 255, or the constructor throws.
