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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::common::helpers::parse_address;
    use crate::common::tokens::{ETH_SENTINEL, USDC, USDT, WETH};
    use std::collections::BTreeMap;
    use std::path::{Path, PathBuf};

    /// Every file-level `address constant` the contracts declare, by name.
    ///
    /// These are compile-time inlined, so they appear in no forge artifact
    /// (no ABI entry, no storage slot, no getter) — the Solidity source is the
    /// only place to read them. Returns `None` when `src/` is absent, e.g. in
    /// an isolated package checkout; set `REQUIRE_CONTRACT_SRC` to make that
    /// case a failure instead, mirroring `REQUIRE_CONTRACT_ABI`.
    fn solidity_address_constants() -> Option<BTreeMap<String, Address>> {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../src");
        let mut files = Vec::new();
        collect_sol_files(&root, &mut files);
        if files.is_empty() {
            if std::env::var("REQUIRE_CONTRACT_SRC").is_ok() {
                panic!(
                    "contract sources required but none found at {}",
                    root.display()
                );
            }
            eprintln!("skipping: no .sol sources under {}", root.display());
            return None;
        }

        let mut found = BTreeMap::new();
        for file in files {
            let source = std::fs::read_to_string(&file).expect("read .sol source");
            for line in source.lines() {
                let Some((name, address)) = parse_address_constant(line) else {
                    continue;
                };
                let previous = found.insert(name.clone(), address);
                assert!(
                    previous.is_none_or(|p| p == address),
                    "conflicting `address constant {name}` declarations in src/"
                );
            }
        }
        Some(found)
    }

    fn collect_sol_files(dir: &Path, out: &mut Vec<PathBuf>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                collect_sol_files(&path, out);
            } else if path.extension().is_some_and(|e| e == "sol") {
                out.push(path);
            }
        }
    }

    /// `address constant NAME = 0x…;` → `(NAME, address)`.
    fn parse_address_constant(line: &str) -> Option<(String, Address)> {
        let rest = line.trim().strip_prefix("address constant ")?;
        let (name, rest) = rest.split_once('=')?;
        let literal = rest.trim().trim_end_matches(';').trim();
        Some((name.trim().to_string(), parse_address(literal).ok()?))
    }

    /// The SDK's addresses must equal the contracts' — they are maintained by
    /// hand in both places, and `BEBOP` in particular is load-bearing: the
    /// router dispatches `venue == BEBOP_ROUTER` down a bespoke `IBebopRouter`
    /// path rather than the generic `IPropAMM` one, so a stale SDK copy sends
    /// callers at the wrong calling convention.
    #[test]
    fn address_constants_match_contract() {
        let Some(solidity) = solidity_address_constants() else {
            return;
        };
        for (name, expected) in [
            ("BEBOP_ROUTER", BEBOP),
            ("USDC", USDC),
            ("USDT", USDT),
            ("WETH", WETH),
            ("ETH_SENTINEL", ETH_SENTINEL),
        ] {
            let actual = solidity
                .get(name)
                .unwrap_or_else(|| panic!("`address constant {name}` not found in src/"));
            assert_eq!(
                actual, &expected,
                "{name} drifted: contracts say {actual:#x}, SDK says {expected:#x}"
            );
        }
    }

    /// The venues below have no Solidity counterpart to check against: the
    /// router reaches them through the runtime `addVenue` whitelist and the
    /// generic `IPropAMM` interface, so only Bebop is hardcoded. If a new
    /// `address constant` appears in `src/`, it is a new hardcoded dispatch
    /// target and the SDKs must mirror it — add it to
    /// `address_constants_match_contract` (and to `PAMMS` if it is a venue).
    #[test]
    fn no_unmirrored_address_constant_in_contracts() {
        let Some(solidity) = solidity_address_constants() else {
            return;
        };
        let mirrored = ["BEBOP_ROUTER", "USDC", "USDT", "WETH", "ETH_SENTINEL"];
        let unmirrored: Vec<_> = solidity
            .keys()
            .filter(|name| !mirrored.contains(&name.as_str()))
            .collect();
        assert!(
            unmirrored.is_empty(),
            "unmirrored `address constant`s in src/: {unmirrored:?} — mirror them in the SDK"
        );
    }

    /// `PAMMS` is the curated venue list; it must stay in sync with the
    /// individual constants and carry no duplicates.
    #[test]
    fn pamms_is_consistent() {
        assert_eq!(PAMMS.len(), 6);
        for (name, address) in PAMMS {
            assert_ne!(address, Address::zero(), "{name} is the zero address");
            assert_eq!(
                PAMMS.iter().filter(|(_, a)| *a == address).count(),
                1,
                "{name} is duplicated in PAMMS"
            );
        }
    }
}
