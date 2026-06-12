/**
 * Quotes: how much ETH you get for $100, $1,000, and $10,000 USDC.
 * Larger trades typically get a worse rate, so the per-USDC
 * output drifts down as the size grows. Re-quotes every 5 seconds until you
 * stop it with Ctrl-C.
 *
 * Build the SDK first, then run (Node >= 22.18 runs TypeScript directly):
 *
 *   pnpm build
 *   RPC_URL=https://... node examples/quotes.ts
 *
 * The RPC_URL environment variable is required (e.g. a mainnet node).
 * ROUTER_ADDRESS defaults to the mainnet router deployment.
 */
import { ContractClient } from "@propamm/sdk/client";
import { PropAmmRouter } from "@propamm/sdk/router";
import { ETH_SENTINEL, USDC } from "@propamm/sdk/common/tokens";
import { formatUnits, parseUnits } from "@propamm/sdk/common/helpers";
import { anvil } from "@propamm/sdk/common/chains";
import type { Address } from "@propamm/sdk";

const RPC_URL = process.env.RPC_URL;
if (!RPC_URL) throw new Error("RPC_URL is required");
// mainnet router deployment
const ROUTER_ADDRESS = (process.env.ROUTER_ADDRESS ??
  "0x4DdF368080CD7946db5b459aD591c350158175e1") as Address;

// No `account`: quotes are read-only, so no private key is required.
const client = new ContractClient({ rpcUrl: RPC_URL, chain: anvil });
// Constructed with no options, so quotes apply fresh pAMM state overrides
// streamed from Titan by default (see the README for details).
const router = new PropAmmRouter(client, ROUTER_ADDRESS);

const USDC_DECIMALS = 6;
const ETH_DECIMALS = 18;
const INTERVAL_MS = 5000;

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// Re-quote every 5 seconds until interrupted (Ctrl-C).
while (true) {
  for (const dollars of [100, 1000, 10000]) {
    const amountIn = parseUnits(String(dollars), USDC_DECIMALS);
    // `quote` is an eth_call simulation; ETH_SENTINEL as `tokenOut` asks for
    // native ETH out. It returns the best venue's output and that venue.
    const { amountOut } = await router.quote(USDC, ETH_SENTINEL, amountIn);
    const eth = Number(formatUnits(amountOut, ETH_DECIMALS));
    // Implied ETH price in dollars: USDC paid divided by ETH received.
    const price = dollars / eth;
    console.log(`${dollars} USDC -> ${eth} ETH @ ${price.toFixed(2)} USDC/ETH`);
  }
  console.log(); // blank line between rounds for readability
  await sleep(INTERVAL_MS);
}
