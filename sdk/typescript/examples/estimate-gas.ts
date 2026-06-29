/**
 * Show, per pAMM (Fermi and Kipseli), how the gas and executed venue of a
 * `swapViaVenueV1` change under three state overrides — via `eth_simulateV1`,
 * the only estimator that can override `block.timestamp` (which a pAMM validates
 * against its pushed state). All runs force the same venue and pin one Titan
 * snapshot's block + slot timestamp; only the override differs:
 *
 *   no overrides       — none; the venue can't price, so the router falls back
 *   overrides          — the SDK's real pAMM overrides, making the venue priceable
 *   modified overrides — `toDisablingStateOverride` zeroes the price slots, so
 *                        the router drops to the Uniswap V3 fallback
 *
 *   pnpm build
 *   node examples/estimate-gas.ts
 *
 * Override with RPC_URL / PRIVATE_KEY / ROUTER_ADDRESS. `amountOutMin` is 0 so
 * the estimate never reverts on slippage regardless of which route it prices.
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
import { BEBOP, FERMI, KIPSELI } from "propamm/common/pamms";
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

const amountIn = parseEther("0.1");

// One snapshot drives BOTH the quote and the estimate overrides — they must
// agree, or the estimate prices a venue the override doesn't actually cover.
const snapshot = await new OverridesRpcSource().getOverrides();
// Zero out Bebop: drop any pushed Bebop entry so `bebopDefault` zeroes its
// registry slot — a stale on-chain Bebop price can't win a quote it can't fill.
delete snapshot.perPamm[BEBOP.toLowerCase() as Address];
const pammOverride = toStateOverride(snapshot);
const bn = snapshot.blockNumber;
const ts = blockTime(snapshot);
console.log(`pAMM overrides: ${pammOverride.length} contract(s) @ block ${bn ?? "latest"}`);

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

// The three simulations: same venue set + block context, only the state
// override differs — isolating the override's effect on gas and executed venue.
const SIMULATIONS = [
  { name: "no overrides      ", override: undefined as StateOverride | undefined },
  { name: "overrides         ", override: pammOverride },
  { name: "modified overrides", override: toDisablingStateOverride(snapshot) },
];

const VENUES: { name: string; address: Address }[] = [
  { name: "Fermi", address: FERMI },
  { name: "Kipseli", address: KIPSELI },
];

// Force the requested venue (`venues: [address]` → swapViaVenueV1) and route
// through `eth_simulateV1` (pinned block + timestamp), since `eth_estimateGas`
// can't override `block.timestamp`, which a pAMM validates against pushed state.
for (const { name, address } of VENUES) {
  console.log(`\n${name} (${address})`);
  const opts: SwapOptions = { venues: [address] };
  for (const sim of SIMULATIONS) {
    const stateOverride = [...balanceOverride, ...(sim.override ?? [])];
    try {
      const { gas, executedVenue } = await router.estimateGasWithStateOverride(
        params,
        opts,
        stateOverride,
        bn,
        ts,
      );
      console.log(
        `Simulation: ${sim.name} - gas consumed: ${gas} - requested venue: ${address} - executed venue: ${executedVenue}`,
      );
    } catch (err) {
      console.log(`Simulation: ${sim.name} - reverted (${(err as Error).message.split("\n")[0]})`);
    }
  }
}
