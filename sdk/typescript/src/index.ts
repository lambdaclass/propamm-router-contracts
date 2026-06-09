export { ApiClient, ApiError } from "./api/http.js";
export type { ApiClientOptions, QueryParams } from "./api/http.js";

export { ContractClient } from "./contract/client.js";
export type {
  ContractClientOptions,
  ReadParams,
  WriteParams,
} from "./contract/client.js";

import { ApiClient, type ApiClientOptions } from "./api/http.js";
import { ContractClient, type ContractClientOptions } from "./contract/client.js";

export interface SdkOptions {
  api: ApiClientOptions;
  contract: ContractClientOptions;
}

export interface Sdk {
  api: ApiClient;
  contract: ContractClient;
}

/** Create an SDK instance wired to both the backend API and the chain. */
export function createSdk(options: SdkOptions): Sdk {
  return {
    api: new ApiClient(options.api),
    contract: new ContractClient(options.contract),
  };
}
