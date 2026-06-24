# PriceLevels

Entry point for Titan's pAMM price levels. Wraps a snapshot source and exposes
quote helpers, mirroring the structure of `PropAmmRouter`.

```ts
new PriceLevels(options?: PriceLevelsOptions)
```

## Usage

```ts
import { PriceLevels, PriceLevelsWsSource } from "propamm/prices";
import { USDC, WETH } from "propamm/common/tokens";
import { parseUnits } from "propamm/common/helpers";

// one-shot HTTP snapshot (default)
const prices = new PriceLevels();
const snapshot = await prices.getPriceLevels();

// live stream
const prices = new PriceLevels({
  source: new PriceLevelsWsSource({ url: "wss://eu.rpc.titanbuilder.xyz/ws/pamm_price_levels" }),
});
const snapshot = await prices.getPriceLevels();
prices.close();
```

## Methods

### getPriceLevels()

```ts
getPriceLevels(): Promise<PriceLevelsSnapshot | undefined>
```

Latest price-level snapshot from the configured source.

**Returns** [`Promise<PriceLevelsSnapshot | undefined>`](/typescript/types#pricelevelsnapshot).

### getQuote()

```ts
getQuote(tokenIn: Address, tokenOut: Address, amountIn: bigint): Promise<TitanQuote>
```

Best quote across all pAMMs for a size (`titan_getPammQuote`). Served from
Titan's latest snapshot over HTTP, skipping the on-chain `eth_call` that
`router.quote` runs.

**Returns** [`Promise<TitanQuote>`](/typescript/types#titanquote). Throws on RPC error.

### getQuoteVenue()

```ts
getQuoteVenue(venue: Address, tokenIn: Address, tokenOut: Address, amountIn: bigint): Promise<TitanQuote>
```

Quote from a specific venue for a size (`titan_getPammQuoteVenue`).

**Returns** [`Promise<TitanQuote>`](/typescript/types#titanquote). Throws on RPC error.

### close()

```ts
close(): void
```

Tear down the snapshot source. Closes the stream socket when the source is a
`PriceLevelsWsSource`; no-op for `PriceLevelsRpcSource`.

## Options

### source (optional)

- **Type:** [`PriceLevelsSource`](/typescript/types#pricelevelsource)
- **Default:** `new PriceLevelsRpcSource()`

Source the snapshot is pulled from. Pass a
[`PriceLevelsWsSource`](/typescript/prices/ws-source) for a live stream.

### rpcUrl (optional)

- **Type:** `string`
- **Default:** `https://rpc.titanbuilder.xyz`

Titan JSON-RPC endpoint used by the quote helpers. Ignored when `source` is a
[`PriceLevelsRpcSource`](/typescript/prices/rpc-source) (its URL is reused).
Set this when pairing a `PriceLevelsWsSource` with a private or regional
deployment so quotes go to the same host:

```ts
const prices = new PriceLevels({
  source: new PriceLevelsWsSource({ url: "wss://us.rpc.titanbuilder.xyz/ws/pamm_price_levels" }),
  rpcUrl: "https://us.rpc.titanbuilder.xyz",
});
```
