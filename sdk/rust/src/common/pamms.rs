use ethrex_common::{Address, H160};
use hex_literal::hex;

// PropAMM venues listed on the router whitelist via `addVenue`.
pub const FERMI: Address = H160(hex!("5979458912F80B96d30D4220af8E2e4925A33320"));
pub const BEBOP: Address = H160(hex!("B09AaA5614916d7AEb59C295C52c92ca82aDdD76"));
pub const KIPSELI: Address = H160(hex!("71e790dd841c8A9061487cb3E78C288E75cE0B3d"));
pub const TEMPEST: Address = H160(hex!("00000003f1ec2379e79F58E12EC6C4F51Ee92149"));
pub const TAURUSFI: Address = H160(hex!("217d58931A8549ca539426AA8152E33dAfc3d95A"));
pub const METRIC: Address = H160(hex!("E715Dc29d2c273D0FC5A03e5Cca9CcB0Abb1dCDB"));

/// Curated propAMM name → venue address mapping, for the `venues` option of
/// quotes and swaps.
///
/// The Uniswap V3 fallback is intentionally absent: its address is router
/// configuration, read it via `PropAmmRouter::fallback_swap_router`.
pub const PAMMS: [(&str, Address); 6] = [
    ("fermi", FERMI),
    ("bebop", BEBOP),
    ("kipseli", KIPSELI),
    ("tempest", TEMPEST),
    ("taurusfi", TAURUSFI),
    ("metric", METRIC),
];
