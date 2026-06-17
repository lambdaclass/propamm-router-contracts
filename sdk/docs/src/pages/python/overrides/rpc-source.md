# OverridesRpcSource

Fetch-on-demand source for pAMM state overrides: one
`titan_getPammStateOverrides` HTTP call per `get_overrides()`. Nothing to
manage; simplest for sporadic quoting.

```python
OverridesRpcSource(url: str = ...)
```

## Usage

```python
from propamm_sdk import PropAmmRouter, QuoteOptions
from propamm_sdk.overrides import OverridesRpcSource

source = OverridesRpcSource()
router = PropAmmRouter(client, "0x...", overrides=source)

# or per call
await router.quote(WETH, USDC, amount_in, QuoteOptions(overrides=source))
```

## Methods

### get_overrides()

```python
async def get_overrides(self) -> OverridesSnapshot
```

**Returns** [`OverridesSnapshot`](/python/types#overridessnapshot) — a fresh
snapshot fetched from the endpoint. Raises on HTTP or JSON-RPC errors.

## Parameters

### url (optional)

- **Type:** `str`
- **Default:** `https://rpc.titanbuilder.xyz`

JSON-RPC endpoint.
