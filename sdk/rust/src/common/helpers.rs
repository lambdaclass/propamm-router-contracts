use std::time::{SystemTime, UNIX_EPOCH};

use ethrex_common::{Address, U256, U512};

use crate::error::{Error, Result};

const BPS_DENOMINATOR: u32 = 10_000;

/// Shave `bps` basis points off `amount` — e.g. derive `amount_out_min` from
/// a quote: `apply_slippage(quote, 50)` accepts up to 0.5% less than quoted.
pub fn apply_slippage(amount: U256, bps: u32) -> Result<U256> {
    if bps > BPS_DENOMINATOR {
        return Err(Error::InvalidInput(format!(
            "slippage bps must be in [0, {BPS_DENOMINATOR}], got {bps}"
        )));
    }
    let fee = amount.full_mul(U256::from(bps)) / U512::from(BPS_DENOMINATOR);
    let fee = U256::try_from(fee).map_err(|_| Error::InvalidInput("slippage overflow".into()))?;
    Ok(amount - fee)
}

/// Unix-timestamp deadline `seconds` from now, for swap `deadline` params.
pub fn deadline_in(seconds: u64) -> U256 {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before unix epoch")
        .as_secs();
    U256::from(now + seconds)
}

/// Parse a 0x-prefixed (or bare) 20-byte hex address.
pub fn parse_address(s: &str) -> Result<Address> {
    let bytes = hex::decode(s.trim_start_matches("0x"))
        .map_err(|e| Error::InvalidInput(format!("invalid address {s}: {e}")))?;
    if bytes.len() != 20 {
        return Err(Error::InvalidInput(format!(
            "invalid address {s}: expected 20 bytes, got {}",
            bytes.len()
        )));
    }
    Ok(Address::from_slice(&bytes))
}

/// Parse a decimal amount into atomic units: `parse_units("1.5", 6)` → 1500000.
pub fn parse_units(amount: &str, decimals: u32) -> Result<U256> {
    let (int_part, frac_part) = amount.split_once('.').unwrap_or((amount, ""));
    if frac_part.len() > decimals as usize {
        return Err(Error::InvalidInput(format!(
            "{amount} has more than {decimals} decimal places"
        )));
    }

    let parse = |s: &str| {
        U256::from_dec_str(s)
            .map_err(|e| Error::InvalidInput(format!("invalid amount {amount}: {e}")))
    };
    let int = if int_part.is_empty() {
        U256::zero()
    } else {
        parse(int_part)?
    };

    let mut value = int
        .checked_mul(U256::exp10(decimals as usize))
        .ok_or_else(|| Error::InvalidInput(format!("{amount} overflows a uint256")))?;
    if !frac_part.is_empty() {
        let frac = parse(frac_part)? * U256::exp10(decimals as usize - frac_part.len());
        value = value
            .checked_add(frac)
            .ok_or_else(|| Error::InvalidInput(format!("{amount} overflows a uint256")))?;
    }
    Ok(value)
}

/// Format atomic units as a decimal amount, trimming trailing zeros:
/// `format_units(1500000, 6)` → "1.5".
pub fn format_units(value: U256, decimals: u32) -> String {
    let scale = U256::exp10(decimals as usize);
    let int = value / scale;
    let frac = value % scale;
    if frac.is_zero() {
        return int.to_string();
    }
    let frac = format!("{frac:0>width$}", width = decimals as usize);
    format!("{int}.{}", frac.trim_end_matches('0'))
}

/// `parse_units` with 18 decimals: `parse_ether("1")` → 10^18.
pub fn parse_ether(amount: &str) -> Result<U256> {
    parse_units(amount, 18)
}

/// `format_units` with 18 decimals.
pub fn format_ether(value: U256) -> String {
    format_units(value, 18)
}
