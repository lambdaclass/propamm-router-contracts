// Slim root: the two entry classes and core types. Everything else lives in
// subpath modules — see propamm/router, propamm/common/*.
export { ContractClient } from "./client.js";
export type { ContractClientOptions, ReadParams, WriteParams } from "./client.js";

export { MAINNET_ROUTER, PropAmmRouter } from "./router/index.js";
export type {
  FrontendFee,
  PropAmmRouterOptions,
  Quote,
  QuoteOptions,
  SwapOptions,
  SwapParams,
  SwapResult,
} from "./router/index.js";

export { OverridesRpcSource, OverridesWsSource } from "./overrides/index.js";
export type { OverridesSnapshot, OverridesSource } from "./overrides/index.js";

export { PriceLevels, PriceLevelsRpcSource, PriceLevelsWsSource } from "./prices/index.js";
export type {
  PairPriceLevels,
  PammPriceLevels,
  PriceLevel,
  PriceLevelsOptions,
  PriceLevelsSnapshot,
  PriceLevelsSource,
  PriceVariant,
  TitanQuote,
} from "./prices/index.js";

export type { Account, Address, Chain, Hash } from "viem";
