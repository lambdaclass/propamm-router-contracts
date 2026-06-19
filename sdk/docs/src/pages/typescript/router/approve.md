# approve

Approve the router to pull an amount of an ERC-20 token from the signer.
Required before any swap with ERC-20 input.

```ts
approve(token: Address, amount: bigint): Promise<Hash>
```

## Usage

```ts
import { parseUnits } from "propamm/common/helpers";
import { USDC } from "propamm/common/tokens";

const hash = await router.approve(USDC, parseUnits("100", 6));
await client.waitForTransaction(hash);
```

## Returns

`Hash`

The approval transaction hash.

## Parameters

### token

- **Type:** `Address`

The ERC-20 token to approve.

### amount

- **Type:** `bigint`

Allowance to grant the router, in atomic units.
