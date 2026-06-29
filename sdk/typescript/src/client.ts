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

/**
 * Prebuilt viem clients for {@link ContractClient.fromClients} — the path for a
 * browser/injected wallet such as MetaMask (e.g. wagmi's `usePublicClient` /
 * `useWalletClient`). Such wallets sign over their own EIP-1193 transport,
 * which a client built from `rpcUrl` cannot reach: a wallet client created with
 * `http(rpcUrl)` sends `eth_sendTransaction` to the RPC node, which holds no
 * key for the user's account and rejects it. Passing the wallet's own client
 * routes the signing request to the wallet instead.
 */
export interface ProvidedClients {
  /** Public client for reads and `eth_call` simulations. */
  publicClient: PublicClient;
  /** Wallet client for writes; its bound account is the signer. Omit for a read-only client. */
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
  /**
   * State override for the simulation that derives the gas limit. For `write`
   * it is applied to the `eth_estimateGas` (not the broadcast tx, which can't
   * override state), so the limit can be pinned to a worst-case execution path
   * instead of letting viem auto-estimate the live path at send time — see
   * `PropAmmRouter.swap`. For `call` it is applied to the `eth_call`.
   */
  stateOverride?: StateOverride;
}

export interface CallParams extends WriteParams {
  /** Pin the simulated `block.number` (block override, fourth RPC parameter). */
  blockNumber?: bigint;
  /** Pin the simulated `block.timestamp`, in seconds (block override). */
  blockTimestamp?: bigint;
}

/** bps denominator (100%). */
const BPS_DENOMINATOR = 10_000n;
/**
 * Safety margin added on top of an override-derived gas estimate (+15%), to
 * cover state drift between estimate and inclusion and any gas a real venue
 * burns before reverting that the override path skips.
 */
const GAS_MARGIN_BPS = 1_500n;

export class ContractClient {
  readonly publicClient: PublicClient;
  readonly walletClient?: WalletClient;
  private readonly account?: Account;

  private constructor(publicClient: PublicClient, walletClient?: WalletClient, account?: Account) {
    this.publicClient = publicClient;
    this.walletClient = walletClient;
    this.account = account;
  }

  /**
   * Build a client from an RPC endpoint. With an `account` (a local/private-key
   * account) the wallet client signs locally and broadcasts via `rpcUrl`.
   */
  static fromRpc({ rpcUrl, chain, account }: ContractClientOptions): ContractClient {
    const transport = http(rpcUrl);
    const publicClient = createPublicClient({ chain, transport });
    const walletClient = account ? createWalletClient({ account, chain, transport }) : undefined;
    return new ContractClient(publicClient, walletClient, account);
  }

  /**
   * Build a client from prebuilt viem clients instead of an RPC endpoint — use
   * this to sign through a browser/injected wallet (see {@link ProvidedClients}).
   */
  static fromClients({ publicClient, walletClient }: ProvidedClients): ContractClient {
    return new ContractClient(publicClient, walletClient, walletClient?.account);
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
   *
   * When `params.stateOverride` is supplied, the gas limit is pinned from an
   * `eth_estimateGas` run against that override (plus a safety margin) rather
   * than letting viem auto-estimate the live path at send time — this bounds
   * the cost of a route that diverges between estimate and execution. If that
   * estimate reverts (the worst-case path can't complete, e.g. it can't meet
   * `amountOutMin`), it defers to viem's live estimate.
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

    const gas = params.stateOverride && (await this.estimateGasWithMargin(params));

    return this.walletClient.writeContract(gas ? { ...request, gas } : request);
  }

  /**
   * Gas estimate (with `params.stateOverride` applied) plus a safety margin, or
   * `undefined` when the estimate reverts so the caller can defer to a live
   * auto-estimate.
   */
  private async estimateGasWithMargin(params: WriteParams): Promise<bigint | undefined> {
    try {
      const estimate = await this.estimateGas(params);
      return (estimate * (BPS_DENOMINATOR + GAS_MARGIN_BPS)) / BPS_DENOMINATOR;
    } catch {
      return undefined;
    }
  }

  /**
   * Estimate the gas a transaction would use, optionally against state and
   * block overrides. Mirrors {@link callWithOverrides}: encode the calldata and
   * go through the raw `estimateGas` action so overrides are honored.
   */
  async estimateGas(params: CallParams): Promise<bigint> {
    const calldata = encodeFunctionData({
      abi: params.abi,
      functionName: params.functionName,
      args: params.args ?? [],
    });

    return this.publicClient.estimateGas({
      account: this.account,
      to: params.address,
      data: calldata,
      value: params.value,
      stateOverride: params.stateOverride,
      ...(params.blockNumber !== undefined && { blockNumber: params.blockNumber }),
    });
  }

  /**
   * Estimate gas via `eth_simulateV1`, which (unlike `eth_estimateGas`) accepts
   * block overrides — including `block.timestamp` — and returns `gasUsed`
   * directly in one round-trip, no binary search. Use this to price a route
   * gated on block context (e.g. a pAMM that validates `block.timestamp`
   * against pushed state). Requires a node that implements `eth_simulateV1`.
   * Throws (decoded) if the simulated call reverts.
   */
  async estimateGasViaSimulateV1(params: CallParams): Promise<bigint> {
    const calldata = encodeFunctionData({
      abi: params.abi,
      functionName: params.functionName,
      args: params.args ?? [],
    });

    const blockOverrides =
      params.blockNumber !== undefined || params.blockTimestamp !== undefined
        ? {
            ...(params.blockNumber !== undefined && { number: params.blockNumber }),
            ...(params.blockTimestamp !== undefined && { time: params.blockTimestamp }),
          }
        : undefined;

    const [block] = await this.publicClient.simulateBlocks({
      validation: false,
      blocks: [
        {
          ...(blockOverrides && { blockOverrides }),
          ...(params.stateOverride && { stateOverrides: params.stateOverride }),
          calls: [
            { account: this.account, to: params.address, data: calldata, value: params.value },
          ],
        },
      ],
    });

    const [call] = block.calls;
    if (call.status !== "success") {
      throw call.error ?? new Error(`eth_simulateV1: ${params.functionName} reverted`);
    }
    return call.gasUsed;
  }

  /** Wait until a transaction is mined and return its receipt. */
  async waitForTransaction(hash: Hash) {
    return this.publicClient.waitForTransactionReceipt({ hash });
  }
}
