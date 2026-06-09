# PropAMM TypeScript SDK

SDK for interacting with the `PropAMMRouter` contract over JSON-RPC.

## Setup

```sh
pnpm install
pnpm build      # compile to dist/
pnpm typecheck
```

## Getting started

Quote and swap 1 ETH for USDC through the best venue:

```ts
import { ContractClient } from "@propamm/sdk/client";
import { PropAmmRouter } from "@propamm/sdk/router";
import { ETH_SENTINEL, USDC } from "@propamm/sdk/common/tokens";
import { applySlippage, deadlineIn } from "@propamm/sdk/common/helpers";
import { mainnet } from "@propamm/sdk/common/chains";
import { privateKeyToAccount } from "@propamm/sdk/common/accounts";

const account = privateKeyToAccount("0x...");
const client = new ContractClient({ rpcUrl: "https://...", chain: mainnet, account });
const router = new PropAmmRouter(client, "0x..."); // deployed router proxy

const { amountOut } = await router.quote(ETH_SENTINEL, USDC, 10n ** 18n);

const result = await router.swapAndWait({
  tokenIn: ETH_SENTINEL,
  tokenOut: USDC,
  amountIn: 10n ** 18n,
  amountOutMin: applySlippage(amountOut, 50), // quote - 0.5%
  recipient: account.address,
  deadline: deadlineIn(300), // now + 5 min
});
console.log(`received ${result.amountOut} USDC via ${result.executedVenue}`);
```

## Usage

```ts
import { ContractClient } from "@propamm/sdk/client";
import { PropAmmRouter, frontendFee } from "@propamm/sdk/router";
import { ETH_SENTINEL, USDC, WETH } from "@propamm/sdk/common/tokens";
import { PAMMS } from "@propamm/sdk/common/pamms";
import { applySlippage, deadlineIn } from "@propamm/sdk/common/helpers";
import { mainnet } from "@propamm/sdk/common/chains";
import { privateKeyToAccount } from "@propamm/sdk/common/accounts";

const client = new ContractClient({
  rpcUrl: "http://localhost:8545",
  chain: mainnet,
  account: privateKeyToAccount("0x..."), // omit for read-only (quotes/views still work)
});
const router = new PropAmmRouter(client, "0x..."); // deployed router proxy

// Quote, approve, swap, then wait
const { amountOut, venue } = await router.quote(USDC, WETH, 1_000_000n);

await router.approve(USDC, 1_000_000n); // ERC-20 input requires router allowance

const hash = await router.swap({
  tokenIn: USDC,
  tokenOut: WETH,
  amountIn: 1_000_000n,
  amountOutMin: applySlippage(amountOut, 50), // quote - 0.5%
  recipient: me,
  deadline: deadlineIn(300), // now + 5 min
});
const result = await router.waitForSwap(hash);
// { hash, receipt, amountIn, amountOut, executedVenue, recipient, fee? }

// One-shot: swap + wait combined
const res = await router.swapViaVenueAndWait(PAMMS.kipseli, {
  tokenIn: USDC,
  tokenOut: WETH,
  amountIn: 1_000_000n,
  amountOutMin: minOut,
  recipient: me,
  deadline: deadlineIn(300),
});

// Native ETH input: sentinel token, msg.value attached automatically
await router.swapAndWait({
  tokenIn: ETH_SENTINEL,
  tokenOut: USDC,
  amountIn: 10n ** 18n,
  amountOutMin: minOut,
  recipient: me,
  deadline: deadlineIn(300),
});

// Frontend fee variants (bps validated against MAX_FEE_BPS)
await router.swapWithFee(params, frontendFee(25, feeRecipient));

// Pinned / selected-venue quotes
const pinned = await router.quoteVenue(PAMMS.fermi, USDC, WETH, amountIn);
const subset = await router.quoteSelectedVenues([PAMMS.fermi, PAMMS.bebop], USDC, WETH, amountIn);

// Views
await router.getWhitelistedVenues();
await router.paused();
await router.fallbackSwapRouter(); // Uniswap fallback "venue" address (dynamic, not in PAMMS)
```

Admin functions (`addVenue`, `pause`, `setPairFee`, ...) have no typed
methods, but they are in the exported ABI — call them through the generic
client:

```ts
import { propAmmRouterAbi } from "@propamm/sdk/router/abi";

await client.write({
  address: router.address,
  abi: propAmmRouterAbi,
  functionName: "addVenue",
  args: [newVenue],
});
```

## Layout

Source modules map 1:1 to import paths (`src/<path>.ts` → `@propamm/sdk/<path>`):

- `src/client.ts` — generic viem-based contract client (`read`/`call`/`write`/`waitForTransaction`).
- `src/router/index.ts` — `PropAmmRouter` bindings (quotes, swaps, `*AndWait` variants, `waitForSwap`, `approve`/`allowance`, views) plus `frontendFee` and `MAX_FEE_BPS`.
- `src/router/abi.ts` — human-readable `PropAMMRouter` ABI (functions, events, errors).
- `src/common/tokens.ts` — `ETH_SENTINEL` and mainnet token addresses.
- `src/common/pamms.ts` — `PAMMS` name → venue address mapping.
- `src/common/helpers.ts` — `applySlippage`, `deadlineIn`.
- `src/common/chains.ts`, `src/common/accounts.ts` — viem re-exports.

The on-chain quote functions are nonpayable (not view), so the bindings call
them through `eth_call` simulation (`ContractClient.call`) rather than a
plain read.
