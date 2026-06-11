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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apply_slippage_shaves_bps_and_floors_in_the_users_favor() {
        // 0.5% off 1_000_000 -> 5_000 fee.
        assert_eq!(
            apply_slippage(U256::from(1_000_000u64), 50).unwrap(),
            U256::from(995_000u64)
        );
        // 0 bps is a no-op; the full denominator zeroes the amount.
        let amount = U256::from(123_456u64);
        assert_eq!(apply_slippage(amount, 0).unwrap(), amount);
        assert_eq!(apply_slippage(amount, 10_000).unwrap(), U256::zero());
        // The fee floors, so the min-out rounds UP (stricter for the user):
        // 10_001 * 1bps = 1.0001 -> fee 1 -> 10_000.
        assert_eq!(
            apply_slippage(U256::from(10_001u64), 1).unwrap(),
            U256::from(10_000u64)
        );
    }

    #[test]
    fn apply_slippage_rejects_bps_above_denominator() {
        assert!(apply_slippage(U256::from(1u64), 10_001).is_err());
    }

    #[test]
    fn apply_slippage_does_not_overflow_for_huge_amounts() {
        // full_mul widens to U512, so amounts near U256::MAX are safe.
        let out = apply_slippage(U256::MAX, 100).unwrap();
        assert!(out < U256::MAX && out > U256::zero());
    }

    #[test]
    fn parse_units_handles_integers_fractions_and_leading_zeros() {
        assert_eq!(parse_units("1.5", 6).unwrap(), U256::from(1_500_000u64));
        assert_eq!(parse_units("1", 6).unwrap(), U256::from(1_000_000u64));
        assert_eq!(parse_units("0.0015", 6).unwrap(), U256::from(1_500u64));
        assert_eq!(parse_ether("1").unwrap(), U256::exp10(18));
    }

    #[test]
    fn parse_units_rejects_excess_precision() {
        assert!(parse_units("1.9999995", 6).is_err());
    }

    #[test]
    fn format_units_trims_zeros_and_round_trips_parse_units() {
        assert_eq!(format_units(U256::from(1_500_000u64), 6), "1.5");
        assert_eq!(format_units(U256::from(1_000_000u64), 6), "1");
        assert_eq!(format_units(U256::from(1_500u64), 6), "0.0015");
        assert_eq!(format_units(U256::zero(), 6), "0");
        assert_eq!(format_ether(U256::exp10(18)), "1");
        let value = parse_units("1234.567", 6).unwrap();
        assert_eq!(format_units(value, 6), "1234.567");
    }

    #[test]
    fn parse_address_validates_length_and_hex() {
        let mut bytes = [0u8; 20];
        bytes[19] = 1;
        let one = Address::from_slice(&bytes);
        assert_eq!(
            parse_address("0x0000000000000000000000000000000000000001").unwrap(),
            one
        );
        // The 0x prefix is optional.
        assert_eq!(
            parse_address("0000000000000000000000000000000000000001").unwrap(),
            one
        );
        // Wrong length and non-hex are rejected.
        assert!(parse_address("0x1234").is_err());
        assert!(parse_address("0xZZ00000000000000000000000000000000000001").is_err());
    }

    #[test]
    fn deadline_in_returns_future_unix_seconds() {
        let base = deadline_in(0);
        // Well past the 2023 epoch, and a positive offset only grows it.
        assert!(base >= U256::from(1_700_000_000u64));
        assert!(deadline_in(1_000) > base);
    }
}
