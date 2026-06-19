# Getting started

Once the SDK is [installed](/typescript/installation), a quote and swap is a
client, a router, and two calls.

## Quote and swap

```ts
import { ContractClient } from "@propamm/sdk/client";
import { PropAmmRouter } from "@propamm/sdk/router";
import { ETH_SENTINEL, USDC } from "@propamm/sdk/common/tokens";
import { applySlippage, deadlineIn, formatUnits, parseEther } from "@propamm/sdk/common/helpers";
import { mainnet } from "@propamm/sdk/common/chains";
import { privateKeyToAccount } from "@propamm/sdk/common/accounts";

const account = privateKeyToAccount("0x...");
const client = new ContractClient({
  rpcUrl: "https://...",
  chain: mainnet,
  account, // omit for a read-only client (quotes and views still work)
});
const router = new PropAmmRouter(client); // defaults to the mainnet router proxy

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

`PropAmmRouter`'s second argument is optional: it defaults to the mainnet
`PropAMMRouter` deployment (exported as `MAINNET_ROUTER`). Pass an explicit
address to target a testnet or local-fork deployment.

The quote already reflects fresh off-chain liquidity — pAMM state overrides
are applied automatically. Native ETH input is signalled with `ETH_SENTINEL`
(no ERC-20 approval needed; `msg.value` is attached automatically).
