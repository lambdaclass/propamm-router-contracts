// Mainnet token addresses for the default per-pair fallback tiers seeded by
// `initialize` (see `_seedDefaultPairFees`). Mainnet-specific by design: on
// other chains these point at the wrong tokens, which is harmless — they are
// only consulted for these exact addresses, and any entry can be cleared or
// overridden via `setPairFee`.
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
// Sentinel passed as `tokenIn` or `tokenOut` to signal native ETH.
address constant ETH_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
