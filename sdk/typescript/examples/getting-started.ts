/**
 * Getting started: quote and swap 1 ETH for USDC through the best venue.
 *
 * Build the SDK first, then run (Node >= 22.18 runs TypeScript directly):
 *
 *   pnpm build
 *   node examples/getting-started.ts
 *
 * Defaults target a local anvil mainnet fork (`anvil --fork-url <mainnet rpc>`)
 * with anvil's default funded account and the mainnet router deployment.
 * Override with RPC_URL / PRIVATE_KEY / ROUTER_ADDRESS / SLIPPAGE_BPS.
 *
 * Note: quotes automatically apply fresh pAMM state overrides (streamed from
 * Titan), but a fork still *executes* swaps against its frozen state — if the
 * swap reverts with `InsufficientOutput` there, raise SLIPPAGE_BPS (live
 * chains fill at the quoted state normally).
 */
import { ContractClient } from "propamm/client";
import { PropAmmRouter } from "propamm/router";
import { ETH_SENTINEL, USDC } from "propamm/common/tokens";
import {
  applySlippage,
  deadlineIn,
  formatEther,
  formatUnits,
  parseEther,
} from "propamm/common/helpers";
import { anvil } from "propamm/common/chains";
import { privateKeyToAccount } from "propamm/common/accounts";
import type { Address, Hash } from "propamm";

const RPC_URL = process.env.RPC_URL ?? "http://localhost:8545";
// anvil's default funded account #0
const PRIVATE_KEY = (process.env.PRIVATE_KEY ??
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80") as Hash;
// mainnet router deployment
const ROUTER_ADDRESS = (process.env.ROUTER_ADDRESS ??
  "0x4DdF368080CD7946db5b459aD591c350158175e1") as Address;
const SLIPPAGE_BPS = Number(process.env.SLIPPAGE_BPS ?? 50);

const account = privateKeyToAccount(PRIVATE_KEY);
const client = ContractClient.fromRpc({ rpcUrl: RPC_URL, chain: anvil, account });
const router = new PropAmmRouter(client, ROUTER_ADDRESS);

const amountIn = parseEther("1");
const { amountOut, venue } = await router.quote(ETH_SENTINEL, USDC, amountIn);
console.log(
  `quote: ${formatEther(amountIn)} ETH -> ${formatUnits(amountOut, 6)} USDC via ${venue}`,
);

const result = await router.swapAndWait({
  tokenIn: ETH_SENTINEL,
  tokenOut: USDC,
  amountIn,
  amountOutMin: applySlippage(amountOut, SLIPPAGE_BPS),
  recipient: account.address,
  deadline: deadlineIn(300), // now + 5 min
});
console.log(
  `swapped: received ${formatUnits(result.amountOut, 6)} USDC via ${result.executedVenue} (tx ${result.hash})`,
);
