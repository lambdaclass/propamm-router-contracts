import type { Address } from "viem";

// PropAMM venues listed on the router whitelist via `addVenue`.
export const FERMI: Address = "0x5979458912F80B96d30D4220af8E2e4925A33320";
export const BEBOP: Address = "0xB09AAA8933626d7E4C48D65dAd2D77021CFBCA9a";
export const KIPSELI: Address = "0x71e790dd841c8A9061487cb3E78C288E75cE0B3d";
export const TEMPEST: Address = "0x00000003f1ec2379e79F58E12EC6C4F51Ee92149";
export const TAURUSFI: Address = "0x3ce2672Aa806138585920421406Bf0dEcB8130Cb";
export const METRIC: Address = "0xE715Dc29d2c273D0FC5A03e5Cca9CcB0Abb1dCDB";
export const EL_ZORRO: Address = "0xCF211B4dD0D2be5C173Ea57Bcf938FC61d1d3bd3";
export const STELAXIS: Address = "0x77047Af6CD8f7f84d96A020a2833d24916b75FDE";

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
  tempest: TEMPEST,
  taurusfi: TAURUSFI,
  metric: METRIC,
  elzorro: EL_ZORRO,
  stelaxis: STELAXIS,
} as const satisfies Record<string, Address>;

export type PammName = keyof typeof PAMMS;
