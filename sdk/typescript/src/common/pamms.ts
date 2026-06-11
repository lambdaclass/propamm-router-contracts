import type { Address } from "viem";

// PropAMM venues seeded into the router whitelist at initialization.
export const FERMI: Address = "0x5979458912F80B96d30D4220af8E2e4925A33320";
export const BEBOP: Address = "0x160141A205F5dDcf096BA3F48B7eD21EB52c62EA";
export const KIPSELI: Address = "0x71e790dd841c8A9061487cb3E78C288E75cE0B3d";

/**
 * Curated propAMM name → venue address mapping, for the `venues` option of
 * quotes and swaps.
 *
 * The Uniswap V3 fallback is intentionally absent: its address is router
 * configuration, read it via `PropAmmRouter.fallbackSwapRouter()`.
 */
export const PAMMS = {
  fermi: FERMI,
  bebop: BEBOP,
  kipseli: KIPSELI,
} as const satisfies Record<string, Address>;

export type PammName = keyof typeof PAMMS;
