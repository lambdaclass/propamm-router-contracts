# PropAMM TypeScript SDK

SDK for interacting with the PropAMM contracts and the backend REST API
(`../web/backend`, served under `/api/v1`).

## Setup

```sh
pnpm install
pnpm build      # compile to dist/
pnpm typecheck
```

## Usage

```ts
import { createSdk } from "@propamm/sdk";
import { privateKeyToAccount } from "viem/accounts";
import { anvil } from "viem/chains";

const sdk = createSdk({
  api: { baseUrl: "http://localhost:4000/api/v1" },
  contract: {
    rpcUrl: "http://localhost:8545",
    chain: anvil,
    account: privateKeyToAccount("0x..."), // omit for read-only
  },
});

// REST API
const health = await sdk.api.get("/health");

// Contract read
const result = await sdk.contract.read({
  address: "0x...",
  abi: routerAbi,
  functionName: "someViewFunction",
});

// Contract write (simulates first, then sends)
const hash = await sdk.contract.write({
  address: "0x...",
  abi: routerAbi,
  functionName: "someFunction",
  args: [/* ... */],
});
await sdk.contract.waitForTransaction(hash);
```

## Layout

- `src/api/http.ts` — generic JSON HTTP client (`get`/`post`, typed errors).
- `src/contract/client.ts` — viem-based contract client (`read`/`write`/`waitForTransaction`).
- `src/index.ts` — public exports and the `createSdk` factory.

Domain-specific bindings (quotes, swaps, router calls) should be added as new
modules on top of these primitives.
