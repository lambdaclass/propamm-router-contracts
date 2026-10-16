use ethrex_common::{Address, H160};
use hex_literal::hex;

/// Sentinel passed as `token_in` or `token_out` to signal native ETH.
pub const ETH_SENTINEL: Address = H160(hex!("EeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"));

// Mainnet token addresses (see src/libraries/Constants.sol).
pub const USDC: Address = H160(hex!("A0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"));
pub const USDT: Address = H160(hex!("dAC17F958D2ee523a2206206994597C13D831ec7"));
pub const WETH: Address = H160(hex!("C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"));

/// ERC-20 decimals of the tokens Titan's price levels quote, read from each
/// token's `decimals()` on mainnet. The v2 price-level stream sends human-unit
/// amounts, and these turn them back into base units.
pub const TOKEN_DECIMALS: [(Address, u8); 9] = [
    (WETH, 18),
    (USDC, 6),
    (USDT, 6),
    (H160(hex!("2260fac5e5542a773aa44fbcfedf7c193bc2c599")), 8), // WBTC
    (H160(hex!("cbb7c0000ab88b473b1f5afd9ef808440eed33bf")), 8), // cbBTC
    (H160(hex!("7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9")), 18), // AAVE
    (H160(hex!("514910771af9ca656af840dff83e8264ecf986ca")), 18), // LINK
    (H160(hex!("4a220e6096b25eadb88358cb44068a3248254675")), 18), // QNT
    (H160(hex!("c845b2894dbddd03858fd2d643b4ef725fe0849d")), 18), // NVDAx
];
