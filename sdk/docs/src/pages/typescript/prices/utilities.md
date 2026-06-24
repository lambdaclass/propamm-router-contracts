# Price levels utilities

Lower-level pieces of `propamm/prices`, for custom sources or manual snapshot
inspection.

## parsePriceLevelsMessage

```ts
parsePriceLevelsMessage(raw: unknown): PriceLevelsSnapshot
```

Parse a raw price-levels payload (a WS frame or the JSON-RPC `result`) into a
[`PriceLevelsSnapshot`](/typescript/types#pricelevelsnapshot): hex amounts become
bigints, addresses are lowercased, and malformed pairs or rungs are dropped.

```ts
import { parsePriceLevelsMessage } from "propamm/prices";

const snapshot = parsePriceLevelsMessage(JSON.parse(frame));
// { blockNumber: 25345763n, pamms: [{ pamm: "0x...", pairs: [...] }] }
```

**Parameters:** `raw: unknown` — the decoded JSON. Throws if it isn't an object.  
**Returns** [`PriceLevelsSnapshot`](/typescript/types#pricelevelsnapshot).

## findPair

```ts
findPair(
  snapshot: PriceLevelsSnapshot,
  pamm: Address,
  tokenIn: Address,
  tokenOut: Address,
): PairPriceLevels | undefined
```

Find a pAMM's order book for a pair within a snapshot. Address comparisons are
case-insensitive.

```ts
import { findPair } from "propamm/prices";
import { USDC, WETH } from "propamm/common/tokens";

const pair = findPair(snapshot, pammAddress, USDC, WETH);
// { tokenIn: "0xa0b8...", tokenOut: "0xc02a...", orderBook: [...] }
```

**Returns** [`PairPriceLevels`](/typescript/types#pairpricelevels) or `undefined` if the pAMM / pair is not in
the snapshot.

## Constants

- `DEFAULT_PRICE_LEVELS_RPC_URL` — `https://rpc.titanbuilder.xyz`
- `DEFAULT_PRICE_LEVELS_WS_URL` — `wss://eu.rpc.titanbuilder.xyz/ws/pamm_price_levels`
