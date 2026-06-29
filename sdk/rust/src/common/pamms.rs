use ethrex_common::{Address, H160};
use hex_literal::hex;

// PropAMM venues seeded into the router whitelist at initialization.
pub const FERMI: Address = H160(hex!("5979458912F80B96d30D4220af8E2e4925A33320"));
pub const BEBOP: Address = H160(hex!("dB13ad0fcD134E9c48f2fDaEa8f6751a0F5349ca"));
pub const KIPSELI: Address = H160(hex!("71e790dd841c8A9061487cb3E78C288E75cE0B3d"));

/// The always-available Uniswap V3 fallback venue sentinel (the max address).
/// Pass it as a venue to select the fallback explicitly; not a real contract —
/// execution derives the core pool.
pub const UNISWAP_V3_FALLBACK: Address = H160(hex!("ffffffffffffffffffffffffffffffffffffffff"));

/// Curated propAMM name → venue address mapping, for the `venues` option of
/// quotes and swaps.
///
/// The Uniswap V3 fallback is intentionally absent: it is the always-available
/// safety net, selected with the fixed `UNISWAP_V3_FALLBACK` sentinel.
pub const PAMMS: [(&str, Address); 3] = [("fermi", FERMI), ("bebop", BEBOP), ("kipseli", KIPSELI)];
