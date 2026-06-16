use ethrex_common::{Address, H160};
use hex_literal::hex;

// PropAMM venues seeded into the router whitelist at initialization.
pub const FERMI: Address = H160(hex!("5979458912F80B96d30D4220af8E2e4925A33320"));
pub const BEBOP: Address = H160(hex!("dB13ad0fcD134E9c48f2fDaEa8f6751a0F5349ca"));
pub const KIPSELI: Address = H160(hex!("342b8458161137d0203605Fa51E4363c1445ADCD"));

/// Curated propAMM name → venue address mapping, for the `venues` option of
/// quotes and swaps.
///
/// The Uniswap V3 fallback is intentionally absent: its address is router
/// configuration, read it via `PropAmmRouter::fallback_swap_router`.
pub const PAMMS: [(&str, Address); 3] = [("fermi", FERMI), ("bebop", BEBOP), ("kipseli", KIPSELI)];
