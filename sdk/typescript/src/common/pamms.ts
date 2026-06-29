import type { Address } from "viem";

// PropAMM venues seeded into the router whitelist at initialization.
export const FERMI: Address = "0x5979458912F80B96d30D4220af8E2e4925A33320";
export const BEBOP: Address = "0xdB13ad0fcD134E9c48f2fDaEa8f6751a0F5349ca";
export const KIPSELI: Address = "0x71e790dd841c8A9061487cb3E78C288E75cE0B3d";

/**
 * The always-available Uniswap V3 fallback venue sentinel (the max address).
 * Pass it as the `venue` to `swapViaVenueV1` / `quoteVenueV1` to select the
 * fallback explicitly. Not a real contract — execution derives the core pool.
 */
export const UNISWAP_V3_FALLBACK: Address = "0xffffffffffffffffffffffffffffffffffffffff";

/**
 * Curated propAMM name → venue address mapping, for the `venues` option of
 * quotes and swaps.
 *
 * The Uniswap V3 fallback is intentionally absent: it is the always-available
 * safety net, selected with the fixed `UNISWAP_V3_FALLBACK` sentinel (the max
 * address, `0xFFFF…FFFF`), not a configurable address.
 */
export const PAMMS = {
  fermi: FERMI,
  bebop: BEBOP,
  kipseli: KIPSELI,
} as const satisfies Record<string, Address>;

export type PammName = keyof typeof PAMMS;
