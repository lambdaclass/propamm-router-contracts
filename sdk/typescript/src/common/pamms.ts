import type { Address } from "viem";

// PropAMM venues seeded into the router whitelist at initialization.
export const FERMI_ROUTER: Address = "0xb1076fE3AB5e28005C7c323Bac5AC06a680d452e";
export const BEBOP_ROUTER: Address = "0x160141A205F5dDcf096BA3F48B7eD21EB52c62EA";
export const KIPSELI_ROUTER: Address = "0x71e790dd841c8A9061487cb3E78C288E75cE0B3d";

/**
 * Curated propAMM name → venue address mapping, for the venue arguments of
 * `quoteVenue` / `swapViaVenue` / `quoteSelectedVenues` / `swapViaSelectedVenues`.
 *
 * The Uniswap V3 fallback is intentionally absent: its address is router
 * configuration, read it via `PropAmmRouter.fallbackSwapRouter()`.
 */
export const PAMMS = {
  fermi: FERMI_ROUTER,
  bebop: BEBOP_ROUTER,
  kipseli: KIPSELI_ROUTER,
} as const satisfies Record<string, Address>;

export type PammName = keyof typeof PAMMS;
