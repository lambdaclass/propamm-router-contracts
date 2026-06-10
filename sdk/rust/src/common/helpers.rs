use std::time::{SystemTime, UNIX_EPOCH};

use alloy_primitives::U256;

use crate::error::{Error, Result};

// Decimal/unit conversion, re-exported from alloy:
//   parse_ether("1")           -> 1000000000000000000
//   parse_units("1", 6)        -> 1000000             (e.g. USDC)
//   format_ether(...)          -> "1"
//   format_units(..., 6)       -> "1"
pub use alloy_primitives::utils::{format_ether, format_units, parse_ether, parse_units};

const BPS_DENOMINATOR: u64 = 10_000;

/// Shave `bps` basis points off `amount` — e.g. derive `amount_out_min` from
/// a quote: `apply_slippage(quote, 50)` accepts up to 0.5% less than quoted.
pub fn apply_slippage(amount: U256, bps: u32) -> Result<U256> {
    if bps > BPS_DENOMINATOR as u32 {
        return Err(Error::InvalidInput(format!(
            "slippage bps must be in [0, {BPS_DENOMINATOR}], got {bps}"
        )));
    }
    Ok(amount - (amount * U256::from(bps)) / U256::from(BPS_DENOMINATOR))
}

/// Unix-timestamp deadline `seconds` from now, for swap `deadline` params.
pub fn deadline_in(seconds: u64) -> U256 {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before unix epoch")
        .as_secs();
    U256::from(now + seconds)
}
