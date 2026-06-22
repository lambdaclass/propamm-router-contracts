/**
 * pAMM price-level sources.
 *
 * Alongside the raw state overrides (see `../overrides`), Titan publishes
 * prices it has *already quoted*, grouped per pAMM: for each trading pair an
 * `orderBook` of rungs mapping an input amount to the output it would receive.
 * This lets a taker read prices across a range of trade sizes without running
 * an `eth_call` simulation per size. Rungs come in two flavours — `Simulated`
 * (derived from an EVM simulation of a synthesized taker tx) and `Interpolated`
 * (a linear spline between simulated rungs, for finer granularity).
 *
 * Titan exposes this through a WebSocket stream and three JSON-RPC methods:
 *
 * - `titan_getPammPriceLevels` — the full per-pAMM snapshot (also streamed at
 *   `wss://.../ws/pamm_price_levels` as *complete* snapshots, not deltas).
 * - `titan_getPammQuote` — the best quote across all pAMMs for a size.
 * - `titan_getPammQuoteVenue` — the same, pinned to one venue.
 *
 * The snapshot payload (the JSON-RPC `result` or a WS frame) looks like:
 *
 * ```json
 * {
 *   "slot": 14581462,
 *   "blockNumber": 25345763,
 *   "timestamp": 1781801564588230787,
 *   "pamms": [{
 *     "pamm": "0x5979...",
 *     "pairs": [{
 *       "tokenIn": "0x2260...", "tokenOut": "0xa0b8...",
 *       "orderBook": [{ "amountIn": "0x989680", "amountOut": "0x174b67393", "variant": "Simulated" }]
 *     }]
 *   }]
 * }
 * ```
 */

import { numberToHex, type Address } from "viem";

/** Whether a rung came from an EVM simulation or a spline interpolation. */
export type PriceVariant = "Simulated" | "Interpolated";

/** One rung of a pair's order book: `amountIn` of `tokenIn` quotes `amountOut`. */
export interface PriceLevel {
  amountIn: bigint;
  amountOut: bigint;
  variant: PriceVariant;
}

/** The order book a pAMM quotes for one `tokenIn`/`tokenOut` pair. */
export interface PairPriceLevels {
  tokenIn: Address;
  tokenOut: Address;
  orderBook: PriceLevel[];
}

/** One pAMM's price levels across all the pairs it quotes. */
export interface PammPriceLevels {
  pamm: Address;
  pairs: PairPriceLevels[];
}

/** A parsed price-levels payload: per-pAMM order books plus block context. */
export interface PriceLevelsSnapshot {
  /** Block the levels were generated against. */
  blockNumber?: bigint;
  /** Slot the levels were generated against. */
  slot?: bigint;
  /** Generation time in nanoseconds since epoch. */
  timestampNs?: bigint;
  pamms: PammPriceLevels[];
}

/** A single quote from `titan_getPammQuote` / `titan_getPammQuoteVenue`. */
export interface TitanQuote {
  tokenIn: Address;
  tokenOut: Address;
  amountIn: bigint;
  amountOut: bigint;
  /** pAMM that produced the quote. */
  pamm: Address;
  /** Router associated with the quote. */
  router: Address;
  blockNumber?: bigint;
  slot?: bigint;
  timestampNs?: bigint;
}

/** Anything callers can pull price-level snapshots from. */
export interface PriceLevelsSource {
  getPriceLevels(): Promise<PriceLevelsSnapshot | undefined>;
  close?(): void;
}

export const DEFAULT_PRICE_LEVELS_RPC_URL = "https://rpc.titanbuilder.xyz";
/**
 * Default price-levels stream endpoint. The stream is served from regional
 * hosts (`eu.`, `ap.`, `us.`); override the URL to pick the nearest.
 */
export const DEFAULT_PRICE_LEVELS_WS_URL = "wss://eu.rpc.titanbuilder.xyz/ws/pamm_price_levels";

export interface PriceLevelsOptions {
  /**
   * Source the price-level snapshot (`getPriceLevels`) is pulled from. Defaults
   * to a one-shot `PriceLevelsRpcSource`; pass a `PriceLevelsWsSource` for a
   * live stream. The quote helpers always go over HTTP JSON-RPC and reuse this
   * source when it is already a `PriceLevelsRpcSource`, so a custom endpoint
   * covers both.
   */
  source?: PriceLevelsSource;
}

/**
 * Entry point for Titan's pAMM price levels, structured like `PropAmmRouter`: a
 * single client wrapping a default {@link PriceLevelsSource} that the
 * constructor lets you override.
 *
 * - `getPriceLevels` reads the latest snapshot from the configured source
 *   (one-shot HTTP by default; pass a `PriceLevelsWsSource` to stream).
 * - `getQuote` / `getQuoteVenue` resolve a single size against Titan's latest
 *   snapshot over HTTP JSON-RPC (`titan_getPammQuote` / `titan_getPammQuoteVenue`),
 *   skipping the on-chain `eth_call` that `PropAmmRouter.quote` runs. They are
 *   HTTP-only — the stream pushes snapshots, not quotes — so they always go
 *   through an RPC source.
 */
export class PriceLevels {
  /** Source price-level snapshots are pulled from. */
  readonly source: PriceLevelsSource;
  /** HTTP source backing the quote helpers (the `source` itself when it speaks HTTP). */
  private readonly rpc: PriceLevelsRpcSource;

  constructor(options: PriceLevelsOptions = {}) {
    this.source = options.source ?? new PriceLevelsRpcSource();
    // The quote helpers are HTTP-only. Reuse the snapshot source when it already
    // speaks HTTP (so a custom endpoint covers both); otherwise use the default.
    this.rpc =
      this.source instanceof PriceLevelsRpcSource ? this.source : new PriceLevelsRpcSource();
  }

  /** Latest price-level snapshot from the configured source. */
  getPriceLevels(): Promise<PriceLevelsSnapshot | undefined> {
    return this.source.getPriceLevels();
  }

  /** Best quote across all pAMMs for a size (`titan_getPammQuote`). */
  getQuote(tokenIn: Address, tokenOut: Address, amountIn: bigint): Promise<TitanQuote> {
    return this.rpc.getQuote(tokenIn, tokenOut, amountIn);
  }

  /** Quote from a specific venue for a size (`titan_getPammQuoteVenue`). */
  getQuoteVenue(
    venue: Address,
    tokenIn: Address,
    tokenOut: Address,
    amountIn: bigint,
  ): Promise<TitanQuote> {
    return this.rpc.getQuoteVenue(venue, tokenIn, tokenOut, amountIn);
  }

  /** Tear down the snapshot source (closes the stream socket, if any). The
   * HTTP quote path holds no connection, so there is nothing else to release. */
  close(): void {
    this.source.close?.();
  }
}

const PRICE_VARIANTS = new Set<string>(["Simulated", "Interpolated"]);

/**
 * Parse a raw price-levels payload (a WS frame or the JSON-RPC `result`) into a
 * snapshot: hex amounts become bigints, addresses are lowercased, and pairs or
 * rungs that are malformed (missing fields, unknown variant) are dropped.
 */
export function parsePriceLevelsMessage(raw: unknown): PriceLevelsSnapshot {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw new Error("price-levels message is not a JSON object");
  }
  const message = raw as Record<string, unknown>;

  const rawPamms = Array.isArray(message["pamms"]) ? (message["pamms"] as unknown[]) : [];
  const pamms: PammPriceLevels[] = [];
  for (const entry of rawPamms) {
    const parsed = parsePamm(entry);
    if (parsed) pamms.push(parsed);
  }

  return {
    blockNumber: parseUintField(message["blockNumber"] ?? message["block_number"]),
    slot: parseUintField(message["slot"]),
    // Titan timestamps are nanoseconds, which overflow Number.MAX_SAFE_INTEGER;
    // JSON.parse already coerces them to a (lossy) number, so this is the best
    // we can do without a bigint-aware parser — mirror `overrides` here.
    timestampNs: parseUintField(message["timestamp"]),
    pamms,
  };
}

function parsePamm(entry: unknown): PammPriceLevels | undefined {
  if (typeof entry !== "object" || entry === null) return undefined;
  const record = entry as Record<string, unknown>;
  const pamm = record["pamm"];
  if (typeof pamm !== "string") return undefined;

  const rawPairs = Array.isArray(record["pairs"]) ? (record["pairs"] as unknown[]) : [];
  const pairs: PairPriceLevels[] = [];
  for (const rawPair of rawPairs) {
    const parsed = parsePair(rawPair);
    if (parsed) pairs.push(parsed);
  }

  return { pamm: pamm.toLowerCase() as Address, pairs };
}

function parsePair(entry: unknown): PairPriceLevels | undefined {
  if (typeof entry !== "object" || entry === null) return undefined;
  const record = entry as Record<string, unknown>;
  const tokenIn = record["tokenIn"];
  const tokenOut = record["tokenOut"];
  if (typeof tokenIn !== "string" || typeof tokenOut !== "string") return undefined;

  const rawBook = Array.isArray(record["orderBook"]) ? (record["orderBook"] as unknown[]) : [];
  const orderBook: PriceLevel[] = [];
  for (const rung of rawBook) {
    const parsed = parseLevel(rung);
    if (parsed) orderBook.push(parsed);
  }

  return {
    tokenIn: tokenIn.toLowerCase() as Address,
    tokenOut: tokenOut.toLowerCase() as Address,
    orderBook,
  };
}

function parseLevel(entry: unknown): PriceLevel | undefined {
  if (typeof entry !== "object" || entry === null) return undefined;
  const record = entry as Record<string, unknown>;
  const amountIn = parseHexAmount(record["amountIn"]);
  const amountOut = parseHexAmount(record["amountOut"]);
  const variant = record["variant"];
  if (amountIn === undefined || amountOut === undefined) return undefined;
  if (typeof variant !== "string" || !PRICE_VARIANTS.has(variant)) return undefined;
  return { amountIn, amountOut, variant: variant as PriceVariant };
}

function parseHexAmount(value: unknown): bigint | undefined {
  if (typeof value !== "string" || value === "") return undefined;
  try {
    return BigInt(value);
  } catch {
    return undefined;
  }
}

function parseUintField(value: unknown): bigint | undefined {
  if (typeof value === "number" && Number.isFinite(value)) return BigInt(Math.trunc(value));
  if (typeof value === "string" && value !== "") {
    try {
      return BigInt(value);
    } catch {
      return undefined;
    }
  }
  return undefined;
}

/** Find a pAMM's order book for a pair within a snapshot (addresses are case-insensitive). */
export function findPair(
  snapshot: PriceLevelsSnapshot,
  pamm: Address,
  tokenIn: Address,
  tokenOut: Address,
): PairPriceLevels | undefined {
  const wantPamm = pamm.toLowerCase();
  const wantIn = tokenIn.toLowerCase();
  const wantOut = tokenOut.toLowerCase();
  return snapshot.pamms
    .find((entry) => entry.pamm === wantPamm)
    ?.pairs.find((pair) => pair.tokenIn === wantIn && pair.tokenOut === wantOut);
}

function parseTitanQuote(raw: unknown): TitanQuote {
  if (typeof raw !== "object" || raw === null) {
    throw new Error("price-levels quote result is not a JSON object");
  }
  const record = raw as Record<string, unknown>;
  const tokenIn = record["tokenIn"];
  const tokenOut = record["tokenOut"];
  const pamm = record["pamm"];
  const router = record["router"];
  const amountIn = parseHexAmount(record["amountIn"]);
  const amountOut = parseHexAmount(record["amountOut"]);
  if (
    typeof tokenIn !== "string" ||
    typeof tokenOut !== "string" ||
    typeof pamm !== "string" ||
    typeof router !== "string" ||
    amountIn === undefined ||
    amountOut === undefined
  ) {
    throw new Error("price-levels quote result is missing required fields");
  }
  return {
    tokenIn: tokenIn.toLowerCase() as Address,
    tokenOut: tokenOut.toLowerCase() as Address,
    amountIn,
    amountOut,
    pamm: pamm.toLowerCase() as Address,
    router: router.toLowerCase() as Address,
    blockNumber: parseUintField(record["blockNumber"] ?? record["block_number"]),
    slot: parseUintField(record["slot"]),
    timestampNs: parseUintField(record["timestamp"]),
  };
}

export interface PriceLevelsRpcSourceOptions {
  /** Titan JSON-RPC endpoint. */
  url?: string;
  /** Custom fetch implementation (defaults to the global `fetch`). */
  fetch?: typeof fetch;
}

/**
 * Fetch-on-demand source over Titan's JSON-RPC endpoint. Besides the price-level
 * snapshot it exposes the two quote helpers, which share the same endpoint and
 * are served from the latest snapshot (so they skip the on-chain `eth_call` that
 * `PropAmmRouter.quote` runs).
 */
export class PriceLevelsRpcSource implements PriceLevelsSource {
  private readonly url: string;
  private readonly fetchFn: typeof fetch;

  constructor(options: PriceLevelsRpcSourceOptions = {}) {
    this.url = options.url ?? DEFAULT_PRICE_LEVELS_RPC_URL;
    this.fetchFn = options.fetch ?? fetch;
  }

  /** Latest full snapshot via `titan_getPammPriceLevels`. */
  async getPriceLevels(): Promise<PriceLevelsSnapshot> {
    return parsePriceLevelsMessage(await this.rpc("titan_getPammPriceLevels", []));
  }

  /** Best quote across all pAMMs via `titan_getPammQuote`. */
  async getQuote(tokenIn: Address, tokenOut: Address, amountIn: bigint): Promise<TitanQuote> {
    return parseTitanQuote(
      await this.rpc("titan_getPammQuote", [tokenIn, tokenOut, numberToHex(amountIn)]),
    );
  }

  /** Quote from a specific venue via `titan_getPammQuoteVenue`. */
  async getQuoteVenue(
    venue: Address,
    tokenIn: Address,
    tokenOut: Address,
    amountIn: bigint,
  ): Promise<TitanQuote> {
    return parseTitanQuote(
      await this.rpc("titan_getPammQuoteVenue", [venue, tokenIn, tokenOut, numberToHex(amountIn)]),
    );
  }

  private async rpc(method: string, params: readonly unknown[]): Promise<unknown> {
    const response = await this.fetchFn(this.url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    });
    if (!response.ok) {
      throw new Error(`price-levels RPC request failed with status ${response.status}`);
    }

    const body = (await response.json()) as {
      result?: unknown;
      error?: { code?: number; message?: string };
    };
    if (body.error) {
      throw new Error(
        `price-levels RPC error: ${body.error.message ?? JSON.stringify(body.error)}`,
      );
    }
    return body.result;
  }
}

export interface PriceLevelsWsSourceOptions {
  /** Titan stream endpoint. */
  url?: string;
  /** How long `getPriceLevels()` waits for the first frame (default 5000ms). */
  firstFrameTimeoutMs?: number;
  /**
   * Close the socket after this long without a `getPriceLevels()` call
   * (default 30000ms), so an idle source never keeps the process alive; the
   * next call reconnects transparently. `0` closes right after each call,
   * `Infinity` keeps the stream open until `close()`.
   */
  idleTimeoutMs?: number;
}

const RECONNECT_INITIAL_MS = 1_000;
const RECONNECT_MAX_MS = 30_000;

/**
 * Streaming source: connects lazily on the first `getPriceLevels()` call and
 * reconnects with exponential backoff. Unlike the overrides stream, each
 * price-levels frame is a *complete* snapshot, so a frame replaces the cached
 * one outright. The socket auto-closes after `idleTimeoutMs` without calls, so
 * no explicit teardown is needed; `close()` remains available for immediate,
 * permanent teardown.
 */
export class PriceLevelsWsSource implements PriceLevelsSource {
  private readonly url: string;
  private readonly firstFrameTimeoutMs: number;
  private readonly idleTimeoutMs: number;

  private ws?: WebSocket;
  private closed = false;
  private reconnectAttempts = 0;
  private reconnectTimer?: ReturnType<typeof setTimeout>;
  private idleTimer?: ReturnType<typeof setTimeout>;

  private snapshot: PriceLevelsSnapshot = { pamms: [] };
  private hasFrame = false;
  private frameWaiters: Array<{ resolve: () => void; reject: (error: Error) => void }> = [];

  constructor(options: PriceLevelsWsSourceOptions = {}) {
    this.url = options.url ?? DEFAULT_PRICE_LEVELS_WS_URL;
    this.firstFrameTimeoutMs = options.firstFrameTimeoutMs ?? 5_000;
    this.idleTimeoutMs = options.idleTimeoutMs ?? 30_000;
  }

  async getPriceLevels(): Promise<PriceLevelsSnapshot> {
    if (this.closed) {
      throw new Error("price-levels source is closed");
    }

    try {
      this.connect();
      if (!this.hasFrame) {
        await this.waitForFirstFrame();
      }
      // Hand out a copy so a later frame can't mutate the caller's snapshot.
      return { ...this.snapshot, pamms: [...this.snapshot.pamms] };
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
    this.failWaiters(new Error("price-levels source closed while waiting for the first frame"));
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
   * next `getPriceLevels()` call. `hasFrame` resets so the next call waits for
   * a fresh complete snapshot instead of serving a stale one.
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

    let frame: PriceLevelsSnapshot;
    try {
      frame = parsePriceLevelsMessage(JSON.parse(data));
    } catch {
      return; // skip undecodable frames, like the reference consumers do
    }

    // Each frame is a complete snapshot, so it replaces the cached one.
    this.snapshot = frame;
    this.hasFrame = true;
    const waiters = this.frameWaiters;
    this.frameWaiters = [];
    for (const waiter of waiters) waiter.resolve();
  }

  private async waitForFirstFrame(): Promise<void> {
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.frameWaiters = this.frameWaiters.filter((w) => w !== waiter);
        reject(new Error(`no price-levels frame received within ${this.firstFrameTimeoutMs}ms`));
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
