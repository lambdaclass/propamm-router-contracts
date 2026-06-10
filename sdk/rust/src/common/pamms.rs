use alloy_primitives::{Address, address};

// PropAMM venues seeded into the router whitelist at initialization.
pub const FERMI: Address = address!("0x5979458912F80B96d30D4220af8E2e4925A33320");
pub const BEBOP: Address = address!("0x160141A205F5dDcf096BA3F48B7eD21EB52c62EA");
pub const KIPSELI: Address = address!("0x71e790dd841c8A9061487cb3E78C288E75cE0B3d");

/// Curated propAMM name → venue address mapping, for the venue arguments of
/// `quote_venue` / `swap_via_venue` / `quote_selected_venues` /
/// `swap_via_selected_venues`.
///
/// The Uniswap V3 fallback is intentionally absent: its address is router
/// configuration, read it via `PropAmmRouter::fallback_swap_router`.
pub const PAMMS: [(&str, Address); 3] = [("fermi", FERMI), ("bebop", BEBOP), ("kipseli", KIPSELI)];
