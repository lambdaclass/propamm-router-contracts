# Getting started

The TypeScript SDK lives in `sdk/typescript` (`@propamm/sdk`), built on
[viem](https://viem.sh). ESM-only; viem is the single runtime dependency.

```sh
cd sdk/typescript
pnpm install
pnpm build
```

Imports are hierarchical — each module has its own subpath, and viem
essentials (chains, account builders) are re-exported so basic usage needs no
direct viem import:

```ts
import { ContractClient } from "@propamm/sdk/client";
import { PropAmmRouter } from "@propamm/sdk/router";
import { ETH_SENTINEL, USDC } from "@propamm/sdk/common/tokens";
import { applySlippage, deadlineIn, formatUnits, parseEther } from "@propamm/sdk/common/helpers";
import { mainnet } from "@propamm/sdk/common/chains";
import { privateKeyToAccount } from "@propamm/sdk/common/accounts";
```

## Quote and swap

```ts
const account = privateKeyToAccount("0x...");
const client = new ContractClient({
  rpcUrl: "https://...",
  chain: mainnet,
  account, // omit for a read-only client (quotes and views still work)
});
const router = new PropAmmRouter(client, "0x..."); // deployed router proxy

const amountIn = parseEther("1");
const { amountOut, venue } = await router.quote(ETH_SENTINEL, USDC, amountIn);

const result = await router.swapAndWait({
  tokenIn: ETH_SENTINEL,
  tokenOut: USDC,
  amountIn,
  amountOutMin: applySlippage(amountOut, 50), // quote - 0.5%
  recipient: account.address,
  deadline: deadlineIn(300), // now + 5 min
});
console.log(`received ${formatUnits(result.amountOut, 6)} USDC via ${result.executedVenue}`);
```

The quote already reflects fresh off-chain liquidity — pAMM state overrides
are applied automatically. Native ETH input is signalled with `ETH_SENTINEL`
(no ERC-20 approval needed; `msg.value` is attached automatically).

## Runnable example

```sh
pnpm build
node examples/getting-started.ts   # Node >= 22.18 runs TypeScript directly
```

It defaults to a local anvil mainnet fork with anvil's funded account and the
mainnet router deployment; override with `RPC_URL` / `PRIVATE_KEY` /
`ROUTER_ADDRESS` / `SLIPPAGE_BPS`.

## Checks

```sh
pnpm check   # typecheck + lint (ESLint) + format check (Prettier)
```
