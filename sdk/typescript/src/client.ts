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
  /** JSON-RPC endpoint, e.g. `http://localhost:8545`. Required unless a `publicClient` is supplied. */
  rpcUrl?: string;
  /** Target chain (e.g. `mainnet` or `anvil` from `propamm/common/chains`). Required unless prebuilt clients are supplied. */
  chain?: Chain;
  /** Account used to sign transactions. Omit for a read-only client, or when supplying a `walletClient`. */
  account?: Account;
  /**
   * Prebuilt viem public client for reads and `eth_call` simulations. When
   * supplied it is used verbatim and `rpcUrl`/`chain` are ignored for reads.
   */
  publicClient?: PublicClient;
  /**
   * Prebuilt viem wallet client for writes. Supply this to sign through a
   * browser/injected wallet such as MetaMask (e.g. wagmi's `useWalletClient`).
   *
   * Such wallets sign over their own EIP-1193 transport, which a client built
   * from `rpcUrl` cannot reach: a wallet client created with `http(rpcUrl)`
   * sends `eth_sendTransaction` to the RPC node, which holds no key for the
   * user's account and rejects it. Passing the wallet's own client routes the
   * signing request to the wallet instead. The client's bound account is used
   * as the signer (falling back to `account`).
   */
  walletClient?: WalletClient;
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
    // A prebuilt public client (e.g. from wagmi) is used as-is; otherwise build
    // an http client from `rpcUrl`/`chain`.
    if (options.publicClient) {
      this.publicClient = options.publicClient;
    } else {
      if (!options.rpcUrl) {
        throw new Error("ContractClient requires either `publicClient` or `rpcUrl`");
      }
      this.publicClient = createPublicClient({
        chain: options.chain,
        transport: http(options.rpcUrl),
      });
    }

    // A prebuilt wallet client (e.g. an injected/browser wallet from wagmi)
    // signs over its own transport, so it is used verbatim and its bound account
    // is the signer. Otherwise a local `account` gets an http wallet client that
    // signs locally and broadcasts via `rpcUrl`.
    if (options.walletClient) {
      this.walletClient = options.walletClient;
      this.account = options.walletClient.account ?? options.account;
    } else if (options.account) {
      this.account = options.account;
      this.walletClient = createWalletClient({
        account: options.account,
        chain: options.chain,
        transport: http(options.rpcUrl),
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
