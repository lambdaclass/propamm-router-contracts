use alloy::primitives::{Address, address};

/// Sentinel passed as `token_in` or `token_out` to signal native ETH.
pub const ETH_SENTINEL: Address = address!("0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE");

// Mainnet token addresses (see src/libraries/Constants.sol).
pub const USDC: Address = address!("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48");
pub const USDT: Address = address!("0xdAC17F958D2ee523a2206206994597C13D831ec7");
pub const WETH: Address = address!("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
