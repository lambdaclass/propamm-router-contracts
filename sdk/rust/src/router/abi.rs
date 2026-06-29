//! Hand-rolled ABI surface for `PropAMMRouter` (src/PropAMMRouter.sol),
//! built on ethrex's calldata codec: function signature strings (the selector
//! source — verify against `forge inspect PropAMMRouter methodIdentifiers`),
//! return-tuple decoding, event decoding, and a custom-error table.
//!
//! The self-call-only internal (`_dispatchVenue`) and UUPS plumbing are
//! intentionally omitted.

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

// Views
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
pub const FALLBACK_FEE_UPDATED_EVENT: &str = "FallbackFeeUpdated(uint24,uint24)";
pub const FALLBACK_QUOTER_UPDATED_EVENT: &str = "FallbackQuoterUpdated(address,address)";
pub const PAIR_FEE_UPDATED_EVENT: &str = "PairFeeUpdated(address,address,uint24,uint24)";
pub const TOKENS_RESCUED_EVENT: &str = "TokensRescued(address,address,uint256)";
pub const VENUE_WHITELISTED_EVENT: &str = "VenueWhitelisted(address)";
pub const VENUE_REMOVED_EVENT: &str = "VenueRemoved(address)";

/// Every router function the SDK binds (the ERC-20 helpers are not part of
/// the router's ABI). Keep in sync when adding signature constants — the
/// contract-parity test enumerates this list.
pub const FUNCTIONS: &[&str] = &[
    SWAP,
    SWAP_WITH_FEE,
    SWAP_VIA_VENUE,
    SWAP_VIA_VENUE_WITH_FEE,
    SWAP_VIA_SELECTED_VENUES,
    SWAP_VIA_SELECTED_VENUES_WITH_FEE,
    QUOTE,
    QUOTE_VENUE,
    QUOTE_SELECTED_VENUES,
    FALLBACK_QUOTER,
    FALLBACK_FEE,
    GET_PAIR_FEE,
    RESOLVED_FEE,
    IS_WHITELISTED_VENUE,
    GET_WHITELISTED_VENUES,
    WHITELISTED_VENUE_COUNT,
    WHITELISTED_VENUE_AT,
    PAUSED,
    AUTHORITY,
    SET_FALLBACK_QUOTER,
    SET_FALLBACK_FEE,
    SET_PAIR_FEE,
    SET_PAIR_FEES,
    ADD_VENUE,
    REMOVE_VENUE,
    PAUSE,
    UNPAUSE,
    RESCUE_TOKENS,
];

/// Every router event the SDK knows. Same parity-test contract as [`FUNCTIONS`].
pub const EVENTS: &[&str] = &[
    SWAPPED_EVENT,
    FRONTEND_FEE_CHARGED_EVENT,
    FALLBACK_FEE_UPDATED_EVENT,
    FALLBACK_QUOTER_UPDATED_EVENT,
    PAIR_FEE_UPDATED_EVENT,
    TOKENS_RESCUED_EVENT,
    VENUE_WHITELISTED_EVENT,
    VENUE_REMOVED_EVENT,
];

/// Custom errors, for naming revert payloads. Mirrors src/libraries/Errors.sol
/// plus OpenZeppelin's `EnforcedPause` (what swaps revert with while paused).
const ERROR_SIGNATURES: &[&str] = &[
    "OnlySelf()",
    "UnknownVenue()",
    "InsufficientOutput(uint256,uint256)",
    "Expired()",
    "NoQuotesAvailable()",
    "InvalidFallbackFee(uint24)",
    "ZeroAddress()",
    "ArrayLengthMismatch()",
    "VenueAlreadyWhitelisted(address)",
    "VenueNotWhitelisted(address)",
    "InvalidValue(uint256,uint256)",
    "ETHTransferFailed()",
    "UnexpectedETHSender()",
    "IdenticalTokens()",
    "OnlyPool()",
    "AmountTooLarge()",
    "ExcessiveInput()",
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

    fn u256_word(n: u64) -> [u8; 32] {
        U256::from(n).to_big_endian()
    }

    fn address_word(address: Address) -> [u8; 32] {
        let mut word = [0u8; 32];
        word[12..].copy_from_slice(address.as_bytes());
        word
    }

    fn address_with_last_byte(byte: u8) -> Address {
        let mut bytes = [0u8; 20];
        bytes[19] = byte;
        Address::from_slice(&bytes)
    }

    #[test]
    fn decode_values_handles_narrow_integer_widths() {
        // ethrex maps every uintN to a 256-bit Value::Uint; pin that for the
        // uint24/uint16 return + error decodes the SDK relies on.
        let values = decode_values("uint24", &u256_word(42)).unwrap();
        assert_eq!(as_u256(&values[0]).unwrap(), U256::from(42u64));

        let mut data = u256_word(7).to_vec();
        data.extend_from_slice(&u256_word(16));
        let values = decode_values("uint16,uint16", &data).unwrap();
        assert_eq!(as_u256(&values[0]).unwrap(), U256::from(7u64));
        assert_eq!(as_u256(&values[1]).unwrap(), U256::from(16u64));
    }

    #[test]
    fn decode_error_names_narrow_width_custom_errors() {
        let mut fallback = keccak("InvalidFallbackFee(uint24)".as_bytes()).as_bytes()[..4].to_vec();
        fallback.extend_from_slice(&u256_word(3000));
        assert_eq!(
            decode_error(&fallback).as_deref(),
            Some("InvalidFallbackFee(3000)")
        );

        let mut fee = keccak("FeeBpsTooHigh(uint16,uint16)".as_bytes()).as_bytes()[..4].to_vec();
        fee.extend_from_slice(&u256_word(150));
        fee.extend_from_slice(&u256_word(100));
        assert_eq!(
            decode_error(&fee).as_deref(),
            Some("FeeBpsTooHigh(150, 100)")
        );
    }

    #[test]
    fn decode_error_returns_none_for_unknown_selector() {
        assert_eq!(decode_error(&[0xde, 0xad, 0xbe, 0xef]), None);
    }

    #[test]
    fn swapped_event_data_decodes_in_the_layout_wait_for_swap_expects() {
        // Swapped data fields (after the 3 indexed leading addresses):
        // (amountIn, amountOut, recipient, marketMaker).
        let recipient = address_with_last_byte(0xaa);
        let market_maker = address_with_last_byte(0xbb);
        let mut data = u256_word(1000).to_vec();
        data.extend_from_slice(&u256_word(950));
        data.extend_from_slice(&address_word(recipient));
        data.extend_from_slice(&address_word(market_maker));

        let values = decode_values("uint256,uint256,address,address", &data).unwrap();
        assert_eq!(as_u256(&values[0]).unwrap(), U256::from(1000u64));
        assert_eq!(as_u256(&values[1]).unwrap(), U256::from(950u64));
        assert_eq!(as_address(&values[2]).unwrap(), recipient);
        assert_eq!(as_address(&values[3]).unwrap(), market_maker);
    }

    #[test]
    fn topic_as_address_reads_the_low_20_bytes() {
        // FrontendFeeCharged's feeRecipient arrives as an indexed topic.
        let recipient = address_with_last_byte(0xcd);
        let topic = H256(address_word(recipient));
        assert_eq!(topic_as_address(&topic), recipient);
    }

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

    /// Functions present in the contract ABI that the SDK deliberately does
    /// not bind: self-call internals, UUPS/AccessManaged plumbing.
    const OMITTED_FUNCTIONS: &[&str] = &[
        "_dispatchVenue(address,address,address,uint256,uint256,address,address,uint256,uint256)",
        "_quoteVenueUnchecked(address,address,address,uint256)",
        "uniswapV3SwapCallback(int256,int256,bytes)",
        "initialize(address,address)",
        "proxiableUUID()",
        "upgradeToAndCall(address,bytes)",
        "setAuthority(address)",
        "isConsumingScheduledOp()",
        "UPGRADE_INTERFACE_VERSION()",
    ];

    /// Inherited OpenZeppelin events the SDK does not decode.
    const OMITTED_EVENTS: &[&str] = &[
        "AuthorityUpdated(address)",
        "Initialized(uint64)",
        "Paused(address)",
        "Unpaused(address)",
        "Upgraded(address)",
    ];

    /// Inherited OpenZeppelin errors the SDK does not name (except
    /// `EnforcedPause`, which swaps actually surface and is bound).
    const OMITTED_ERRORS: &[&str] = &[
        "AccessManagedInvalidAuthority(address)",
        "AccessManagedRequiredDelay(address,uint32)",
        "AccessManagedUnauthorized(address)",
        "AddressEmptyCode(address)",
        "ERC1967InvalidImplementation(address)",
        "ERC1967NonPayable()",
        "ExpectedPause()",
        "FailedCall()",
        "InvalidInitialization()",
        "NotInitializing()",
        "ReentrancyGuardReentrantCall()",
        "SafeERC20FailedOperation(address)",
        "UUPSUnauthorizedCallContext()",
        "UUPSUnsupportedProxiableUUID(bytes32)",
    ];

    /// Canonical type of an ABI input, expanding tuples recursively.
    fn canonical_type(input: &serde_json::Value) -> String {
        let ty = input["type"].as_str().expect("abi input type");
        if let Some(suffix) = ty.strip_prefix("tuple") {
            let components = input["components"].as_array().expect("tuple components");
            let inner: Vec<String> = components.iter().map(canonical_type).collect();
            format!("({}){suffix}", inner.join(","))
        } else {
            ty.to_string()
        }
    }

    fn canonical_signature(item: &serde_json::Value) -> String {
        let name = item["name"].as_str().expect("abi item name");
        let inputs = item["inputs"].as_array().expect("abi item inputs");
        let types: Vec<String> = inputs.iter().map(canonical_type).collect();
        format!("{name}({})", types.join(","))
    }

    /// Two-direction parity against the compiled contract:
    ///  1. every SDK signature must exist in the contract ABI (catches typos
    ///     and signature drift after contract changes);
    ///  2. every contract function/event/error must be bound by the SDK or
    ///     explicitly allowlisted (catches new contract surface the SDK
    ///     hasn't picked up — including stale allowlist entries).
    ///
    /// Reads the Foundry artifact (`forge build` first). Skips when absent
    /// unless REQUIRE_CONTRACT_ABI is set (CI sets it).
    #[test]
    fn abi_matches_contract() {
        let path = std::env::var("ROUTER_ABI_JSON").unwrap_or_else(|_| {
            format!(
                "{}/../../out/PropAMMRouter.sol/PropAMMRouter.json",
                env!("CARGO_MANIFEST_DIR")
            )
        });
        let artifact = match std::fs::read_to_string(&path) {
            Ok(contents) => contents,
            Err(_) if std::env::var("REQUIRE_CONTRACT_ABI").is_err() => {
                eprintln!("skipping abi_matches_contract: {path} not found (run `forge build`)");
                return;
            }
            Err(e) => panic!("contract artifact required but unreadable at {path}: {e}"),
        };
        let artifact: serde_json::Value = serde_json::from_str(&artifact).expect("artifact JSON");

        let of_kind = |kind: &str| -> Vec<String> {
            artifact["abi"]
                .as_array()
                .expect("abi array")
                .iter()
                .filter(|item| item["type"] == kind)
                .map(canonical_signature)
                .collect()
        };
        let contract_functions = of_kind("function");
        let contract_events = of_kind("event");
        let contract_errors = of_kind("error");

        // Sanity-check our canonicalization against forge's own selector map.
        let method_identifiers = artifact["methodIdentifiers"]
            .as_object()
            .expect("methodIdentifiers");
        for signature in &contract_functions {
            assert!(
                method_identifiers.contains_key(signature),
                "canonicalization bug: {signature} not in methodIdentifiers"
            );
        }

        check_parity(
            "function",
            FUNCTIONS,
            &contract_functions,
            OMITTED_FUNCTIONS,
        );
        check_parity("event", EVENTS, &contract_events, OMITTED_EVENTS);
        check_parity("error", ERROR_SIGNATURES, &contract_errors, OMITTED_ERRORS);
    }

    fn check_parity(kind: &str, sdk: &[&str], contract: &[String], omitted: &[&str]) {
        for signature in sdk {
            assert!(
                contract.iter().any(|c| c == signature),
                "SDK {kind} `{signature}` does not exist in the contract ABI"
            );
        }
        for signature in contract {
            let bound = sdk.contains(&signature.as_str());
            let allowlisted = omitted.contains(&signature.as_str());
            assert!(
                bound || allowlisted,
                "contract {kind} `{signature}` is neither bound by the SDK nor allowlisted"
            );
            assert!(
                !(bound && allowlisted),
                "{kind} `{signature}` is both bound and allowlisted — remove it from the allowlist"
            );
        }
        for signature in omitted {
            assert!(
                contract.iter().any(|c| c == signature),
                "allowlisted {kind} `{signature}` no longer exists in the contract — remove it"
            );
        }
    }
}
