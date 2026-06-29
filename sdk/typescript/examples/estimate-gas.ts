/**
 * Show the gas gap a swap's route can hide, via `eth_simulateV1` (the only
 * estimator that can override `block.timestamp`, which a pAMM validates against
 * its pushed state). Estimates three routes against one Titan override snapshot,
 * all pinned to its block + slot timestamp:
 *
 *   1. live          — no override; mainnet state prices the live route
 *   2. pAMM route    — the SDK's real pAMM overrides + the venue `quote` picked
 *                      forced (`venues: [venue]`), pricing the cheap pAMM path
 *   3. fallback route — `toDisablingStateOverride` zeroes the pAMM price slots
 *                      so the router drops to Uniswap V3 — the worst case
 *
 * The gap between (2) and (3) is the under-estimation the SDK's worst-case gas
 * pinning closes: `quote` sees the cheap pAMM route, but if that pAMM is
 * unavailable at execution the tx pays the fallback's (much higher) gas.
 *
 *   pnpm build
 *   node examples/estimate-gas.ts
 *
 * Override with RPC_URL / PRIVATE_KEY / ROUTER_ADDRESS. `amountOutMin` is 0 so
 * the estimate never reverts on slippage regardless of which route it prices.
 * Route 2 forces the venue because on public nodes `eth_simulateV1` doesn't
 * apply the timestamp override the way `eth_call` does, so auto-selection
 * (`swapV1`) would let the pAMM lose `_pickBestVenue` and fall back (see below).
 */
import { ContractClient } from "propamm/client";
import { PropAmmRouter, type SwapOptions } from "propamm/router";
import {
  BEACON_GENESIS_TS,
  OverridesRpcSource,
  SECS_PER_SLOT,
  toDisablingStateOverride,
  toStateOverride,
  type OverridesSnapshot,
} from "propamm/overrides";
import { ETH_SENTINEL, USDC } from "propamm/common/tokens";
import { deadlineIn, parseEther } from "propamm/common/helpers";
import { anvil } from "propamm/common/chains";
import { privateKeyToAccount } from "propamm/common/accounts";
import type { Address, Hash, StateOverride } from "propamm";

/** Canonical block time for a snapshot (genesis + slot*12), matching `quote`. */
function blockTime(snapshot: OverridesSnapshot): bigint | undefined {
  if (snapshot.slot !== undefined) return BEACON_GENESIS_TS + snapshot.slot * SECS_PER_SLOT;
  if (snapshot.timestampNs !== undefined) return snapshot.timestampNs / BigInt(1_000_000_000);
  return undefined;
}

const RPC_URL = process.env.RPC_URL ?? "https://ethereum-rpc.publicnode.com";
// anvil's default funded account #0
const PRIVATE_KEY = (process.env.PRIVATE_KEY ??
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80") as Hash;
// mainnet router deployment
const ROUTER_ADDRESS = (process.env.ROUTER_ADDRESS ??
  "0x4DdF368080CD7946db5b459aD591c350158175e1") as Address;

const account = privateKeyToAccount(PRIVATE_KEY);
const client = ContractClient.fromRpc({ rpcUrl: RPC_URL, chain: anvil, account });
const router = new PropAmmRouter(client, ROUTER_ADDRESS);

const amountIn = parseEther("1");

// One snapshot drives BOTH the quote and the estimate overrides — they must
// agree, or the estimate prices a venue the override doesn't actually cover.
const snapshot = await new OverridesRpcSource().getOverrides();
const pammOverride = toStateOverride(snapshot);
const bn = snapshot.blockNumber;
const ts = blockTime(snapshot);
console.log(`pAMM overrides: ${pammOverride.length} contract(s) @ block ${bn ?? "latest"}`);

const fallbackRouter = await router.fallbackSwapRouter();
const { amountOut, venue } = await router.quote(ETH_SENTINEL, USDC, amountIn, {
  overrides: snapshot,
});
const viaPamm = venue.toLowerCase() !== fallbackRouter.toLowerCase();
console.log(`quote: 1 ETH -> ${amountOut} USDC via ${venue} ${viaPamm ? "(pAMM)" : "(fallback)"}`);

const params = {
  tokenIn: ETH_SENTINEL,
  tokenOut: USDC,
  amountIn,
  amountOutMin: BigInt(0),
  recipient: account.address,
  deadline: deadlineIn(300),
};

// The default account holds no ETH on mainnet, so a value-bearing estimate
// reverts "insufficient funds". Fund it in the sim. Merged into every route's
// override below (it targets the account, the route overrides target venues).
const balanceOverride: StateOverride = [{ address: account.address, balance: parseEther("2") }];

async function estimate(
  label: string,
  opts: SwapOptions,
  routeOverride?: StateOverride,
  blockNumber?: bigint,
  blockTimestamp?: bigint,
) {
  const stateOverride = [...balanceOverride, ...(routeOverride ?? [])];
  try {
    const gas = await router.estimateGasWithStateOverride(
      params,
      opts,
      stateOverride,
      blockNumber,
      blockTimestamp,
    );
    console.log(`${label}: ${gas} gas`);
    return gas;
  } catch (err) {
    console.log(`${label}: estimate reverted (${(err as Error).message.split("\n")[0]})`);
    return undefined;
  }
}

// All estimates pin the snapshot's block + slot-derived timestamp (so a pAMM,
// which validates `block.timestamp` against the state it pushed, is priceable)
// and route through the `eth_simulateV1` estimator — `eth_estimateGas` can't
// override the timestamp.
//
// Route 2 FORCES the venue `quote` picked (`venues: [venue]` → swapViaVenueV1)
// to price the pAMM path. Auto-selection (`swapV1`) is unreliable here: on
// public nodes `eth_simulateV1` doesn't apply `blockOverrides.time` the way
// `eth_call` does, so the pAMM's quote loses inside `_pickBestVenue` and the
// router falls back — even though `quote` (an `eth_call`) selects it. Forcing
// the venue still executes the pAMM swap, which is what we want to price.
await estimate("1. live           ", {}, undefined, bn, ts);
const pamm = await estimate("2. pAMM route     ", { venues: [venue] }, pammOverride, bn, ts);
// Disable the pAMMs by zeroing their pushed price slots — state only, no code
// override — so the router drops to the Uniswap V3 fallback.
const fallback = await estimate(
  "3. fallback route ",
  {},
  toDisablingStateOverride(snapshot),
  bn,
  ts,
);

if (pamm !== undefined && fallback !== undefined) {
  const diff = fallback - pamm;
  const pct =
    pamm === BigInt(0) ? "n/a" : `${(Number((diff * BigInt(10000)) / pamm) / 100).toFixed(2)}%`;
  console.log(
    `\nunder-estimation risk (fallback - pAMM): ${diff >= BigInt(0) ? "+" : ""}${diff} gas (${pct})`,
  );
  if (diff === BigInt(0)) {
    console.log(
      "(pAMM route == fallback: the pAMM wasn't selected at estimate time — the override\n" +
        " snapshot may be stale relative to the node's head, or the venue isn't priceable.)",
    );
  }
}
