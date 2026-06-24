//! pAMM state-override sources.
//!
//! The proprietary AMMs price off-chain liquidity that mainnet state does not
//! reflect, so plain `eth_call` quotes see stale prices. Titan publishes
//! fresh state overrides through a WebSocket stream and a JSON-RPC method;
//! the sources here consume either one and produce snapshots that the
//! router's quote calls attach to `eth_call` (third parameter, plus block
//! number/timestamp overrides so venues that check block context don't
//! revert).
//!
//! Both payloads share one shape — top-level metadata plus one entry per pAMM:
//!
//! ```json
//! {
//!   "blockNumber": 24285034,
//!   "0x<pamm>": { "stateOverride": { "0x<contract>": { "stateDiff": { "0x<slot>": "0x<value>" } } } }
//! }
//! ```

use std::{collections::HashMap, sync::Arc, time::Duration};

use async_trait::async_trait;
use ethrex_common::{Address, H256, U256};
use hex_literal::hex;
use rex_sdk::client::eth::StateOverrideSet;
use serde_json::Value;

use crate::common::helpers::parse_address;
use crate::common::pamms::BEBOP;
use crate::error::{Error, Result};
use crate::ws::{WsConnection, WsHandler};

pub const DEFAULT_OVERRIDES_RPC_URL: &str = "https://rpc.titanbuilder.xyz";
pub const DEFAULT_OVERRIDES_WS_URL: &str = "wss://rpc.titanbuilder.xyz/ws/pamm_quote_stream";

/// Bebop prices from a single registry slot. When a snapshot carries no Bebop
/// entry, [`to_state_override`] zeroes this slot by default so a stale
/// on-chain Bebop price cannot win a best-quote selection it could never fill.
pub const BEBOP_DEFAULT_SLOT: H256 = H256(hex!(
    "3ca381a3d43d4e593578057c4abe441ad9df02f080defd17d2b6e6190cdcd936"
));

/// Storage slot diffs for one contract: slot → value.
pub type SlotDiffs = HashMap<H256, U256>;
/// Per-contract slot diffs: contract address → slots.
pub type ContractDiffs = HashMap<Address, SlotDiffs>;

/// A parsed overrides payload: per-pAMM contract diffs plus block context.
#[derive(Debug, Clone, Default)]
pub struct OverridesSnapshot {
    /// Block the overrides were generated against.
    pub block_number: Option<u64>,
    /// Generation time in nanoseconds since epoch.
    pub timestamp_ns: Option<u64>,
    /// pAMM address → contract address → slot diffs.
    pub per_pamm: HashMap<Address, ContractDiffs>,
}

/// Anything quotes can pull override snapshots from.
///
/// Snapshots are handed out behind an [`Arc`] so the hot quote path clones a
/// pointer rather than deep-copying the nested per-pAMM slot maps.
#[async_trait]
pub trait OverridesSource: Send + Sync {
    async fn get_overrides(&self) -> Result<Arc<OverridesSnapshot>>;
    /// Immediate, permanent teardown. Default: no-op.
    fn close(&self) {}
}

const META_KEYS: [&str; 4] = ["slot", "blockNumber", "block_number", "timestamp"];

/// Parse a raw overrides payload (a WS frame or the JSON-RPC `result`) into a
/// snapshot: metadata keys are split out and pAMMs/contracts with empty
/// `stateDiff`s are dropped.
pub fn parse_overrides_message(raw: &Value) -> Result<OverridesSnapshot> {
    let object = raw
        .as_object()
        .ok_or_else(|| Error::Overrides("overrides message is not a JSON object".into()))?;

    let mut per_pamm = HashMap::new();
    for (key, payload) in object {
        if META_KEYS.contains(&key.as_str()) || !key.starts_with("0x") {
            continue;
        }
        let Ok(pamm) = parse_address(key) else {
            continue;
        };
        if let Some(contracts) = parse_contract_diffs(payload) {
            per_pamm.insert(pamm, contracts);
        }
    }

    Ok(OverridesSnapshot {
        block_number: object
            .get("blockNumber")
            .or_else(|| object.get("block_number"))
            .and_then(parse_block_number),
        timestamp_ns: object.get("timestamp").and_then(Value::as_u64),
        per_pamm,
    })
}

fn parse_contract_diffs(payload: &Value) -> Option<ContractDiffs> {
    let override_map = payload
        .get("stateOverride")
        .or_else(|| payload.get("state_override"))?
        .as_object()?;

    let mut contracts = ContractDiffs::new();
    for (address, spec) in override_map {
        let Ok(address) = parse_address(address) else {
            continue;
        };
        let Some(state_diff) = spec.get("stateDiff").and_then(Value::as_object) else {
            continue;
        };
        let mut slots = SlotDiffs::new();
        for (slot, value) in state_diff {
            // Payloads may carry unpadded words ("0x1"); go through U256.
            let parsed = value.as_str().and_then(parse_word);
            let (Some(slot), Some(value)) = (parse_word(slot), parsed) else {
                continue;
            };
            slots.insert(H256(slot.to_big_endian()), value);
        }
        if !slots.is_empty() {
            contracts.insert(address, slots);
        }
    }
    (!contracts.is_empty()).then_some(contracts)
}

fn parse_word(hex: &str) -> Option<U256> {
    hex.strip_prefix("0x")
        .and_then(|h| U256::from_str_radix(h, 16).ok())
}

fn parse_block_number(value: &Value) -> Option<u64> {
    if let Some(number) = value.as_u64() {
        return Some(number);
    }
    let text = value.as_str()?;
    if let Some(hex) = text.strip_prefix("0x") {
        u64::from_str_radix(hex, 16).ok()
    } else {
        text.parse().ok()
    }
}

/// Options for [`to_state_override`].
#[derive(Debug, Clone, Default)]
pub struct ToStateOverrideOptions {
    /// Restrict to these pAMM entries (default: all in the snapshot).
    pub pamms: Option<Vec<Address>>,
    /// Skip injecting the Bebop default slot when no Bebop entry is present.
    pub skip_bebop_default: bool,
}

/// Merge a snapshot's per-pAMM diffs into rex's [`StateOverrideSet`] format
/// for `eth_call`. Diffs are merged at slot level when multiple pAMM entries
/// touch the same contract.
pub fn to_state_override(
    snapshot: &OverridesSnapshot,
    options: &ToStateOverrideOptions,
) -> StateOverrideSet {
    let mut merged: HashMap<Address, SlotDiffs> = HashMap::new();
    let mut has_bebop = false;
    for (pamm, contracts) in &snapshot.per_pamm {
        if options.pamms.as_ref().is_some_and(|s| !s.contains(pamm)) {
            continue;
        }
        if *pamm == BEBOP {
            has_bebop = true;
        }
        for (address, slots) in contracts {
            merged.entry(*address).or_default().extend(slots);
        }
    }

    if !options.skip_bebop_default && !has_bebop {
        merged
            .entry(BEBOP)
            .or_default()
            .insert(BEBOP_DEFAULT_SLOT, U256::zero());
    }

    let mut set = StateOverrideSet::new();
    for (address, slots) in merged {
        set.entry(address).state_diff.extend(slots);
    }
    set
}

/// Fetch-on-demand source: one `titan_getPammStateOverrides` call per
/// [`OverridesSource::get_overrides`].
#[derive(Debug, Clone)]
pub struct OverridesRpcSource {
    url: String,
    client: reqwest::Client,
}

impl Default for OverridesRpcSource {
    fn default() -> Self {
        Self::new(DEFAULT_OVERRIDES_RPC_URL)
    }
}

impl OverridesRpcSource {
    pub fn new(url: impl Into<String>) -> Self {
        Self {
            url: url.into(),
            client: reqwest::Client::new(),
        }
    }
}

#[async_trait]
impl OverridesSource for OverridesRpcSource {
    async fn get_overrides(&self) -> Result<Arc<OverridesSnapshot>> {
        let response = self
            .client
            .post(&self.url)
            .json(&serde_json::json!({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "titan_getPammStateOverrides",
                "params": [],
            }))
            .send()
            .await
            .map_err(|e| Error::Overrides(format!("overrides RPC request failed: {e}")))?;

        if !response.status().is_success() {
            return Err(Error::Overrides(format!(
                "overrides RPC request failed with status {}",
                response.status()
            )));
        }

        let body: Value = response
            .json()
            .await
            .map_err(|e| Error::Overrides(format!("overrides RPC response is not JSON: {e}")))?;
        parse_rpc_response(&body).map(Arc::new)
    }
}

/// Parse a `titan_getPammStateOverrides` JSON-RPC response body into a snapshot.
///
/// A present-but-null `"error"` is treated as success: many JSON-RPC servers
/// send `{"result": {...}, "error": null}`, and the field's mere presence must
/// not be read as a failure (this mirrors the reference SDK's truthiness check
/// — `serde_json` returns `Some(Value::Null)`, not `None`, for an explicit
/// null).
fn parse_rpc_response(body: &Value) -> Result<OverridesSnapshot> {
    if let Some(error) = body.get("error").filter(|error| !error.is_null()) {
        return Err(Error::Overrides(format!("overrides RPC error: {error}")));
    }
    match body.get("result") {
        Some(result) if !result.is_null() => parse_overrides_message(result),
        _ => Err(Error::Overrides(
            "overrides RPC response had neither a result nor an error".into(),
        )),
    }
}

/// Configuration for [`OverridesWsSource`].
#[derive(Debug, Clone)]
pub struct OverridesWsSourceConfig {
    /// Titan stream endpoint.
    pub url: String,
    /// How long `get_overrides` waits for the first frame.
    pub first_frame_timeout: Duration,
    /// Close the socket after this long without a `get_overrides` call, so an
    /// idle source holds no connection; the next call reconnects
    /// transparently and waits for a fresh frame.
    pub idle_timeout: Duration,
}

impl Default for OverridesWsSourceConfig {
    fn default() -> Self {
        Self {
            url: DEFAULT_OVERRIDES_WS_URL.into(),
            first_frame_timeout: Duration::from_secs(5),
            idle_timeout: Duration::from_secs(30),
        }
    }
}

struct OverridesWsHandler;

impl WsHandler for OverridesWsHandler {
    type Snapshot = OverridesSnapshot;

    fn apply_frame(snapshot: &mut Arc<Self::Snapshot>, text: &str) -> bool {
        let Ok(value) = serde_json::from_str::<Value>(text) else {
            return false;
        };
        let Ok(frame) = parse_overrides_message(&value) else {
            return false;
        };
        // `make_mut` clones only when a reader still holds the Arc; readers keep
        // it only transiently (across one quote), so frames usually mutate in
        // place rather than deep-copying.
        let s = Arc::make_mut(snapshot);
        // A frame only carries the pAMMs it updates; entries for other pAMMs
        // stay cached from earlier frames.
        s.per_pamm.extend(frame.per_pamm);
        if frame.block_number.is_some() {
            s.block_number = frame.block_number;
        }
        if frame.timestamp_ns.is_some() {
            s.timestamp_ns = frame.timestamp_ns;
        }
        true
    }

    fn closed_error() -> Error {
        Error::Overrides("overrides source is closed".into())
    }

    fn timeout_error(timeout: Duration) -> Error {
        Error::Timeout(format!("no overrides frame received within {timeout:?}"))
    }
}

/// Streaming source: connects lazily on the first `get_overrides` call and
/// accumulates per-pAMM entries across frames (a frame only carries the pAMMs
/// it updates), reconnecting with exponential backoff. The connection is
/// dropped after `idle_timeout` without calls and re-established on demand,
/// so no explicit teardown is needed; [`OverridesSource::close`] tears down
/// immediately and permanently.
pub struct OverridesWsSource {
    conn: WsConnection<OverridesWsHandler>,
}

impl Default for OverridesWsSource {
    fn default() -> Self {
        Self::new(OverridesWsSourceConfig::default())
    }
}

impl OverridesWsSource {
    pub fn new(config: OverridesWsSourceConfig) -> Self {
        Self {
            conn: WsConnection::new(config.url, config.idle_timeout, config.first_frame_timeout),
        }
    }
}

#[async_trait]
impl OverridesSource for OverridesWsSource {
    async fn get_overrides(&self) -> Result<Arc<OverridesSnapshot>> {
        self.conn.get_snapshot().await
    }

    fn close(&self) {
        self.conn.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rpc_response_treats_null_error_as_success() {
        // Servers that send `"error": null` alongside a result must not be read
        // as failures — the field is present but null.
        let body = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "error": null,
            "result": { "blockNumber": 100 },
        });
        let snapshot = parse_rpc_response(&body).expect("null error is success");
        assert_eq!(snapshot.block_number, Some(100));
    }

    #[test]
    fn rpc_response_parses_result_when_error_key_absent() {
        let body = serde_json::json!({ "result": { "blockNumber": 5 } });
        let snapshot = parse_rpc_response(&body).expect("missing error key is success");
        assert_eq!(snapshot.block_number, Some(5));
        assert!(snapshot.per_pamm.is_empty());
    }

    #[test]
    fn rpc_response_surfaces_a_real_error_object() {
        let body = serde_json::json!({
            "error": { "code": -32000, "message": "boom" },
        });
        let err = parse_rpc_response(&body).expect_err("non-null error must fail");
        assert!(matches!(err, Error::Overrides(_)));
    }

    #[test]
    fn rpc_response_errors_clearly_without_result_or_error() {
        let body = serde_json::json!({ "jsonrpc": "2.0", "id": 1 });
        match parse_rpc_response(&body) {
            Err(Error::Overrides(msg)) => {
                assert!(msg.contains("neither a result nor an error"), "got: {msg}")
            }
            other => panic!("expected an Overrides error, got {other:?}"),
        }
    }

    fn slot(n: u64) -> H256 {
        H256(U256::from(n).to_big_endian())
    }

    fn snapshot_with(
        pamm: Address,
        contract: Address,
        slot: H256,
        value: U256,
        block_number: Option<u64>,
    ) -> OverridesSnapshot {
        let mut slots = SlotDiffs::new();
        slots.insert(slot, value);
        let mut contracts = ContractDiffs::new();
        contracts.insert(contract, slots);
        let mut per_pamm = HashMap::new();
        per_pamm.insert(pamm, contracts);
        OverridesSnapshot {
            block_number,
            timestamp_ns: None,
            per_pamm,
        }
    }

    #[test]
    fn parse_word_accepts_padded_and_unpadded_hex() {
        assert_eq!(parse_word("0x2a"), Some(U256::from(42u64)));
        assert_eq!(parse_word("0x1"), Some(U256::from(1u64)));
        assert_eq!(parse_word("2a"), None); // missing 0x prefix
        assert_eq!(parse_word("0xzz"), None); // non-hex
    }

    #[test]
    fn parse_block_number_accepts_int_hex_and_decimal_forms() {
        assert_eq!(parse_block_number(&serde_json::json!(100)), Some(100));
        assert_eq!(parse_block_number(&serde_json::json!("0x64")), Some(100));
        assert_eq!(parse_block_number(&serde_json::json!("100")), Some(100));
        assert_eq!(parse_block_number(&serde_json::json!("oops")), None);
    }

    #[test]
    fn parse_overrides_message_extracts_diffs_and_skips_metadata() {
        let pamm = "0x0000000000000000000000000000000000000abc";
        let contract = "0x0000000000000000000000000000000000000011";
        let raw = format!(
            r#"{{
                "blockNumber": 24285034,
                "timestamp": 1700000000000000000,
                "slot": "meta-key-ignored",
                "{pamm}": {{ "stateOverride": {{
                    "{contract}": {{ "stateDiff": {{ "0x1": "0x2a" }} }}
                }} }}
            }}"#
        );
        let message: Value = serde_json::from_str(&raw).unwrap();
        let snapshot = parse_overrides_message(&message).unwrap();

        assert_eq!(snapshot.block_number, Some(24_285_034));
        assert_eq!(snapshot.timestamp_ns, Some(1_700_000_000_000_000_000));
        assert_eq!(snapshot.per_pamm.len(), 1);
        let pamm = parse_address(pamm).unwrap();
        let contract = parse_address(contract).unwrap();
        assert_eq!(
            snapshot.per_pamm[&pamm][&contract].get(&slot(1)),
            Some(&U256::from(42u64))
        );
    }

    #[test]
    fn parse_overrides_message_drops_empty_and_invalid_entries() {
        let raw = r#"{
            "not-an-address": { "stateOverride": {} },
            "0x00000000000000000000000000000000000000ff": {
                "stateOverride": { "0x0000000000000000000000000000000000000011": { "stateDiff": {} } }
            }
        }"#;
        let message: Value = serde_json::from_str(raw).unwrap();
        assert!(
            parse_overrides_message(&message)
                .unwrap()
                .per_pamm
                .is_empty()
        );
    }

    #[test]
    fn to_state_override_zeroes_the_bebop_default_slot_when_absent() {
        let pamm = parse_address("0x0000000000000000000000000000000000000abc").unwrap();
        let contract = parse_address("0x0000000000000000000000000000000000000011").unwrap();
        let snapshot = snapshot_with(pamm, contract, slot(7), U256::from(99u64), Some(1));

        let set = to_state_override(&snapshot, &ToStateOverrideOptions::default());
        // The real diff survives...
        assert_eq!(
            set.0[&contract].state_diff.get(&slot(7)),
            Some(&U256::from(99u64))
        );
        // ...and the Bebop registry slot is zeroed because no Bebop entry exists,
        // so a stale on-chain Bebop price can't win a quote it could never fill.
        assert_eq!(
            set.0[&BEBOP].state_diff.get(&BEBOP_DEFAULT_SLOT),
            Some(&U256::zero())
        );
    }

    #[test]
    fn to_state_override_can_skip_the_bebop_default() {
        let pamm = parse_address("0x0000000000000000000000000000000000000abc").unwrap();
        let contract = parse_address("0x0000000000000000000000000000000000000011").unwrap();
        let snapshot = snapshot_with(pamm, contract, slot(7), U256::from(99u64), None);

        let set = to_state_override(
            &snapshot,
            &ToStateOverrideOptions {
                pamms: None,
                skip_bebop_default: true,
            },
        );
        assert!(!set.0.contains_key(&BEBOP));
    }

    #[test]
    fn to_state_override_keeps_real_bebop_diffs_without_injecting_default() {
        let contract = parse_address("0x0000000000000000000000000000000000000011").unwrap();
        // pAMM IS Bebop, so the default-slot injection is skipped.
        let snapshot = snapshot_with(BEBOP, contract, slot(7), U256::from(99u64), None);

        let set = to_state_override(&snapshot, &ToStateOverrideOptions::default());
        assert_eq!(
            set.0[&contract].state_diff.get(&slot(7)),
            Some(&U256::from(99u64))
        );
        assert!(!set.0.contains_key(&BEBOP));
    }
}
