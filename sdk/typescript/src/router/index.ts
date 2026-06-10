/**
 * Typed bindings for the `PropAMMRouter` contract, built on the generic
 * `ContractClient` primitives. Method names drop the on-chain `V1` suffix:
 * `router.swap(...)` calls `swapV1`, and so on.
 */

import {
  erc20Abi,
  isAddressEqual,
  parseEventLogs,
  zeroAddress,
  type Address,
  type Hash,
  type StateOverride,
  type TransactionReceipt,
} from "viem";
import { propAmmRouterAbi } from "./abi.js";
import { ETH_SENTINEL } from "../common/tokens.js";
import {
  OverridesWsSource,
  toStateOverride,
  type OverridesSnapshot,
  type OverridesSource,
} from "../overrides/index.js";
import type { ContractClient } from "../client.js";

/** Common parameters shared by every swap entrypoint. */
export interface SwapParams {
  /** Token being sold, or `ETH_SENTINEL` for native ETH. */
  tokenIn: Address;
  /** Token being bought, or `ETH_SENTINEL` for native ETH. */
  tokenOut: Address;
  /** Exact amount of `tokenIn` to sell, in atomic units. */
  amountIn: bigint;
  /** Minimum acceptable amount of `tokenOut` (net of fee, on the `WithFee` paths). */
  amountOutMin: bigint;
  /** Address that receives `tokenOut`. */
  recipient: Address;
  /** Unix timestamp after which the swap is no longer valid (see `deadlineIn`). */
  deadline: bigint;
}

/** Frontend fee for the `swap*WithFee` entrypoints — build with `frontendFee()`. */
export interface FrontendFee {
  bps: number;
  recipient: Address;
}

/** Result of an on-chain quote: best output and the venue that produced it. */
export interface Quote {
  amountOut: bigint;
  venue: Address;
}

export interface PropAmmRouterOptions {
  /**
   * Source of pAMM state overrides applied to quote simulations. Defaults to
   * a streaming `OverridesWsSource` (which connects lazily on first use).
   */
  overrides?: OverridesSource;
}

export interface QuoteOptions {
  /**
   * Override source (or a fixed snapshot) for this call. Defaults to the
   * router's attached source; pass `null` to quote without overrides.
   */
  overrides?: OverridesSource | OverridesSnapshot | null;
  /** Inject the Bebop default slot when no Bebop entry is present (default true). */
  bebopDefault?: boolean;
}

/** Decoded outcome of a mined swap (from the `Swapped` event). */
export interface SwapResult {
  hash: Hash;
  receipt: TransactionReceipt;
  amountIn: bigint;
  amountOut: bigint;
  /** The venue that filled, or the Uniswap fallback router address. */
  executedVenue: Address;
  recipient: Address;
  /** Present when the swap charged a frontend fee (`FrontendFeeCharged`). */
  fee?: { recipient: Address; amount: bigint };
}

/** Maximum frontend fee accepted by the `swap*WithFee` entrypoints, in bps. */
export const MAX_FEE_BPS = 100;

/** Validated `FrontendFee` builder. Throws if `bps` exceeds `MAX_FEE_BPS` or the recipient is zero. */
export function frontendFee(bps: number, recipient: Address): FrontendFee {
  if (!Number.isInteger(bps) || bps < 0 || bps > MAX_FEE_BPS) {
    throw new RangeError(`fee bps must be an integer in [0, ${MAX_FEE_BPS}], got ${bps}`);
  }
  if (isAddressEqual(recipient, zeroAddress)) {
    throw new RangeError("fee recipient must not be the zero address");
  }
  return { bps, recipient };
}

export class PropAmmRouter {
  readonly address: Address;
  readonly client: ContractClient;
  /** Source of pAMM state overrides quotes apply by default. */
  readonly overrides: OverridesSource;

  constructor(client: ContractClient, address: Address, options: PropAmmRouterOptions = {}) {
    this.client = client;
    this.address = address;
    this.overrides = options.overrides ?? new OverridesWsSource();
  }

  //--------//
  // Quotes //
  //--------//
  // The quote functions are nonpayable on-chain, so they go through
  // `ContractClient.call` (eth_call simulation) rather than `read`. By
  // default the simulation carries the latest pAMM state overrides (plus
  // their block number) so venues quote fresh off-chain liquidity.

  /** Best quote across all whitelisted venues and the Uniswap V3 fallback. */
  async quote(
    tokenIn: Address,
    tokenOut: Address,
    amountIn: bigint,
    opts?: QuoteOptions,
  ): Promise<Quote> {
    const [amountOut, venue] = await this.callRouter<[bigint, Address]>(
      "quoteV1",
      [tokenIn, tokenOut, amountIn],
      await this.resolveOverrides(opts),
    );
    return { amountOut, venue };
  }

  /**
   * Quote a specific venue. Falls back to the Uniswap V3 quote (reporting the
   * fallback router as `venue`) when the venue cannot be priced.
   */
  async quoteVenue(
    venue: Address,
    tokenIn: Address,
    tokenOut: Address,
    amountIn: bigint,
    opts?: QuoteOptions,
  ): Promise<Quote> {
    const [amountOut, quotedVenue] = await this.callRouter<[bigint, Address]>(
      "quoteVenueV1",
      [venue, tokenIn, tokenOut, amountIn],
      await this.resolveOverrides(opts),
    );
    return { amountOut, venue: quotedVenue };
  }

  /** Best quote among a caller-supplied set of venues. */
  async quoteSelectedVenues(
    venues: readonly Address[],
    tokenIn: Address,
    tokenOut: Address,
    amountIn: bigint,
    opts?: QuoteOptions,
  ): Promise<Quote> {
    const [amountOut, venue] = await this.callRouter<[bigint, Address]>(
      "quoteSelectedVenuesV1",
      [venues, tokenIn, tokenOut, amountIn],
      await this.resolveOverrides(opts),
    );
    return { amountOut, venue };
  }

  /**
   * Quote the Uniswap V3 fallback route directly. Never applies overrides —
   * the fallback quoter only reads live on-chain pool state.
   */
  async quoteUniswapV3(tokenIn: Address, tokenOut: Address, amountIn: bigint): Promise<bigint> {
    return this.callRouter<bigint>("quoteUniswapV3", [tokenIn, tokenOut, amountIn]);
  }

  //-------//
  // Swaps //
  //-------//
  // ETH input: when `tokenIn` is `ETH_SENTINEL` the router expects
  // `msg.value == amountIn`; the bindings attach it automatically. ERC-20
  // input requires a prior allowance for the router (see `approve`).

  /** Swap through the best-quoting venue. */
  async swap(params: SwapParams): Promise<Hash> {
    return this.sendSwap(
      "swapV1",
      [
        params.tokenIn,
        params.tokenOut,
        params.amountIn,
        params.amountOutMin,
        params.recipient,
        params.deadline,
      ],
      params,
    );
  }

  /** Best-venue swap that skims a frontend fee from the output. */
  async swapWithFee(params: SwapParams, fee: FrontendFee): Promise<Hash> {
    return this.sendSwap(
      "swapWithFeeV1",
      [
        params.tokenIn,
        params.tokenOut,
        params.amountIn,
        params.amountOutMin,
        params.recipient,
        params.deadline,
        fee,
      ],
      params,
    );
  }

  /** Swap through an explicit venue (a whitelisted propAMM or the fallback router). */
  async swapViaVenue(venue: Address, params: SwapParams): Promise<Hash> {
    return this.sendSwap(
      "swapViaVenueV1",
      [
        venue,
        params.tokenIn,
        params.tokenOut,
        params.amountIn,
        params.amountOutMin,
        params.recipient,
        params.deadline,
      ],
      params,
    );
  }

  /** Explicit-venue swap that skims a frontend fee from the output. */
  async swapViaVenueWithFee(venue: Address, params: SwapParams, fee: FrontendFee): Promise<Hash> {
    return this.sendSwap(
      "swapViaVenueWithFeeV1",
      [
        venue,
        params.tokenIn,
        params.tokenOut,
        params.amountIn,
        params.amountOutMin,
        params.recipient,
        params.deadline,
        fee,
      ],
      params,
    );
  }

  /** Swap through the best of a caller-supplied set of venues. */
  async swapViaSelectedVenues(venues: readonly Address[], params: SwapParams): Promise<Hash> {
    return this.sendSwap(
      "swapViaSelectedVenuesV1",
      [
        venues,
        params.tokenIn,
        params.tokenOut,
        params.amountIn,
        params.amountOutMin,
        params.recipient,
        params.deadline,
      ],
      params,
    );
  }

  /** Selected-venues swap that skims a frontend fee from the output. */
  async swapViaSelectedVenuesWithFee(
    venues: readonly Address[],
    params: SwapParams,
    fee: FrontendFee,
  ): Promise<Hash> {
    return this.sendSwap(
      "swapViaSelectedVenuesWithFeeV1",
      [
        venues,
        params.tokenIn,
        params.tokenOut,
        params.amountIn,
        params.amountOutMin,
        params.recipient,
        params.deadline,
        fee,
      ],
      params,
    );
  }

  //-----------------//
  // Combined swaps  //
  //-----------------//
  // Same as the methods above, but wait for the receipt and decode the result.

  async swapAndWait(params: SwapParams): Promise<SwapResult> {
    return this.waitForSwap(await this.swap(params));
  }

  async swapWithFeeAndWait(params: SwapParams, fee: FrontendFee): Promise<SwapResult> {
    return this.waitForSwap(await this.swapWithFee(params, fee));
  }

  async swapViaVenueAndWait(venue: Address, params: SwapParams): Promise<SwapResult> {
    return this.waitForSwap(await this.swapViaVenue(venue, params));
  }

  async swapViaVenueWithFeeAndWait(
    venue: Address,
    params: SwapParams,
    fee: FrontendFee,
  ): Promise<SwapResult> {
    return this.waitForSwap(await this.swapViaVenueWithFee(venue, params, fee));
  }

  async swapViaSelectedVenuesAndWait(
    venues: readonly Address[],
    params: SwapParams,
  ): Promise<SwapResult> {
    return this.waitForSwap(await this.swapViaSelectedVenues(venues, params));
  }

  async swapViaSelectedVenuesWithFeeAndWait(
    venues: readonly Address[],
    params: SwapParams,
    fee: FrontendFee,
  ): Promise<SwapResult> {
    return this.waitForSwap(await this.swapViaSelectedVenuesWithFee(venues, params, fee));
  }

  /**
   * Wait until a swap transaction is mined and decode its outcome from the
   * router's `Swapped` (and, when present, `FrontendFeeCharged`) events.
   * Throws if the transaction reverted or emitted no `Swapped` event.
   */
  async waitForSwap(hash: Hash): Promise<SwapResult> {
    const receipt = await this.client.waitForTransaction(hash);
    if (receipt.status !== "success") {
      throw new Error(`swap transaction ${hash} reverted`);
    }

    const routerLogs = receipt.logs.filter((log) => isAddressEqual(log.address, this.address));

    const [swapped] = parseEventLogs({
      abi: propAmmRouterAbi,
      eventName: "Swapped",
      logs: routerLogs,
    });
    if (!swapped) {
      throw new Error(`transaction ${hash} emitted no Swapped event from ${this.address}`);
    }

    const [feeCharged] = parseEventLogs({
      abi: propAmmRouterAbi,
      eventName: "FrontendFeeCharged",
      logs: routerLogs,
    });

    return {
      hash,
      receipt,
      amountIn: swapped.args.amountIn,
      amountOut: swapped.args.amountOut,
      executedVenue: swapped.args.marketMaker,
      recipient: swapped.args.recipient,
      ...(feeCharged && {
        fee: { recipient: feeCharged.args.feeRecipient, amount: feeCharged.args.feeAmount },
      }),
    };
  }

  //--------//
  // ERC-20 //
  //--------//

  /** Approve the router to pull `amount` of `token` from the signer. */
  async approve(token: Address, amount: bigint): Promise<Hash> {
    return this.client.write({
      address: token,
      abi: erc20Abi,
      functionName: "approve",
      args: [this.address, amount],
    });
  }

  /** Current router allowance of `token` granted by `owner`. */
  async allowance(token: Address, owner: Address): Promise<bigint> {
    return this.client.read<bigint>({
      address: token,
      abi: erc20Abi,
      functionName: "allowance",
      args: [owner, this.address],
    });
  }

  //-------//
  // Views //
  //-------//

  /** The Uniswap fallback "venue" address (dynamic router configuration). */
  async fallbackSwapRouter(): Promise<Address> {
    return this.readRouter<Address>("fallbackSwapRouter");
  }

  async fallbackQuoter(): Promise<Address> {
    return this.readRouter<Address>("fallbackQuoter");
  }

  async fallbackFee(): Promise<number> {
    return this.readRouter<number>("fallbackFee");
  }

  /** Raw per-pair fee override (0 if unset). Order-independent. */
  async getPairFee(tokenA: Address, tokenB: Address): Promise<number> {
    return this.readRouter<number>("getPairFee", [tokenA, tokenB]);
  }

  /** Effective Uniswap V3 fallback tier for a pair (override or global). */
  async resolvedFee(tokenIn: Address, tokenOut: Address): Promise<number> {
    return this.readRouter<number>("resolvedFee", [tokenIn, tokenOut]);
  }

  async isWhitelistedVenue(venue: Address): Promise<boolean> {
    return this.readRouter<boolean>("isWhitelistedVenue", [venue]);
  }

  /** Every whitelisted propAMM venue (excludes the Uniswap fallback). */
  async getWhitelistedVenues(): Promise<readonly Address[]> {
    return this.readRouter<readonly Address[]>("getWhitelistedVenues");
  }

  async paused(): Promise<boolean> {
    return this.readRouter<boolean>("paused");
  }

  //-----------//
  // Internals //
  //-----------//

  private async readRouter<T>(functionName: string, args: readonly unknown[] = []): Promise<T> {
    return this.client.read<T>({
      address: this.address,
      abi: propAmmRouterAbi,
      functionName,
      args,
    });
  }

  private async callRouter<T>(
    functionName: string,
    args: readonly unknown[],
    overrides: {
      stateOverride?: StateOverride;
      blockNumber?: bigint;
      blockTimestamp?: bigint;
    } = {},
  ): Promise<T> {
    return this.client.call<T>({
      address: this.address,
      abi: propAmmRouterAbi,
      functionName,
      args,
      ...overrides,
    });
  }

  /**
   * Resolve a quote's override options into eth_call parameters: pick the
   * per-call source/snapshot (or the router's attached source), then flatten
   * the snapshot into viem's state-override format. The snapshot's block
   * number and timestamp are attached only alongside overrides — venues
   * revert when the simulated block context doesn't match their pushed state
   * (the timestamp matters on forks, whose `block.timestamp` lags the
   * snapshot's freshness window).
   */
  private async resolveOverrides(
    opts?: QuoteOptions,
  ): Promise<{ stateOverride?: StateOverride; blockNumber?: bigint; blockTimestamp?: bigint }> {
    const chosen = opts?.overrides === undefined ? this.overrides : opts.overrides;
    if (chosen === null) return {};

    const snapshot = isOverridesSource(chosen) ? await chosen.getOverrides() : chosen;
    if (!snapshot) return {};

    const stateOverride = toStateOverride(snapshot, { bebopDefault: opts?.bebopDefault });
    if (stateOverride.length === 0) return {};

    return {
      stateOverride,
      blockNumber: snapshot.blockNumber,
      blockTimestamp:
        snapshot.timestampNs !== undefined ? snapshot.timestampNs / 1_000_000_000n : undefined,
    };
  }

  private async sendSwap(
    functionName: string,
    args: readonly unknown[],
    params: SwapParams,
  ): Promise<Hash> {
    return this.client.write({
      address: this.address,
      abi: propAmmRouterAbi,
      functionName,
      args,
      // Native-ETH input is signalled by the sentinel and paid via msg.value.
      value: isAddressEqual(params.tokenIn, ETH_SENTINEL) ? params.amountIn : undefined,
    });
  }
}

function isOverridesSource(value: OverridesSource | OverridesSnapshot): value is OverridesSource {
  return typeof (value as OverridesSource).getOverrides === "function";
}
