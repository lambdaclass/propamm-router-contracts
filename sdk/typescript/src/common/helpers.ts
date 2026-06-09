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
