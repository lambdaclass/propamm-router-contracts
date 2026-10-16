/**
 * pAMM price-level sources.
 *
 * Alongside the raw state overrides (see `../overrides`), Titan publishes
 * prices it has *already quoted*, grouped per pAMM: for each trading pair an
 * `orderBook` of rungs mapping an input amount to the output it would receive.
 * This lets a taker read prices across a range of trade sizes without running
 * an `eth_call` simulation per size.
 *
 * Titan exposes this through a WebSocket stream and three JSON-RPC methods:
 *
 * - `titan_getPammBooks` — the full snapshot (also streamed at
 *   `wss://.../ws/pamm_price_levels_v2` as *complete* snapshots, not deltas).
 * - `titan_getPammQuote` — the best quote across all pAMMs for a size.
 * - `titan_getPammQuoteVenue` — the same, pinned to one venue.
 *
 * The v2 payload carries one book per maker and token pair, in human units:
 *
 * ```json
 * {
 *   "slot": 15436468, "block": 26197444, "ts": 1792061637434840374,
 *   "books": [{
 *     "maker": "Tempest", "quoteAddress": "0x0000...",
 *     "token1Address": "0xc02a...", "token2Address": "0xdac1...",
 *     "bids": [{ "price": 2365.0436, "cumVolume": 0.005 }],
 *     "asks": [{ "price": 2365.526259, "cumVolume": 0.004227389132525372 }]
 *   }]
 * }
 * ```
 *
 * A bid rung sells `cumVolume` of token1 for `cumVolume * price` of token2; an
 * ask rung buys `cumVolume` of token1 for `cumVolume * price` of token2. The
 * parser turns each side into the `tokenIn → tokenOut` order book of base-unit
 * amounts this module has always returned, which needs each token's decimals
 * (see {@link TOKEN_DECIMALS}). Titan sends those numbers as floats, so a
 * rebuilt amount can be a few base units off the exact simulated one. The book
 * is filed under the router venue its quote address maps to
 * ({@link QUOTE_ADDRESS_VENUES}).
 *
 * The v1 payload (`pamms` of hex `amountIn`/`amountOut` rungs) is still
 * parsed, for sources pointed at the deprecated endpoints.
 */

import { createPublicClient, erc20Abi, http, numberToHex, type Address } from "viem";
import { QUOTE_ADDRESS_VENUES } from "../common/pamms.js";
import { TOKEN_DECIMALS } from "../common/tokens.js";
import { WsSource } from "../ws-source.js";

/** Whether a rung came from an EVM simulation or a spline interpolation. */
export type PriceVariant = "Simulated" | "Interpolated";

/** One rung of a pair's order book: `amountIn` of `tokenIn` quotes `amountOut`. */
export interface PriceLevel {
  amountIn: bigint;
  amountOut: bigint;
  /** Only the v1 payload says how a rung was produced. */
  variant?: PriceVariant;
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

/**
 * Default price-levels endpoint. Served from regional hosts (`eu.`, `ap.`,
 * `us.`); override the URL to pick the nearest.
 */
export const DEFAULT_PRICE_LEVELS_RPC_URL = "https://eu.data.titanbuilder.xyz/data";
/**
 * Default price-levels stream endpoint. The stream is served from regional
 * hosts (`eu.`, `ap.`, `us.`); override the URL to pick the nearest.
 */
export const DEFAULT_PRICE_LEVELS_WS_URL = "wss://eu.data.titanbuilder.xyz/ws/pamm_price_levels_v2";

/** How sources learn the decimals of tokens missing from {@link TOKEN_DECIMALS}. */
export interface TokenDecimalsOptions {
  /** Extra or overriding decimals, by token address. */
  decimals?: Record<string, number>;
  /**
   * Ethereum JSON-RPC endpoint. When set, a token in neither table has its
   * `decimals()` read once and cached; otherwise books quoting it are skipped.
   */
  ethRpcUrl?: string;
}

/** Token decimals: the built-in table, caller additions, and cached on-chain reads. */
class TokenDecimals {
  private readonly table: Record<string, number>;
  private readonly client?: ReturnType<typeof createPublicClient>;
  private readonly failed = new Set<string>();

  constructor(options: TokenDecimalsOptions = {}) {
    this.table = { ...TOKEN_DECIMALS };
    for (const [token, decimals] of Object.entries(options.decimals ?? {})) {
      this.table[token.toLowerCase()] = decimals;
    }
    if (options.ethRpcUrl) this.client = createPublicClient({ transport: http(options.ethRpcUrl) });
  }

  /** Read the decimals of the payload's unknown tokens, then return the table. */
  async resolve(raw: unknown): Promise<Record<string, number>> {
    if (this.client) {
      const unknown = bookTokens(raw).filter((t) => !(t in this.table) && !this.failed.has(t));
      await Promise.all(
        unknown.map(async (token) => {
          try {
            const decimals = await this.client!.readContract({
              address: token as Address,
              abi: erc20Abi,
              functionName: "decimals",
            });
            this.table[token] = decimals;
          } catch {
            this.failed.add(token); // not retried: its books stay skipped
          }
        }),
      );
    }
    return this.table;
  }
}

function bookTokens(raw: unknown): string[] {
  const books = (raw as Record<string, unknown> | null)?.["books"];
  if (!Array.isArray(books)) return [];
  const tokens = new Set<string>();
  for (const book of books) {
    for (const key of ["token1Address", "token2Address"]) {
      const token = (book as Record<string, unknown> | null)?.[key];
      if (typeof token === "string") tokens.add(token.toLowerCase());
    }
  }
  return [...tokens];
}

export interface PriceLevelsOptions extends TokenDecimalsOptions {
  /**
   * Source the price-level snapshot (`getPriceLevels`) is pulled from. Defaults
   * to a one-shot `PriceLevelsRpcSource`; pass a `PriceLevelsWsSource` for a
   * live stream.
   */
  source?: PriceLevelsSource;
  /**
   * Titan JSON-RPC endpoint used by the quote helpers (`getQuote` /
   * `getQuoteVenue`). Ignored when `source` is a `PriceLevelsRpcSource` (its
   * URL is reused). Required when pairing a `PriceLevelsWsSource` with a
   * private or regional Titan deployment; defaults to
   * `DEFAULT_PRICE_LEVELS_RPC_URL` otherwise.
   */
  rpcUrl?: string;
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
    const decimals = { decimals: options.decimals, ethRpcUrl: options.ethRpcUrl };
    this.source = options.source ?? new PriceLevelsRpcSource({ url: options.rpcUrl, ...decimals });
    this.rpc =
      this.source instanceof PriceLevelsRpcSource
        ? this.source
        : new PriceLevelsRpcSource({ url: options.rpcUrl, ...decimals });
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
 * Parse a raw price-levels payload (a WS frame or the JSON-RPC `result`, v2 or
 * v1 shape) into a snapshot: amounts become base-unit bigints, addresses are
 * lowercased, and malformed books, pairs or rungs are dropped. A v2 book
 * quoting a token absent from `decimals` (default {@link TOKEN_DECIMALS}) is
 * skipped.
 */
export function parsePriceLevelsMessage(
  raw: unknown,
  decimals: Readonly<Record<string, number>> = TOKEN_DECIMALS,
): PriceLevelsSnapshot {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw new Error("price-levels message is not a JSON object");
  }
  const message = raw as Record<string, unknown>;
  if (Array.isArray(message["books"])) return parseBooks(message, decimals);

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

function parseBooks(
  message: Record<string, unknown>,
  decimals: Readonly<Record<string, number>>,
): PriceLevelsSnapshot {
  const byPamm = new Map<Address, Map<string, PairPriceLevels>>();
  for (const entry of message["books"] as unknown[]) {
    if (typeof entry !== "object" || entry === null) continue;
    const book = entry as Record<string, unknown>;
    const quoteAddress = book["quoteAddress"];
    const token1 = book["token1Address"];
    const token2 = book["token2Address"];
    if (
      typeof quoteAddress !== "string" ||
      typeof token1 !== "string" ||
      typeof token2 !== "string"
    )
      continue;
    const t1 = token1.toLowerCase() as Address;
    const t2 = token2.toLowerCase() as Address;
    const d1 = decimals[t1];
    const d2 = decimals[t2];
    if (d1 === undefined || d2 === undefined) continue;

    const qa = quoteAddress.toLowerCase();
    const pamm = (QUOTE_ADDRESS_VENUES[qa]?.toLowerCase() ?? qa) as Address;
    const pairs = byPamm.get(pamm) ?? new Map<string, PairPriceLevels>();
    byPamm.set(pamm, pairs);

    // Bids: sell cumVolume of token1, receive cumVolume*price of token2.
    const bids = parseRungs(book["bids"], (volume, quote) => ({
      amountIn: toBaseUnits(volume, d1),
      amountOut: toBaseUnits(quote, d2),
    }));
    // Asks: pay cumVolume*price of token2, receive cumVolume of token1.
    const asks = parseRungs(book["asks"], (volume, quote) => ({
      amountIn: toBaseUnits(quote, d2),
      amountOut: toBaseUnits(volume, d1),
    }));
    // Two quote addresses can map to one venue (Metric); the first book for a
    // pair is kept.
    if (bids.length > 0 && !pairs.has(`${t1}:${t2}`))
      pairs.set(`${t1}:${t2}`, { tokenIn: t1, tokenOut: t2, orderBook: bids });
    if (asks.length > 0 && !pairs.has(`${t2}:${t1}`))
      pairs.set(`${t2}:${t1}`, { tokenIn: t2, tokenOut: t1, orderBook: asks });
  }

  return {
    blockNumber: parseUintField(message["block"]),
    slot: parseUintField(message["slot"]),
    timestampNs: parseUintField(message["ts"]),
    pamms: [...byPamm].map(([pamm, pairs]) => ({ pamm, pairs: [...pairs.values()] })),
  };
}

/** A decimal as `digits / 10^scale`. */
interface Decimal {
  digits: bigint;
  scale: number;
}

function parseRungs(
  value: unknown,
  toLevel: (volume: Decimal, quote: Decimal) => PriceLevel,
): PriceLevel[] {
  if (!Array.isArray(value)) return [];
  const levels: PriceLevel[] = [];
  for (const entry of value) {
    const record = entry as Record<string, unknown> | null;
    const volume = toDecimal(record?.["cumVolume"]);
    const price = toDecimal(record?.["price"]);
    if (!volume || !price) continue;
    const quote = { digits: volume.digits * price.digits, scale: volume.scale + price.scale };
    levels.push(toLevel(volume, quote));
  }
  return levels;
}

/**
 * A JSON number as an exact decimal: the shortest decimal that round-trips to
 * the same double, which is what Titan printed.
 */
function toDecimal(value: unknown): Decimal | undefined {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) return undefined;
  const [mantissa, exponent = "0"] = value.toString().split("e");
  const [whole, fraction = ""] = mantissa!.split(".");
  return { digits: BigInt(whole! + fraction), scale: fraction.length - Number(exponent) };
}

/** Round `value * 10^decimals` to the nearest integer (half up). */
function toBaseUnits(value: Decimal, decimals: number): bigint {
  const shift = decimals - value.scale;
  if (shift >= 0) return value.digits * 10n ** BigInt(shift);
  const divisor = 10n ** BigInt(-shift);
  return (value.digits + divisor / 2n) / divisor;
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

export interface PriceLevelsRpcSourceOptions extends TokenDecimalsOptions {
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
  private readonly decimals: TokenDecimals;

  constructor(options: PriceLevelsRpcSourceOptions = {}) {
    this.url = options.url ?? DEFAULT_PRICE_LEVELS_RPC_URL;
    this.fetchFn = options.fetch ?? fetch;
    this.decimals = new TokenDecimals(options);
  }

  /** Latest full snapshot via `titan_getPammBooks`. */
  async getPriceLevels(): Promise<PriceLevelsSnapshot> {
    const raw = await this.rpc("titan_getPammBooks", []);
    return parsePriceLevelsMessage(raw, await this.decimals.resolve(raw));
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

export interface PriceLevelsWsSourceOptions extends TokenDecimalsOptions {
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

/**
 * Streaming source: connects lazily on the first `getPriceLevels()` call and
 * reconnects with exponential backoff. Unlike the overrides stream, each
 * price-levels frame is a *complete* snapshot, so a frame replaces the cached
 * one outright. The socket auto-closes after `idleTimeoutMs` without calls, so
 * no explicit teardown is needed; `close()` remains available for immediate,
 * permanent teardown.
 */
export class PriceLevelsWsSource extends WsSource<unknown> implements PriceLevelsSource {
  // Replaced outright on each frame: price-levels frames are complete snapshots.
  // Kept raw and parsed per call, once any unknown token's decimals are read.
  private frame: unknown;
  private readonly decimals: TokenDecimals;

  protected override get name() {
    return "price-levels";
  }

  constructor(options: PriceLevelsWsSourceOptions = {}) {
    super(options.url ?? DEFAULT_PRICE_LEVELS_WS_URL, options);
    this.decimals = new TokenDecimals(options);
  }

  protected override applyFrame(data: string): void {
    const frame: unknown = JSON.parse(data);
    parsePriceLevelsMessage(frame); // reject undecodable frames up front
    this.frame = frame;
  }

  protected override copySnapshot(): unknown {
    return this.frame;
  }

  async getPriceLevels(): Promise<PriceLevelsSnapshot> {
    const frame = await this.getSnapshot();
    return parsePriceLevelsMessage(frame, await this.decimals.resolve(frame));
  }
}
