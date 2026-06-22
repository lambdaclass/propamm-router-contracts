# allowance

Current allowance an owner has granted the router for an ERC-20 token.

```ts
allowance(token: Address, owner: Address): Promise<bigint>
```

## Usage

```ts
import { USDC } from "propamm/common/tokens";

await router.allowance(USDC, account.address);
```

## Returns

`bigint`

The current allowance, in atomic units.

## Parameters

### token

- **Type:** `Address`

The ERC-20 token.

### owner

- **Type:** `Address`

The account whose allowance to read.
