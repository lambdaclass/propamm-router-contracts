# Price levels utilities

Lower-level pieces of `propamm.prices`, for custom sources or manual snapshot
inspection.

## parse_price_levels_message

```python
def parse_price_levels_message(raw: Any) -> PriceLevelsSnapshot
```

Parse a raw price-levels payload (a WS frame or the JSON-RPC `result`) into a
[`PriceLevelsSnapshot`](/python/types#pricelevelsnapshot): hex amounts become
`int`s, addresses are checksummed, and malformed pAMMs, pairs, or rungs are
dropped silently.

```python
from propamm.prices import parse_price_levels_message
import json

snapshot = parse_price_levels_message(json.loads(frame))
```

**Parameters:** `raw` — the decoded JSON. Raises `PricesError` if it isn't a dict.  
**Returns** [`PriceLevelsSnapshot`](/python/types#pricelevelsnapshot).

## Constants

- `DEFAULT_PRICE_LEVELS_RPC_URL` — `https://rpc.titanbuilder.xyz`
- `DEFAULT_PRICE_LEVELS_WS_URL` — `wss://eu.rpc.titanbuilder.xyz/ws/pamm_price_levels`
