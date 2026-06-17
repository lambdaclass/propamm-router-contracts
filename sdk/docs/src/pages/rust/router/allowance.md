# allowance

Current allowance an owner has granted the router for an ERC-20 token.

```rust
pub async fn allowance(&self, token: Address, owner: Address) -> Result<U256>
```

## Usage

```rust
use propamm_sdk::common::tokens::USDC;

let allowance: U256 = router.allowance(USDC, me).await?;
```

## Returns

`Result<U256>`

The current allowance, in atomic units.

## Parameters

### token

- **Type:** `Address`

The ERC-20 token.

### owner

- **Type:** `Address`

The account whose allowance to read.
