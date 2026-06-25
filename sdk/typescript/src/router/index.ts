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
  BEACON_GENESIS_TS,
  OverridesWsSource,
  SECS_PER_SLOT,
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
  /** Minimum acceptable amount of `tokenOut` (net of the frontend fee, when one is passed). */
  amountOutMin: bigint;
  /** Address that receives `tokenOut`. */
  recipient: Address;
  /** Unix timestamp after which the swap is no longer valid (see `deadlineIn`). */
  deadline: bigint;
}

/** Frontend fee skimmed from a swap's output — pass via `SwapOptions.frontendFee`. */
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
  /**
   * Restrict the quote to these venues: a single entry quotes that venue
   * directly, several pick the best among them. Must be non-empty when
   * present; omit to quote across every whitelisted venue.
   */
  venues?: readonly Address[];
}

/** Per-swap options. */
export interface SwapOptions {
  /**
   * Restrict the swap to these venues: a single entry executes through that
   * venue directly (reverting `UnknownVenue` on a bad address), several
   * re-quote on-chain and fill via the best of them (unpriceable entries are
   * skipped). Must be non-empty when present; omit to swap through the
   * best-quoting venue overall.
   */
  venues?: readonly Address[];
  /**
   * Optional frontend fee skimmed from the output. When present the swap is
   * routed through the contract's `WithFee` selector; `bps` must be an
   * integer in [1, `MAX_FEE_BPS`] and the recipient non-zero (validated
   * before sending).
   */
  frontendFee?: FrontendFee;
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

/** Maximum frontend fee accepted by the router, in bps. */
export const MAX_FEE_BPS = 100;

/**
 * Mainnet address of the deployed `PropAMMRouter` proxy — the default target
 * the constructor binds to when no address is given. Pass an explicit address
 * (e.g. a testnet or local-fork deployment) to override it.
 */
export const MAINNET_ROUTER: Address = "0x4DdF368080CD7946db5b459aD591c350158175e1";

export class PropAmmRouter {
  readonly address: Address;
  readonly client: ContractClient;
  /** Source of pAMM state overrides quotes apply by default. */
  readonly overrides: OverridesSource;

  /**
   * @param address Router proxy to bind to; defaults to the mainnet deployment
   * (`MAINNET_ROUTER`).
   */
  constructor(
    client: ContractClient,
    address: Address = MAINNET_ROUTER,
    options: PropAmmRouterOptions = {},
  ) {
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

  /**
   * Best quote across all whitelisted venues and the Uniswap V3 fallback, or
   * across `opts.venues` only. Restricted quotes fall back to the Uniswap V3
   * quote (reporting the fallback router as `venue`) when no listed venue can
   * be priced.
   */
  async quote(
    tokenIn: Address,
    tokenOut: Address,
    amountIn: bigint,
    opts?: QuoteOptions,
  ): Promise<Quote> {
    const { mode, venueArgs } = venueDispatch(opts?.venues);
    const [amountOut, venue] = await this.callRouter<[bigint, Address]>(
      QUOTE_SELECTORS[mode],
      [...venueArgs, tokenIn, tokenOut, amountIn],
      await this.resolveOverrides(opts),
    );
    return { amountOut, venue };
  }

  //-------//
  // Swaps //
  //-------//
  // ETH input: when `tokenIn` is `ETH_SENTINEL` the router expects
  // `msg.value == amountIn`; the bindings attach it automatically. ERC-20
  // input requires a prior allowance for the router (see `approve`).

  /**
   * Swap through the best-quoting venue, or through `opts.venues` only (see
   * `SwapOptions.venues` for the single- vs multi-entry semantics).
   * `opts.frontendFee` routes the call through the contract's `WithFee`
   * selector, which skims the fee from the output.
   */
  async swap(params: SwapParams, opts: SwapOptions = {}): Promise<Hash> {
    const { mode, venueArgs } = venueDispatch(opts.venues);
    const fee = opts.frontendFee;
    if (fee) validateFee(fee);

    const selectors = SWAP_SELECTORS[mode];
    return this.client.write({
      address: this.address,
      abi: propAmmRouterAbi,
      // The `WithFee` selectors take the same tuple plus the fee struct last.
      functionName: fee ? selectors.withFee : selectors.plain,
      args: [
        ...venueArgs,
        params.tokenIn,
        params.tokenOut,
        params.amountIn,
        params.amountOutMin,
        params.recipient,
        params.deadline,
        ...(fee ? [fee] : []),
      ],
      // Native-ETH input is signalled by the sentinel and paid via msg.value.
      value: isAddressEqual(params.tokenIn, ETH_SENTINEL) ? params.amountIn : undefined,
    });
  }

  /** Same as `swap`, but waits for the receipt and decodes the result. */
  async swapAndWait(params: SwapParams, opts: SwapOptions = {}): Promise<SwapResult> {
    return this.waitForSwap(await this.swap(params, opts));
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
   * revert when the simulated block context doesn't match their pushed state.
   * The timestamp is the slot's canonical block time (`genesis + slot*12`),
   * falling back to the emit time when no slot is present; venues validate
   * `block.timestamp` against the state they pushed, which is keyed to the slot,
   * not to the frame's emit time.
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
      blockTimestamp: blockTimeSecs(snapshot),
    };
  }
}

/**
 * Canonical block time (seconds) for a snapshot: derived from the beacon slot
 * (`genesis + slot*12`), falling back to the emit timestamp when no slot is
 * present, or `undefined` when neither is known.
 */
function blockTimeSecs(snapshot: OverridesSnapshot): bigint | undefined {
  if (snapshot.slot !== undefined) return BEACON_GENESIS_TS + snapshot.slot * SECS_PER_SLOT;
  if (snapshot.timestampNs !== undefined) return snapshot.timestampNs / 1_000_000_000n;
  return undefined;
}

/** Quote selector per venue-restriction mode. */
const QUOTE_SELECTORS = {
  all: "quoteV1",
  single: "quoteVenueV1",
  selected: "quoteSelectedVenuesV1",
} as const;

/** Swap selector pairs (plain / frontend-fee) per venue-restriction mode. */
const SWAP_SELECTORS = {
  all: { plain: "swapV1", withFee: "swapWithFeeV1" },
  single: { plain: "swapViaVenueV1", withFee: "swapViaVenueWithFeeV1" },
  selected: { plain: "swapViaSelectedVenuesV1", withFee: "swapViaSelectedVenuesWithFeeV1" },
} as const;

/**
 * Resolve a venue restriction into the selector mode and its leading args: a
 * single venue targets the direct `Venue` entrypoint, several the
 * `SelectedVenues` one. Empty restrictions throw — omit `venues` instead.
 */
function venueDispatch(venues: readonly Address[] | undefined): {
  mode: keyof typeof QUOTE_SELECTORS;
  venueArgs: readonly unknown[];
} {
  if (venues === undefined) return { mode: "all", venueArgs: [] };
  if (venues.length === 0) {
    throw new RangeError("venues must not be empty — omit it to use every whitelisted venue");
  }
  if (venues.length === 1) return { mode: "single", venueArgs: [venues[0]] };
  return { mode: "selected", venueArgs: [venues] };
}

function isOverridesSource(value: OverridesSource | OverridesSnapshot): value is OverridesSource {
  return typeof (value as OverridesSource).getOverrides === "function";
}

/** Throws unless the fee has an integer bps in [1, MAX_FEE_BPS] and a non-zero recipient. */
function validateFee(fee: FrontendFee): void {
  if (!Number.isInteger(fee.bps) || fee.bps < 1 || fee.bps > MAX_FEE_BPS) {
    throw new RangeError(`fee bps must be an integer in [1, ${MAX_FEE_BPS}], got ${fee.bps}`);
  }
  if (isAddressEqual(fee.recipient, zeroAddress)) {
    throw new RangeError("fee recipient must not be the zero address");
  }
}
