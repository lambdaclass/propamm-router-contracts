import type { Address } from "viem";

// PropAMM venues seeded into the router whitelist at initialization.
export const FERMI: Address = "0x5979458912F80B96d30D4220af8E2e4925A33320";
export const BEBOP: Address = "0xdB13ad0fcD134E9c48f2fDaEa8f6751a0F5349ca";
export const KIPSELI: Address = "0x342b8458161137d0203605Fa51E4363c1445ADCD";

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
