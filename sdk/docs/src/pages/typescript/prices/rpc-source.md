# PriceLevelsRpcSource

Fetch-on-demand source for pAMM price levels: one `titan_getPammPriceLevels`
call per `getPriceLevels`. Also exposes the quote helpers directly. Simplest
for sporadic use.

```ts
new PriceLevelsRpcSource(options?: PriceLevelsRpcSourceOptions)
```

## Usage

```ts
import { PriceLevels, PriceLevelsRpcSource } from "propamm/prices";

// custom endpoint — snapshot and quotes both use it
const prices = new PriceLevels({
  source: new PriceLevelsRpcSource({ url: "https://us.rpc.titanbuilder.xyz" }),
});
```

## Methods

### getPriceLevels()

```ts
getPriceLevels(): Promise<PriceLevelsSnapshot>
```

**Returns** [`Promise<PriceLevelsSnapshot>`](/typescript/types#pricelevelsnapshot) — a fresh snapshot. Throws on HTTP or
JSON-RPC error.

### getQuote()

```ts
getQuote(tokenIn: Address, tokenOut: Address, amountIn: bigint): Promise<TitanQuote>
```

**Returns** [`Promise<TitanQuote>`](/typescript/types#titanquote). Throws on error.

### getQuoteVenue()

```ts
getQuoteVenue(venue: Address, tokenIn: Address, tokenOut: Address, amountIn: bigint): Promise<TitanQuote>
```

**Returns** [`Promise<TitanQuote>`](/typescript/types#titanquote). Throws on error.

## Options

### url (optional)

- **Type:** `string`
- **Default:** `https://rpc.titanbuilder.xyz`

Titan JSON-RPC endpoint.

### fetch (optional)

- **Type:** `typeof fetch`

Custom fetch implementation.
