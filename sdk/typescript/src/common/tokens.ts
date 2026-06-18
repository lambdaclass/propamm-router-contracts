import type { Address } from "viem";

/** Sentinel passed as `tokenIn` or `tokenOut` to signal native ETH. */
export const ETH_SENTINEL: Address = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";

// Mainnet token addresses (see src/libraries/Constants.sol).
export const USDC: Address = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
export const USDT: Address = "0xdAC17F958D2ee523a2206206994597C13D831ec7";
export const WETH: Address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
