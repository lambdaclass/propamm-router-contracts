/**
 * Thin wrappers around viem for reading from and writing to contracts.
 *
 * Domain-specific bindings (router, ...) are built on top of
 * `ContractClient.read` / `call` / `write` with their own ABIs.
 */

import {
  createPublicClient,
  createWalletClient,
  decodeFunctionResult,
  encodeFunctionData,
  http,
  type Abi,
  type Account,
  type Address,
  type BaseError,
  type Chain,
  type Hash,
  type PublicClient,
  type StateOverride,
  type WalletClient,
} from "viem";
import { getContractError } from "viem/utils";

export interface ContractClientOptions {
  /** JSON-RPC endpoint, e.g. `http://localhost:8545`. */
  rpcUrl: string;
  /** Target chain (e.g. `mainnet` or `anvil` from `propamm/common/chains`). */
  chain: Chain;
  /** Account used to sign transactions. Omit for a read-only client. */
  account?: Account;
}

export interface ReadParams {
  address: Address;
  abi: Abi;
  functionName: string;
  args?: readonly unknown[];
}

export interface WriteParams extends ReadParams {
  /** ETH value to send along with the call, in wei. */
  value?: bigint;
}

export interface CallParams extends WriteParams {
  /** State overrides applied to the `eth_call` (third RPC parameter). */
  stateOverride?: StateOverride;
  /** Pin the simulated `block.number` (block override, fourth RPC parameter). */
  blockNumber?: bigint;
  /** Pin the simulated `block.timestamp`, in seconds (block override). */
  blockTimestamp?: bigint;
}

export class ContractClient {
  readonly publicClient: PublicClient;
  readonly walletClient?: WalletClient;
  private readonly account?: Account;

  constructor(options: ContractClientOptions) {
    const transport = http(options.rpcUrl);

    this.publicClient = createPublicClient({ chain: options.chain, transport });

    if (options.account) {
      this.account = options.account;
      this.walletClient = createWalletClient({
        account: options.account,
        chain: options.chain,
        transport,
      });
    }
  }

  /** Call a read-only (view/pure) contract function. */
  async read<T = unknown>(params: ReadParams): Promise<T> {
    const result = await this.publicClient.readContract({
      address: params.address,
      abi: params.abi,
      functionName: params.functionName,
      args: params.args ?? [],
    });
    return result as T;
  }

  /**
   * Simulate a state-changing function via `eth_call` and return its result
   * without sending a transaction. Useful for nonpayable functions that are
   * effectively queries (e.g. on-chain quotes). Optionally applies state and
   * block-number overrides to the simulation.
   */
  async call<T = unknown>(params: CallParams): Promise<T> {
    // viem's simulateContract doesn't support overrides, so override-carrying
    // calls go through the raw `call` action with manual encode/decode.
    if (
      params.stateOverride ||
      params.blockNumber !== undefined ||
      params.blockTimestamp !== undefined
    ) {
      return this.callWithOverrides(params);
    }

    const { result } = await this.publicClient.simulateContract({
      account: this.account,
      address: params.address,
      abi: params.abi,
      functionName: params.functionName,
      args: params.args ?? [],
      value: params.value,
    });
    return result as T;
  }

  private async callWithOverrides<T>(params: CallParams): Promise<T> {
    const args = params.args ?? [];
    const calldata = encodeFunctionData({
      abi: params.abi,
      functionName: params.functionName,
      args,
    });

    const blockOverrides =
      params.blockNumber !== undefined || params.blockTimestamp !== undefined
        ? {
            ...(params.blockNumber !== undefined && { number: params.blockNumber }),
            ...(params.blockTimestamp !== undefined && { time: params.blockTimestamp }),
          }
        : undefined;

    let returnData;
    try {
      ({ data: returnData } = await this.publicClient.call({
        account: this.account,
        to: params.address,
        data: calldata,
        value: params.value,
        stateOverride: params.stateOverride,
        blockOverrides,
      }));
    } catch (error) {
      // Re-shape the raw call error so custom contract errors decode by name.
      throw getContractError(error as BaseError, {
        abi: params.abi,
        address: params.address,
        args,
        functionName: params.functionName,
      });
    }

    if (!returnData) {
      throw new Error(`call to ${params.functionName} at ${params.address} returned no data`);
    }
    return decodeFunctionResult({
      abi: params.abi,
      functionName: params.functionName,
      data: returnData,
    }) as T;
  }

  /**
   * Send a state-changing contract call. Simulates first so reverts surface
   * as errors before any gas is spent. Returns the transaction hash.
   */
  async write(params: WriteParams): Promise<Hash> {
    if (!this.walletClient || !this.account) {
      throw new Error("ContractClient was created without an account; writes are unavailable");
    }

    const { request } = await this.publicClient.simulateContract({
      account: this.account,
      address: params.address,
      abi: params.abi,
      functionName: params.functionName,
      args: params.args ?? [],
      value: params.value,
    });

    return this.walletClient.writeContract(request);
  }

  /** Wait until a transaction is mined and return its receipt. */
  async waitForTransaction(hash: Hash) {
    return this.publicClient.waitForTransactionReceipt({ hash });
  }
}
