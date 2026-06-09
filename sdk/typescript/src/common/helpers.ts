// Decimal/unit conversion, re-exported from viem:
//   parseEther("1")        -> 1000000000000000000n
//   parseUnits("1", 6)     -> 1000000n            (e.g. USDC)
//   formatEther(10n ** 18n) -> "1"
//   formatUnits(1000000n, 6) -> "1"
export { formatEther, formatUnits, parseEther, parseUnits } from "viem";

const BPS_DENOMINATOR = 10_000n;

/**
 * Shave `bps` basis points off `amount` — e.g. derive `amountOutMin` from a
 * quote: `applySlippage(quote, 50)` accepts up to 0.5% less than quoted.
 */
export function applySlippage(amount: bigint, bps: number): bigint {
  if (!Number.isInteger(bps) || bps < 0 || bps > 10_000) {
    throw new RangeError(`slippage bps must be an integer in [0, 10000], got ${bps}`);
  }
  return amount - (amount * BigInt(bps)) / BPS_DENOMINATOR;
}

/** Unix-timestamp deadline `seconds` from now, for swap `deadline` params. */
export function deadlineIn(seconds: number): bigint {
  return BigInt(Math.floor(Date.now() / 1000) + seconds);
}
