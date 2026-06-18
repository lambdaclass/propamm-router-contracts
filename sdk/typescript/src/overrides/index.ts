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

const RECONNECT_INITIAL_MS = 1_000;
const RECONNECT_MAX_MS = 30_000;

/**
 * Streaming source: connects lazily on the first `getOverrides()` call and
 * accumulates per-pAMM entries across frames (a frame only carries the pAMMs
 * it updates), reconnecting with exponential backoff. `getOverrides()`
 * returns the latest accumulated snapshot. The socket auto-closes after
 * `idleTimeoutMs` without calls, so no explicit teardown is needed; `close()`
 * remains available for immediate, permanent teardown.
 */
export class OverridesWsSource implements OverridesSource {
  private readonly url: string;
  private readonly firstFrameTimeoutMs: number;
  private readonly idleTimeoutMs: number;

  private ws?: WebSocket;
  private closed = false;
  private reconnectAttempts = 0;
  private reconnectTimer?: ReturnType<typeof setTimeout>;
  private idleTimer?: ReturnType<typeof setTimeout>;

  private readonly snapshot: OverridesSnapshot = { perPamm: {} };
  private hasFrame = false;
  private frameWaiters: Array<{ resolve: () => void; reject: (error: Error) => void }> = [];

  constructor(options: OverridesWsSourceOptions = {}) {
    this.url = options.url ?? DEFAULT_OVERRIDES_WS_URL;
    this.firstFrameTimeoutMs = options.firstFrameTimeoutMs ?? 5_000;
    this.idleTimeoutMs = options.idleTimeoutMs ?? 30_000;
  }

  async getOverrides(): Promise<OverridesSnapshot> {
    if (this.closed) {
      throw new Error("overrides source is closed");
    }

    try {
      this.connect();
      if (!this.hasFrame) {
        await this.waitForFirstFrame();
      }
      // Hand out a copy so a later frame can't mutate the caller's snapshot.
      return { ...this.snapshot, perPamm: { ...this.snapshot.perPamm } };
    } finally {
      this.armIdleTimer();
    }
  }

  close(): void {
    this.closed = true;
    this.clearTimer("reconnectTimer");
    this.clearTimer("idleTimer");
    this.ws?.close();
    this.ws = undefined;
    this.failWaiters(new Error("overrides source closed while waiting for the first frame"));
  }

  private connect(): void {
    if (this.ws || this.reconnectTimer || this.closed) return;
    if (typeof WebSocket === "undefined") {
      throw new Error("no global WebSocket available (Node >= 22 or a browser is required)");
    }

    const ws = new WebSocket(this.url);
    this.ws = ws;

    ws.addEventListener("open", () => {
      this.reconnectAttempts = 0;
    });
    ws.addEventListener("message", (event) => {
      this.handleFrame(event.data);
    });
    ws.addEventListener("error", () => {
      // The paired "close" event drives reconnection.
    });
    ws.addEventListener("close", () => {
      if (this.ws !== ws) return;
      this.ws = undefined;
      this.scheduleReconnect();
    });
  }

  private scheduleReconnect(): void {
    if (this.closed || this.reconnectTimer) return;
    const delay = Math.min(RECONNECT_INITIAL_MS * 2 ** this.reconnectAttempts, RECONNECT_MAX_MS);
    this.reconnectAttempts += 1;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined;
      this.connect();
    }, delay);
    unrefTimer(this.reconnectTimer);
  }

  /** (Re)start the idle countdown; unref'd so it never pins the process. */
  private armIdleTimer(): void {
    this.clearTimer("idleTimer");
    if (this.closed || !Number.isFinite(this.idleTimeoutMs)) return;
    this.idleTimer = setTimeout(() => {
      this.idleTimer = undefined;
      this.idleClose();
    }, this.idleTimeoutMs);
    unrefTimer(this.idleTimer);
  }

  /**
   * Idle teardown: drop the socket (and any reconnection backoff) until the
   * next `getOverrides()` call. The accumulated per-pAMM entries are kept —
   * frames only carry deltas — but `hasFrame` resets so the next call waits
   * for a fresh frame instead of serving a stale snapshot.
   */
  private idleClose(): void {
    if (this.frameWaiters.length > 0) {
      this.armIdleTimer();
      return;
    }
    this.clearTimer("reconnectTimer");
    this.reconnectAttempts = 0;
    const ws = this.ws;
    this.ws = undefined; // cleared first so the close handler doesn't reconnect
    ws?.close();
    this.hasFrame = false;
  }

  private clearTimer(name: "reconnectTimer" | "idleTimer"): void {
    if (this[name] !== undefined) {
      clearTimeout(this[name]);
      this[name] = undefined;
    }
  }

  private handleFrame(data: unknown): void {
    if (typeof data !== "string") return;

    let frame: OverridesSnapshot;
    try {
      frame = parseOverridesMessage(JSON.parse(data));
    } catch {
      return; // skip undecodable frames, like the reference consumers do
    }

    // A frame only carries the pAMMs it updates; entries for other pAMMs
    // stay cached from earlier frames.
    Object.assign(this.snapshot.perPamm, frame.perPamm);
    if (frame.blockNumber !== undefined) this.snapshot.blockNumber = frame.blockNumber;
    if (frame.timestampNs !== undefined) this.snapshot.timestampNs = frame.timestampNs;

    this.hasFrame = true;
    const waiters = this.frameWaiters;
    this.frameWaiters = [];
    for (const waiter of waiters) waiter.resolve();
  }

  private async waitForFirstFrame(): Promise<void> {
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.frameWaiters = this.frameWaiters.filter((w) => w !== waiter);
        reject(new Error(`no overrides frame received within ${this.firstFrameTimeoutMs}ms`));
      }, this.firstFrameTimeoutMs);
      const waiter = {
        resolve: () => {
          clearTimeout(timer);
          resolve();
        },
        reject: (error: Error) => {
          clearTimeout(timer);
          reject(error);
        },
      };
      this.frameWaiters.push(waiter);
    });
  }

  private failWaiters(error: Error): void {
    const waiters = this.frameWaiters;
    this.frameWaiters = [];
    for (const waiter of waiters) waiter.reject(error);
  }
}

// In Node, unref'd timers don't keep the event loop (and thus the process)
// alive; browsers have no such concept, so the call is a no-op there.
function unrefTimer(timer: ReturnType<typeof setTimeout>): void {
  (timer as { unref?: () => void }).unref?.();
}
