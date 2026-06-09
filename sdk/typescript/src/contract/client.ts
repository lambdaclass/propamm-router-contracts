/**
 * Thin wrappers around viem for reading from and writing to contracts.
 *
 * Domain-specific bindings (router, access manager, ...) should be built on
 * top of `ContractClient.read` / `ContractClient.write` with their own ABIs.
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  type Abi,
  type Account,
  type Address,
  type Chain,
  type Hash,
  type PublicClient,
  type WalletClient,
} from "viem";

export interface ContractClientOptions {
  /** JSON-RPC endpoint, e.g. `http://localhost:8545`. */
  rpcUrl: string;
  /** Target chain (e.g. `mainnet` or `anvil` from `viem/chains`). */
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
