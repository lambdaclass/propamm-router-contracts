import type { Address } from "viem";

// PropAMM venues listed on the router whitelist via `addVenue`.
export const FERMI: Address = "0x5979458912F80B96d30D4220af8E2e4925A33320";
export const BEBOP: Address = "0xB09AAA8933626d7E4C48D65dAd2D77021CFBCA9a";
export const KIPSELI: Address = "0x71e790dd841c8A9061487cb3E78C288E75cE0B3d";
export const TEMPEST: Address = "0x00000003f1ec2379e79F58E12EC6C4F51Ee92149";
export const TAURUSFI: Address = "0x3ce2672Aa806138585920421406Bf0dEcB8130Cb";
export const METRIC: Address = "0x99Ab7c1C5eab47801F7937075998527a550fbA8a";
export const EL_ZORRO: Address = "0xCF211B4dD0D2be5C173Ea57Bcf938FC61d1d3bd3";
export const STELAXIS: Address = "0x77047Af6CD8f7f84d96A020a2833d24916b75FDE";
export const GOLIATH: Address = "0x4367985A63063fc970b009c6E599e9225181f551";

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
  goliath: GOLIATH,
} as const satisfies Record<string, Address>;

export type PammName = keyof typeof PAMMS;

/**
 * Titan publishes each maker's data under the maker's quote address, which for
 * some makers is not the venue address the router whitelists. This maps those
 * quote addresses (lowercased) to the router venue; makers absent here publish
 * under the venue address itself. Source: the stream-address table in Titan's
 * takers docs.
 */
export const QUOTE_ADDRESS_VENUES: Readonly<Record<string, Address>> = {
  // Kipseli
  "0xc9a956b5196dfe110debe8781857bc8b97d32091": KIPSELI,
  // Metric publishes under two quote addresses; its venue needs both.
  "0xe844701934d9c6085b292e428f41b911cc0b3872": METRIC,
  "0x30a88bf894d1b806125a23ebf23d715496fd7102": METRIC,
};
