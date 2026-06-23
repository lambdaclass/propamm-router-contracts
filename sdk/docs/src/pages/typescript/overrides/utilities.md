# Overrides utilities

Lower-level pieces of `propamm/overrides`, for custom sources or manual
`eth_call` overrides.

## parseOverridesMessage

```ts
parseOverridesMessage(raw: unknown): OverridesSnapshot
```

Parse a raw payload (a WS frame or the JSON-RPC `result`) into an
[`OverridesSnapshot`](/typescript/types#overridessnapshot): metadata keys split out, addresses and slots
lowercased, empty `stateDiff`s dropped.

```ts
import { parseOverridesMessage } from "propamm/overrides";

const snapshot = parseOverridesMessage(JSON.parse(frame));
// { blockNumber: 24285034n, timestampNs: ..., perPamm: { "0x...": { ... } } }
```

**Parameters:** `raw: unknown` — the decoded JSON. Throws if it isn't an object.
**Returns** [`OverridesSnapshot`](/typescript/types#overridessnapshot).

## toStateOverride

```ts
toStateOverride(snapshot: OverridesSnapshot, options?: ToStateOverrideOptions): StateOverride
```

Flatten a snapshot into viem's `StateOverride` array for `eth_call`, merging
diffs at slot level and padding words to 32 bytes.

```ts
import { toStateOverride } from "propamm/overrides";

const stateOverride = toStateOverride(snapshot);
const out = await client.call({ ...callParams, stateOverride });
```

**Parameters:**

- `snapshot: OverridesSnapshot`
- `options.pamms?: Address[]` — restrict to these pAMM entries (default all).
- `options.bebopDefault?: boolean` — inject the Bebop default slot when no
  Bebop entry is present (default `true`), so a stale on-chain Bebop price
  can't win venue selection.

**Returns** `StateOverride`.

## Constants

- `BEBOP_DEFAULT_SLOT` — the registry slot zeroed by the Bebop default.
- `DEFAULT_OVERRIDES_RPC_URL` / `DEFAULT_OVERRIDES_WS_URL`.

## OverridesSource

The interface both sources implement — implement it to plug in a custom
source:

```ts
interface OverridesSource {
  getOverrides(): Promise<OverridesSnapshot | undefined>;
  close?(): void;
}
```
