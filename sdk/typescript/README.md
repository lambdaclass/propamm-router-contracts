# PropAMM TypeScript SDK

SDK for interacting with the PropAMM contracts over JSON-RPC.

## Setup

```sh
pnpm install
pnpm build      # compile to dist/
pnpm typecheck
```

## Usage

```ts
import { ContractClient } from "@propamm/sdk";
import { privateKeyToAccount } from "viem/accounts";
import { anvil } from "viem/chains";

const client = new ContractClient({
  rpcUrl: "http://localhost:8545",
  chain: anvil,
  account: privateKeyToAccount("0x..."), // omit for read-only
});

// Contract read
const result = await client.read({
  address: "0x...",
  abi: routerAbi,
  functionName: "someViewFunction",
});

// Contract write (simulates first, then sends)
const hash = await client.write({
  address: "0x...",
  abi: routerAbi,
  functionName: "someFunction",
  args: [/* ... */],
});
await client.waitForTransaction(hash);
```

## Layout

- `src/contract/client.ts` — viem-based contract client (`read`/`write`/`waitForTransaction`).
- `src/index.ts` — public exports.

Domain-specific bindings (quotes, swaps, router calls) should be added as new
modules on top of these primitives.
