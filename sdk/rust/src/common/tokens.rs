use ethrex_common::{Address, H160};
use hex_literal::hex;

/// Sentinel passed as `token_in` or `token_out` to signal native ETH.
pub const ETH_SENTINEL: Address = H160(hex!("EeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"));

// Mainnet token addresses (see src/libraries/Constants.sol).
pub const USDC: Address = H160(hex!("A0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"));
pub const USDT: Address = H160(hex!("dAC17F958D2ee523a2206206994597C13D831ec7"));
pub const WETH: Address = H160(hex!("C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"));
