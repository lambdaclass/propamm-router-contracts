# allowance

Current allowance an owner has granted the router for an ERC-20 token.

```python
async def allowance(self, token: str, owner: str) -> int
```

## Usage

```python
from propamm_sdk.common.tokens import USDC

await router.allowance(USDC, account.address)
```

## Returns

`int`

The current allowance, in atomic units.

## Parameters

### token

- **Type:** `str`

The ERC-20 token.

### owner

- **Type:** `str`

The account whose allowance to read.
