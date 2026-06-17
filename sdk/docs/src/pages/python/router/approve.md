# approve

Approve the router to pull an amount of an ERC-20 token from the signer.
Required before any swap with ERC-20 input.

```python
async def approve(self, token: str, amount: int) -> str
```

## Usage

```python
from propamm_sdk.common.helpers import parse_units
from propamm_sdk.common.tokens import USDC

tx_hash = await router.approve(USDC, parse_units("100", 6))
await client.wait_for_transaction(tx_hash)
```

## Returns

`str`

The approval transaction hash.

## Parameters

### token

- **Type:** `str`

The ERC-20 token to approve.

### amount

- **Type:** `int`

Allowance to grant the router, in atomic units.
