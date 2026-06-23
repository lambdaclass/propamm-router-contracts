# Overrides utilities

Lower-level pieces of the `overrides` module, for custom sources or manual
`eth_call` overrides.

## parse_overrides_message

```rust
pub fn parse_overrides_message(raw: &Value) -> Result<OverridesSnapshot>
```

Parse a raw payload (a WS frame or the JSON-RPC `result`) into an
[`OverridesSnapshot`](/rust/types#overridessnapshot); pAMMs/contracts with empty `stateDiff`s are dropped.

```rust
use propamm::overrides::parse_overrides_message;

let snapshot = parse_overrides_message(&serde_json::from_str(frame)?)?;
```

**Parameters:** `raw: &serde_json::Value`. Fails if it isn't a JSON object.
**Returns** [`Result<OverridesSnapshot>`](/rust/types#overridessnapshot).

## to_state_override

```rust
pub fn to_state_override(snapshot: &OverridesSnapshot, options: &ToStateOverrideOptions) -> StateOverrideSet
```

Flatten a snapshot into rex's `StateOverrideSet` for `eth_call`, merging
diffs at slot level.

```rust
use propamm::overrides::{to_state_override, ToStateOverrideOptions};
use propamm::CallOverrides;

let state = to_state_override(&snapshot, &ToStateOverrideOptions::default());
let overrides = CallOverrides { state: Some(state), block: None };
let data = client.call(to, calldata, &overrides).await?;
```

**Parameters:**

- `snapshot: &OverridesSnapshot`
- `options: &ToStateOverrideOptions`:
  - `pamms: Option<Vec<Address>>` — restrict to these pAMM entries (default all).
  - `skip_bebop_default: bool` — skip injecting the Bebop default slot when
    no Bebop entry is present.

**Returns** `StateOverrideSet`.

## Constants

- `BEBOP_DEFAULT_SLOT` — the registry slot zeroed by the Bebop default, so a
  stale on-chain Bebop price can't win venue selection.
- `DEFAULT_OVERRIDES_RPC_URL` / `DEFAULT_OVERRIDES_WS_URL`.

## OverridesSource

The trait both sources implement — implement it to plug in a custom source:

```rust
#[async_trait]
pub trait OverridesSource: Send + Sync {
    async fn get_overrides(&self) -> Result<OverridesSnapshot>;
    fn close(&self) {}
}
```
