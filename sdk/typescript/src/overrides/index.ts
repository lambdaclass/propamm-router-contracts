/**
 * pAMM state-override sources.
 *
 * The proprietary AMMs price off-chain liquidity that mainnet state does not
 * reflect, so plain `eth_call` quotes see stale prices. Titan publishes fresh
 * state overrides through a WebSocket stream and a JSON-RPC method; the
 * sources here consume either one and produce snapshots that the router's
 * quote calls attach to `eth_call` (third parameter, plus a block-number
 * override so venues that check block context don't revert).
 *
 * Both payloads share one shape — top-level metadata plus one entry per pAMM:
 *
 * ```json
 * {
 *   "blockNumber": 24285034,
 *   "0x<pamm>": { "stateOverride": { "0x<contract>": { "stateDiff": { "0x<slot>": "0x<value>" } } } }
 * }
 * ```
 */

import { padHex, type Address, type Hex, type StateOverride } from "viem";
import { BEBOP } from "../common/pamms.js";
import { WsSource } from "../ws-source.js";

/** Storage slot diffs for one contract: slot → value (0x-prefixed, lowercased). */
export type SlotDiffs = Record<Hex, Hex>;
/** Per-contract slot diffs: contract address → slots. */
export type ContractDiffs = Record<Address, SlotDiffs>;

/** A parsed overrides payload: per-pAMM contract diffs plus block context. */
export interface OverridesSnapshot {
  /** Block the overrides were generated against. */
  blockNumber?: bigint;
  /** Generation time in nanoseconds since epoch. */
  timestampNs?: bigint;
  /** pAMM address → contract address → slot diffs. */
  perPamm: Record<Address, ContractDiffs>;
}

/** Anything quotes can pull override snapshots from. */
export interface OverridesSource {
  getOverrides(): Promise<OverridesSnapshot | undefined>;
  close?(): void;
}

export const DEFAULT_OVERRIDES_RPC_URL = "https://rpc.titanbuilder.xyz";
export const DEFAULT_OVERRIDES_WS_URL = "wss://rpc.titanbuilder.xyz/ws/pamm_quote_stream";

/**
 * Bebop prices from a single registry slot. When a snapshot carries no Bebop
 * entry, `toStateOverride` zeroes this slot by default so a stale on-chain
 * Bebop price cannot win a best-quote selection it could never fill.
 */
export const BEBOP_DEFAULT_SLOT: Hex =
  "0x3ca381a3d43d4e593578057c4abe441ad9df02f080defd17d2b6e6190cdcd936";

const ZERO_WORD: Hex = `0x${"0".repeat(64)}`;
const BEBOP_LOWER = BEBOP.toLowerCase() as Address;

const META_KEYS = new Set(["slot", "blockNumber", "block_number", "timestamp"]);

/**
 * Parse a raw overrides payload (a WS frame or the JSON-RPC `result`) into a
 * snapshot: metadata keys are split out, addresses and slots are lowercased,
 * and pAMMs/contracts with empty `stateDiff`s are dropped.
 */
export function parseOverridesMessage(raw: unknown): OverridesSnapshot {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw new Error("overrides message is not a JSON object");
  }
  const message = raw as Record<string, unknown>;

  const perPamm: Record<Address, ContractDiffs> = {};
  for (const [key, payload] of Object.entries(message)) {
    if (META_KEYS.has(key) || !key.startsWith("0x")) continue;
    const contracts = parseContractDiffs(payload);
    if (contracts) {
      perPamm[key.toLowerCase() as Address] = contracts;
    }
  }

  return {
    blockNumber: parseBlockNumber(message["blockNumber"] ?? message["block_number"]),
    timestampNs:
      typeof message["timestamp"] === "number" ? BigInt(message["timestamp"]) : undefined,
    perPamm,
  };
}

function parseContractDiffs(payload: unknown): ContractDiffs | undefined {
  if (typeof payload !== "object" || payload === null) return undefined;
  const overrideMap =
    (payload as Record<string, unknown>)["stateOverride"] ??
    (payload as Record<string, unknown>)["state_override"];
  if (typeof overrideMap !== "object" || overrideMap === null) return undefined;

  const contracts: ContractDiffs = {};
  for (const [address, spec] of Object.entries(overrideMap)) {
    const stateDiff = (spec as Record<string, unknown> | null)?.["stateDiff"];
    if (typeof stateDiff !== "object" || stateDiff === null) continue;
    const slots: SlotDiffs = {};
    for (const [slot, value] of Object.entries(stateDiff)) {
      if (typeof value !== "string") continue;
      slots[slot.toLowerCase() as Hex] = value as Hex;
    }
    if (Object.keys(slots).length > 0) {
      contracts[address.toLowerCase() as Address] = slots;
    }
  }
  return Object.keys(contracts).length > 0 ? contracts : undefined;
}

function parseBlockNumber(value: unknown): bigint | undefined {
  if (typeof value === "number" && Number.isFinite(value)) return BigInt(value);
  if (typeof value === "string" && value !== "") return BigInt(value);
  return undefined;
}

export interface ToStateOverrideOptions {
  /** Restrict to these pAMM entries (default: all in the snapshot). */
  pamms?: readonly Address[];
  /** Inject the Bebop default slot when no Bebop entry is present (default true). */
  bebopDefault?: boolean;
}

/**
 * Merge a snapshot's per-pAMM diffs into viem's `StateOverride` format for
 * `eth_call`. Diffs are merged at slot level when multiple pAMM entries touch
 * the same contract.
 */
export function toStateOverride(
  snapshot: OverridesSnapshot,
  options: ToStateOverrideOptions = {},
): StateOverride {
  const selected = options.pamms?.map((pamm) => pamm.toLowerCase());

  const merged: Record<Address, SlotDiffs> = {};
  let hasBebop = false;
  for (const [pamm, contracts] of Object.entries(snapshot.perPamm)) {
    if (selected && !selected.includes(pamm)) continue;
    if (pamm === BEBOP_LOWER) hasBebop = true;
    for (const [address, slots] of Object.entries(contracts)) {
      merged[address as Address] = { ...merged[address as Address], ...slots };
    }
  }

  if (options.bebopDefault !== false && !hasBebop) {
    merged[BEBOP_LOWER] = { ...merged[BEBOP_LOWER], [BEBOP_DEFAULT_SLOT]: ZERO_WORD };
  }

  return Object.entries(merged).map(([address, slots]) => ({
    address: address as Address,
    stateDiff: Object.entries(slots).map(([slot, value]) => ({
      // RPC payloads may carry unpadded words ("0x1"); viem requires 32 bytes.
      slot: padHex(slot as Hex, { size: 32 }),
      value: padHex(value as Hex, { size: 32 }),
    })),
  }));
}

export interface OverridesRpcSourceOptions {
  /** Titan JSON-RPC endpoint. */
  url?: string;
  /** Custom fetch implementation (defaults to the global `fetch`). */
  fetch?: typeof fetch;
}

/** Fetch-on-demand source: one `titan_getPammStateOverrides` call per `getOverrides()`. */
export class OverridesRpcSource implements OverridesSource {
  private readonly url: string;
  private readonly fetchFn: typeof fetch;

  constructor(options: OverridesRpcSourceOptions = {}) {
    this.url = options.url ?? DEFAULT_OVERRIDES_RPC_URL;
    this.fetchFn = options.fetch ?? fetch;
  }

  async getOverrides(): Promise<OverridesSnapshot> {
    const response = await this.fetchFn(this.url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "titan_getPammStateOverrides",
        params: [],
      }),
    });
    if (!response.ok) {
      throw new Error(`overrides RPC request failed with status ${response.status}`);
    }

    const body = (await response.json()) as {
      result?: unknown;
      error?: { code?: number; message?: string };
    };
    if (body.error) {
      throw new Error(`overrides RPC error: ${body.error.message ?? JSON.stringify(body.error)}`);
    }
    return parseOverridesMessage(body.result);
  }
}

export interface OverridesWsSourceOptions {
  /** Titan stream endpoint. */
  url?: string;
  /** How long `getOverrides()` waits for the first frame (default 5000ms). */
  firstFrameTimeoutMs?: number;
  /**
   * Close the socket after this long without a `getOverrides()` call
   * (default 30000ms), so an idle source never keeps the process alive; the
   * next call reconnects transparently. `0` closes right after each call,
   * `Infinity` keeps the stream open until `close()`.
   */
  idleTimeoutMs?: number;
}

/**
 * Streaming source: connects lazily on the first `getOverrides()` call and
 * accumulates per-pAMM entries across frames (a frame only carries the pAMMs
 * it updates), reconnecting with exponential backoff. `getOverrides()`
 * returns the latest accumulated snapshot. The socket auto-closes after
 * `idleTimeoutMs` without calls, so no explicit teardown is needed; `close()`
 * remains available for immediate, permanent teardown.
 */
export class OverridesWsSource extends WsSource<OverridesSnapshot> implements OverridesSource {
  // Mutated in place: frames carry deltas, so entries for absent pAMMs are kept.
  private readonly snapshot: OverridesSnapshot = { perPamm: {} };

  protected override get name() {
    return "overrides";
  }

  constructor(options: OverridesWsSourceOptions = {}) {
    super(options.url ?? DEFAULT_OVERRIDES_WS_URL, options);
  }

  protected override applyFrame(data: string): void {
    const frame = parseOverridesMessage(JSON.parse(data));
    Object.assign(this.snapshot.perPamm, frame.perPamm);
    if (frame.blockNumber !== undefined) this.snapshot.blockNumber = frame.blockNumber;
    if (frame.timestampNs !== undefined) this.snapshot.timestampNs = frame.timestampNs;
  }

  protected override copySnapshot(): OverridesSnapshot {
    return { ...this.snapshot, perPamm: { ...this.snapshot.perPamm } };
  }

  getOverrides(): Promise<OverridesSnapshot> {
    return this.getSnapshot();
  }
}
