# Getting started

Once the SDK is [installed](/typescript/installation), a quote and swap is a
client, a router, and two calls.

## Quote and swap

```ts
import { ContractClient } from "propamm/client";
import { PropAmmRouter } from "propamm/router";
import { ETH_SENTINEL, USDC } from "propamm/common/tokens";
import { applySlippage, deadlineIn, formatUnits, parseEther } from "propamm/common/helpers";
import { mainnet } from "propamm/common/chains";
import { privateKeyToAccount } from "propamm/common/accounts";

const account = privateKeyToAccount("0x...");
const client = ContractClient.fromRpc({
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

## Browser wallets

`ContractClient.fromRpc` builds its own viem clients from an RPC URL. In a
browser app the clients instead come from the connected wallet, so build the
client with `ContractClient.fromClients` and pass the wallet's own clients —
e.g. wagmi's `usePublicClient` / `useWalletClient`. Writes are then signed by
the wallet (MetaMask, WalletConnect, ...) over its own transport.

```ts
import { ContractClient } from "propamm/client";
import { usePublicClient, useWalletClient } from "wagmi";

// viem public client for reads and quote simulations
const publicClient = usePublicClient();

// viem wallet client for writes, signing through the connected wallet (MetaMask)
const { data: walletClient } = useWalletClient();

// SDK client backed by the wallet's viem clients
const client = ContractClient.fromClients({ publicClient, walletClient });
```

`walletClient` is `undefined` until a wallet connects; omit it (pass only
`publicClient`) for a read-only client that can still quote and read views.
