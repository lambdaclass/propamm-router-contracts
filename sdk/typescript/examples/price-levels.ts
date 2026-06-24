/**
 * pAMM price levels: Titan's pre-quoted prices for a range of trade sizes,
 * grouped per pAMM. Served from Titan's latest snapshot over HTTP (no node RPC,
 * no key), unlike `router.quote`, which runs an on-chain `eth_call`.
 *
 * Build the SDK first, then run (Node >= 22.18 runs TypeScript directly):
 *
 *   pnpm build
 *   node examples/price-levels.ts
 *
 * Set PRICE_LEVELS_URL to use a specific HTTP endpoint.
 */
import { PriceLevels, PriceLevelsRpcSource } from "propamm/prices";
import type { PairPriceLevels } from "propamm/prices";
import { PAMMS } from "propamm/common/pamms";
import { formatUnits } from "propamm/common/helpers";
import type { Address } from "propamm";

// Known tokens, for readable amounts. Unknown tokens print raw (0 decimals).
const TOKENS: Record<string, { symbol: string; decimals: number }> = {
  "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": { symbol: "USDC", decimals: 6 },
  "0xdac17f958d2ee523a2206206994597c13d831ec7": { symbol: "USDT", decimals: 6 },
  "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2": { symbol: "WETH", decimals: 18 },
  "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599": { symbol: "WBTC", decimals: 8 },
};
const tokenInfo = (token: Address) => TOKENS[token.toLowerCase()] ?? { symbol: token, decimals: 0 };
const fmt = (amount: bigint, token: Address) => {
  const { symbol, decimals } = tokenInfo(token);
  return `${formatUnits(amount, decimals)} ${symbol}`;
};

// Map venue addresses back to readable pAMM names.
const venueNames: Record<string, string> = {};
for (const [name, address] of Object.entries(PAMMS)) {
  venueNames[address.toLowerCase()] = name;
}
const venueName = (address: Address) => venueNames[address.toLowerCase()] ?? address;

// PriceLevels defaults to a one-shot HTTP snapshot source. Set PRICE_LEVELS_URL
// to point snapshots and quotes at a specific endpoint.
const url = process.env.PRICE_LEVELS_URL;
const prices = new PriceLevels(url ? { source: new PriceLevelsRpcSource({ url }) } : {});

// 1. Full snapshot: every pAMM's order book.
const snapshot = await prices.getPriceLevels();
if (!snapshot) throw new Error("no price-levels snapshot available");
console.log(`snapshot @ block ${snapshot.blockNumber ?? "?"} — ${snapshot.pamms.length} pAMM(s)`);

// Pick the first pAMM/pair that actually carries an order book to display.
let chosen: { pamm: Address; pair: PairPriceLevels } | undefined;
for (const entry of snapshot.pamms) {
  const pair = entry.pairs.find((p) => p.orderBook.length > 0);
  if (pair) {
    chosen = { pamm: entry.pamm, pair };
    break;
  }
}
if (!chosen) throw new Error("snapshot carried no order books");
const { pamm, pair } = chosen;

console.log(
  `\n${venueName(pamm)} order book: ${tokenInfo(pair.tokenIn).symbol} -> ${tokenInfo(pair.tokenOut).symbol}`,
);
for (const level of pair.orderBook) {
  console.log(
    `  ${fmt(level.amountIn, pair.tokenIn)} -> ${fmt(level.amountOut, pair.tokenOut)}  [${level.variant}]`,
  );
}

// 2. Quote helpers, for that pair and a mid-ladder size. `getQuote` returns the
// best across all pAMMs; `getQuoteVenue` pins to one. Both skip the eth_call.
const size = pair.orderBook[Math.floor(pair.orderBook.length / 2)].amountIn;

const best = await prices.getQuote(pair.tokenIn, pair.tokenOut, size);
console.log(
  `\nbest quote:  ${fmt(best.amountIn, best.tokenIn)} -> ${fmt(best.amountOut, best.tokenOut)} via ${venueName(best.pamm)}`,
);

const pinned = await prices.getQuoteVenue(pamm, pair.tokenIn, pair.tokenOut, size);
console.log(
  `${venueName(pamm)} quote: ${fmt(pinned.amountIn, pinned.tokenIn)} -> ${fmt(pinned.amountOut, pinned.tokenOut)}`,
);

prices.close(); // close the stream socket so the process exits promptly
