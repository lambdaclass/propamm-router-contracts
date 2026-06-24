# Price levels utilities

Lower-level pieces of `propamm::prices`, for custom sources or manual snapshot
inspection.

## parse_price_levels_message

```rust
pub fn parse_price_levels_message(raw: &Value) -> Result<PriceLevelsSnapshot>
```

Parse a raw price-levels payload (a WS frame or the JSON-RPC `result`) into a
[`PriceLevelsSnapshot`](/rust/types#pricelevelsnapshot): hex amounts become
`U256`s, and malformed pAMMs, pairs, or rungs are dropped silently.

```rust
use propamm::prices::parse_price_levels_message;
use serde_json::Value;

let value: Value = serde_json::from_str(&frame)?;
let snapshot = parse_price_levels_message(&value)?;
```

**Parameters:** `raw: &Value` — the decoded JSON. Errors if it isn't an object.  
**Returns** [`PriceLevelsSnapshot`](/rust/types#pricelevelsnapshot).

## Constants

- `DEFAULT_PRICE_LEVELS_RPC_URL` — `https://rpc.titanbuilder.xyz`
- `DEFAULT_PRICE_LEVELS_WS_URL` — `wss://eu.rpc.titanbuilder.xyz/ws/pamm_price_levels`
