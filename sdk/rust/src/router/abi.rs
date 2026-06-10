//! Hand-rolled ABI surface for `PropAMMRouter` (src/PropAMMRouter.sol),
//! built on ethrex's calldata codec: function signature strings (the selector
//! source — verify against `forge inspect PropAMMRouter methodIdentifiers`),
//! return-tuple decoding, event decoding, and a custom-error table.
//!
//! Self-call-only internals (`_dispatchVenue`, `_dispatchQuoteVenue`) and
//! UUPS plumbing are intentionally omitted.

use std::fmt::Write as _;

use ethrex_common::{Address, H256, U256};
use ethrex_l2_sdk::calldata::decode_calldata;
use keccak_hash::keccak;

use crate::error::{Error, Result};

pub use ethrex_l2_common::calldata::Value;

// Swaps. Struct params (`FrontendFee`) appear as tuples, per the canonical
// Solidity signature.
pub const SWAP: &str = "swapV1(address,address,uint256,uint256,address,uint256)";
pub const SWAP_WITH_FEE: &str =
    "swapWithFeeV1(address,address,uint256,uint256,address,uint256,(uint16,address))";
pub const SWAP_VIA_VENUE: &str =
    "swapViaVenueV1(address,address,address,uint256,uint256,address,uint256)";
pub const SWAP_VIA_VENUE_WITH_FEE: &str = "swapViaVenueWithFeeV1(address,address,address,uint256,uint256,address,uint256,(uint16,address))";
pub const SWAP_VIA_SELECTED_VENUES: &str =
    "swapViaSelectedVenuesV1(address[],address,address,uint256,uint256,address,uint256)";
pub const SWAP_VIA_SELECTED_VENUES_WITH_FEE: &str = "swapViaSelectedVenuesWithFeeV1(address[],address,address,uint256,uint256,address,uint256,(uint16,address))";

// Quotes — nonpayable (not view) on-chain; call off-chain via simulation.
pub const QUOTE: &str = "quoteV1(address,address,uint256)";
pub const QUOTE_VENUE: &str = "quoteVenueV1(address,address,address,uint256)";
pub const QUOTE_SELECTED_VENUES: &str = "quoteSelectedVenuesV1(address[],address,address,uint256)";
pub const QUOTE_UNISWAP_V3: &str = "quoteUniswapV3(address,address,uint256)";

// Views
pub const FALLBACK_SWAP_ROUTER: &str = "fallbackSwapRouter()";
pub const FALLBACK_QUOTER: &str = "fallbackQuoter()";
pub const FALLBACK_FEE: &str = "fallbackFee()";
pub const GET_PAIR_FEE: &str = "getPairFee(address,address)";
pub const RESOLVED_FEE: &str = "resolvedFee(address,address)";
pub const IS_WHITELISTED_VENUE: &str = "isWhitelistedVenue(address)";
pub const GET_WHITELISTED_VENUES: &str = "getWhitelistedVenues()";
pub const WHITELISTED_VENUE_COUNT: &str = "whitelistedVenueCount()";
pub const WHITELISTED_VENUE_AT: &str = "whitelistedVenueAt(uint256)";
pub const PAUSED: &str = "paused()";
pub const AUTHORITY: &str = "authority()";

// Administration (access-controlled via the AccessManager authority).
// No typed bindings — encode with these and send through `ContractClient::send`.
pub const SET_FALLBACK_SWAP_ROUTER: &str = "setFallbackSwapRouter(address)";
pub const SET_FALLBACK_QUOTER: &str = "setFallbackQuoter(address)";
pub const SET_FALLBACK_FEE: &str = "setFallbackFee(uint24)";
pub const SET_PAIR_FEE: &str = "setPairFee(address,address,uint24)";
pub const SET_PAIR_FEES: &str = "setPairFees(address[],address[],uint24[])";
pub const ADD_VENUE: &str = "addVenue(address)";
pub const REMOVE_VENUE: &str = "removeVenue(address)";
pub const PAUSE: &str = "pause()";
pub const UNPAUSE: &str = "unpause()";
pub const RESCUE_TOKENS: &str = "rescueTokens(address,address,uint256)";

// ERC-20 (for router approvals)
pub const ERC20_APPROVE: &str = "approve(address,uint256)";
pub const ERC20_ALLOWANCE: &str = "allowance(address,address)";

// Events
pub const SWAPPED_EVENT: &str = "Swapped(address,address,address,uint256,uint256,address,address)";
pub const FRONTEND_FEE_CHARGED_EVENT: &str = "FrontendFeeCharged(address,address,uint256,address)";

/// Custom errors, for naming revert payloads. Mirrors src/libraries/Errors.sol
/// plus OpenZeppelin's `EnforcedPause` (what swaps revert with while paused).
const ERROR_SIGNATURES: &[&str] = &[
    "OnlySelf()",
    "UnknownVenue()",
    "InsufficientOutput(uint256,uint256)",
    "Expired()",
    "NoQuotesAvailable()",
    "TokenOutBalanceDecreased()",
    "InvalidFallbackFee(uint24)",
    "ZeroAddress()",
    "ArrayLengthMismatch()",
    "VenueAlreadyWhitelisted(address)",
    "VenueNotWhitelisted(address)",
    "InvalidValue(uint256,uint256)",
    "ETHTransferFailed()",
    "UnexpectedETHSender()",
    "IdenticalTokens()",
    "FeeBpsTooHigh(uint16,uint16)",
    "EnforcedPause()",
];

/// keccak topic0 of an event signature.
pub fn event_topic(signature: &str) -> H256 {
    keccak(signature.as_bytes())
}

/// Decode ABI-encoded return data (or any bare tuple) against a
/// comma-separated type list, e.g. `decode_values("uint256,address", data)`.
pub fn decode_values(types: &str, data: &[u8]) -> Result<Vec<Value>> {
    // ethrex's decoder expects calldata (it skips a 4-byte selector and never
    // checks it), so a dummy selector + function name turn it into a plain
    // tuple decoder for return data, event data, and error args.
    let mut calldata = Vec::with_capacity(4 + data.len());
    calldata.extend_from_slice(&[0u8; 4]);
    calldata.extend_from_slice(data);
    decode_calldata(&format!("x({types})"), calldata.into())
        .map_err(|e| Error::Abi(format!("failed to decode ({types}): {e}")))
}

pub fn as_u256(value: &Value) -> Result<U256> {
    match value {
        Value::Uint(v) => Ok(*v),
        other => Err(Error::Abi(format!("expected uint, got {other:?}"))),
    }
}

pub fn as_address(value: &Value) -> Result<Address> {
    match value {
        Value::Address(v) => Ok(*v),
        other => Err(Error::Abi(format!("expected address, got {other:?}"))),
    }
}

pub fn as_bool(value: &Value) -> Result<bool> {
    match value {
        Value::Bool(v) => Ok(*v),
        other => Err(Error::Abi(format!("expected bool, got {other:?}"))),
    }
}

pub fn as_address_array(value: &Value) -> Result<Vec<Address>> {
    match value {
        Value::Array(values) => values.iter().map(as_address).collect(),
        other => Err(Error::Abi(format!("expected address[], got {other:?}"))),
    }
}

/// An indexed event argument (a full 32-byte topic) read as an address.
pub fn topic_as_address(topic: &H256) -> Address {
    Address::from_slice(&topic.as_bytes()[12..])
}

/// Name a revert payload against the router's known custom errors, e.g.
/// `InsufficientOutput(1000, 900)`. `None` when the selector is unknown.
pub fn decode_error(data: &[u8]) -> Option<String> {
    if data.len() < 4 {
        return None;
    }
    let signature = ERROR_SIGNATURES
        .iter()
        .find(|signature| keccak(signature.as_bytes()).as_bytes()[..4] == data[..4])?;

    let (name, params) = signature.split_once('(')?;
    let types = params.trim_end_matches(')');
    if types.is_empty() {
        return Some(format!("{name}()"));
    }
    let values = decode_values(types, &data[4..]).ok()?;
    let mut rendered = String::new();
    for (i, value) in values.iter().enumerate() {
        if i > 0 {
            rendered.push_str(", ");
        }
        let _ = write!(rendered, "{}", format_value(value));
    }
    Some(format!("{name}({rendered})"))
}

fn format_value(value: &Value) -> String {
    match value {
        Value::Uint(v) | Value::Int(v) => v.to_string(),
        Value::Address(v) => format!("{v:#x}"),
        Value::Bool(v) => v.to_string(),
        other => format!("{other:?}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Selectors verified against `forge inspect PropAMMRouter methodIdentifiers`.
    /// Guards the signature strings — with runtime ABI, a typo here is the
    /// only thing the compiler can't catch.
    #[test]
    fn selectors_match_contract() {
        let cases = [
            (SWAP, "1037acb3"),
            (SWAP_WITH_FEE, "d4a41dda"),
            (SWAP_VIA_VENUE, "82fc5493"),
            (SWAP_VIA_VENUE_WITH_FEE, "ca775698"),
            (SWAP_VIA_SELECTED_VENUES, "f7890e1d"),
            (SWAP_VIA_SELECTED_VENUES_WITH_FEE, "cc38d822"),
            (QUOTE, "04f9caa2"),
            (QUOTE_VENUE, "221ee81f"),
            (QUOTE_SELECTED_VENUES, "824bfccd"),
            (QUOTE_UNISWAP_V3, "64d40acb"),
            (FALLBACK_SWAP_ROUTER, "2f61968b"),
            (GET_WHITELISTED_VENUES, "d7d008fc"),
            (PAUSED, "5c975abb"),
            (ADD_VENUE, "2522ed6b"),
            (SET_PAIR_FEES, "aca5c88c"),
            (RESCUE_TOKENS, "cea9d26f"),
        ];
        for (signature, expected) in cases {
            let selector = hex::encode(&keccak(signature.as_bytes()).as_bytes()[..4]);
            assert_eq!(selector, expected, "selector mismatch for {signature}");
        }
    }

    /// The encoder must derive the same selector from the signature string
    /// (it normalizes the signature before hashing).
    #[test]
    fn encoder_selector_matches_keccak() {
        use ethrex_common::{H160, U256};
        use ethrex_l2_sdk::calldata::encode_calldata;

        let fee = Value::Tuple(vec![
            Value::Uint(U256::from(25u32)),
            Value::Address(H160::zero()),
        ]);
        let args = [
            Value::Address(H160::zero()),
            Value::Address(H160::zero()),
            Value::Uint(U256::one()),
            Value::Uint(U256::zero()),
            Value::Address(H160::zero()),
            Value::Uint(U256::zero()),
            fee,
        ];
        let calldata = encode_calldata(SWAP_WITH_FEE, &args).expect("encode");
        assert_eq!(hex::encode(&calldata[..4]), "d4a41dda");
    }
}
