// Slim root: the two entry classes and core types. Everything else lives in
// subpath modules — see @propamm/sdk/router, @propamm/sdk/common/*.
export { ContractClient } from "./client.js";
export type { ContractClientOptions, ReadParams, WriteParams } from "./client.js";

export { PropAmmRouter } from "./router/index.js";
export type { FrontendFee, Quote, SwapParams, SwapResult } from "./router/index.js";

export type { Account, Address, Chain, Hash } from "viem";
