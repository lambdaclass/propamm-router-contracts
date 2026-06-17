# Overrides utilities

Lower-level pieces of `propamm_sdk.overrides`, for custom sources or manual
`eth_call` overrides.

## parse_overrides_message

```python
def parse_overrides_message(raw: Any) -> OverridesSnapshot
```

Parse a raw payload (a WS frame or the JSON-RPC `result`) into an
[`OverridesSnapshot`](/python/types#overridessnapshot): metadata keys split
out, addresses lowercased, empty `stateDiff`s dropped.

```python
import json

from propamm_sdk.overrides import parse_overrides_message

snapshot = parse_overrides_message(json.loads(frame))
# OverridesSnapshot(block_number=24285034, timestamp_ns=..., per_pamm={"0x...": {...}})
```

**Parameters:** `raw: Any` — the decoded JSON. Raises if it isn't an object.
**Returns** [`OverridesSnapshot`](/python/types#overridessnapshot).

## to_state_override

```python
def to_state_override(snapshot: OverridesSnapshot, *, pamms: list[str] | None = None, bebop_default: bool = True) -> dict
```

Flatten a snapshot into the `eth_call` state-override map
(`{address: {"stateDiff": {slot: value}}}`), merging diffs at slot level and
padding words to 32 bytes.

```python
from propamm_sdk.overrides import to_state_override

state_override = to_state_override(snapshot)
raw = await client.call_with_overrides(function, state_override=state_override)
```

**Parameters:**

- `snapshot: OverridesSnapshot`
- `pamms: list[str] | None` — restrict to these pAMM entries (default all).
- `bebop_default: bool` — inject the Bebop default slot when no Bebop entry is
  present (default `True`), so a stale on-chain Bebop price can't win venue
  selection.

**Returns** `dict` — the `eth_call` state-override map.

## Constants

- `BEBOP_DEFAULT_SLOT` — the registry slot zeroed by the Bebop default.
- `DEFAULT_OVERRIDES_RPC_URL` / `DEFAULT_OVERRIDES_WS_URL`.

## OverridesSource

The abstract base both sources implement — subclass it to plug in a custom
source:

```python
class OverridesSource(abc.ABC):
    async def get_overrides(self) -> OverridesSnapshot | None: ...
    async def close(self) -> None: ...  # optional teardown; default no-op
```
