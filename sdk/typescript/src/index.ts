// Slim root: the two entry classes and core types. Everything else lives in
// subpath modules — see @propamm/sdk/router, @propamm/sdk/common/*.
export { ContractClient } from "./client.js";
export type { ContractClientOptions, ReadParams, WriteParams } from "./client.js";

export { PropAmmRouter } from "./router/index.js";
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

export type { Account, Address, Chain, Hash } from "viem";
