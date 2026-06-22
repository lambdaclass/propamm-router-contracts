//! pAMM price-level sources.
//!
//! Alongside the raw state overrides (see [`crate::overrides`]), Titan
//! publishes prices it has *already quoted*, grouped per pAMM: for each trading
//! pair an `order_book` of rungs mapping an input amount to the output it would
//! receive. This lets a taker read prices across a range of trade sizes without
//! running an `eth_call` simulation per size. Rungs come in two flavours —
//! `Simulated` (derived from an EVM simulation of a synthesized taker tx) and
//! `Interpolated` (a linear spline between simulated rungs, for finer
//! granularity).
//!
//! Titan exposes this through a WebSocket stream and three JSON-RPC methods:
//!
//! - `titan_getPammPriceLevels` — the full per-pAMM snapshot (also streamed as
//!   *complete* snapshots, not deltas).
//! - `titan_getPammQuote` — the best quote across all pAMMs for a size.
//! - `titan_getPammQuoteVenue` — the same, pinned to one venue.
//!
//! The snapshot payload (the JSON-RPC `result` or a WS frame) looks like:
//!
//! ```json
//! {
//!   "slot": 14581462,
//!   "blockNumber": 25345763,
//!   "timestamp": 1781801564588230787,
//!   "pamms": [{
//!     "pamm": "0x5979...",
//!     "pairs": [{
//!       "tokenIn": "0x2260...", "tokenOut": "0xa0b8...",
//!       "orderBook": [{ "amountIn": "0x989680", "amountOut": "0x174b67393", "variant": "Simulated" }]
//!     }]
//!   }]
//! }
//! ```

use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};

use async_trait::async_trait;
use ethrex_common::{Address, U256};
use futures_util::StreamExt;
use serde_json::Value;
use tokio::sync::{Mutex, Notify};
use tokio_tungstenite::{connect_async, tungstenite::Message};

use crate::common::helpers::parse_address;
use crate::error::{Error, Result};

pub const DEFAULT_PRICE_LEVELS_RPC_URL: &str = "https://rpc.titanbuilder.xyz";
/// Default price-levels stream endpoint. The stream is served from regional
/// hosts (`eu.`, `ap.`, `us.`); override the URL to pick the nearest.
pub const DEFAULT_PRICE_LEVELS_WS_URL: &str = "wss://eu.rpc.titanbuilder.xyz/ws/pamm_price_levels";

/// Whether a rung came from an EVM simulation or a spline interpolation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PriceVariant {
    Simulated,
    Interpolated,
}

impl PriceVariant {
    fn parse(s: &str) -> Option<Self> {
        match s {
            "Simulated" => Some(Self::Simulated),
            "Interpolated" => Some(Self::Interpolated),
            _ => None,
        }
    }
}

/// One rung of a pair's order book: `amount_in` of `token_in` quotes `amount_out`.
#[derive(Debug, Clone)]
pub struct PriceLevel {
    pub amount_in: U256,
    pub amount_out: U256,
    pub variant: PriceVariant,
}

/// The order book a pAMM quotes for one `token_in`/`token_out` pair.
#[derive(Debug, Clone)]
pub struct PairPriceLevels {
    pub token_in: Address,
    pub token_out: Address,
    pub order_book: Vec<PriceLevel>,
}

/// One pAMM's price levels across all the pairs it quotes.
#[derive(Debug, Clone)]
pub struct PammPriceLevels {
    pub pamm: Address,
    pub pairs: Vec<PairPriceLevels>,
}

/// A parsed price-levels payload: per-pAMM order books plus block context.
#[derive(Debug, Clone, Default)]
pub struct PriceLevelsSnapshot {
    /// Block the levels were generated against.
    pub block_number: Option<u64>,
    /// Slot the levels were generated against.
    pub slot: Option<u64>,
    /// Generation time in nanoseconds since epoch.
    pub timestamp_ns: Option<u64>,
    pub pamms: Vec<PammPriceLevels>,
}

/// A single quote from `titan_getPammQuote` / `titan_getPammQuoteVenue`.
#[derive(Debug, Clone)]
pub struct TitanQuote {
    pub token_in: Address,
    pub token_out: Address,
    pub amount_in: U256,
    pub amount_out: U256,
    /// pAMM that produced the quote.
    pub pamm: Address,
    /// Router associated with the quote.
    pub router: Address,
    pub block_number: Option<u64>,
    pub slot: Option<u64>,
    pub timestamp_ns: Option<u64>,
}

/// Anything callers can pull price-level snapshots from.
///
/// Snapshots are handed out behind an [`Arc`] so a streaming source clones a
/// pointer rather than deep-copying the (large) per-pAMM order books.
#[async_trait]
pub trait PriceLevelsSource: Send + Sync {
    async fn get_price_levels(&self) -> Result<Arc<PriceLevelsSnapshot>>;
    /// Immediate, permanent teardown. Default: no-op.
    fn close(&self) {}
    /// The HTTP source backing the quote helpers, when this source speaks HTTP.
    /// The streaming source returns `None`, so [`PriceLevels`] falls back to a
    /// default HTTP source for quotes (the stream pushes snapshots, not quotes).
    fn as_rpc_source(&self) -> Option<PriceLevelsRpcSource> {
        None
    }
}

/// Parse a raw price-levels payload (a WS frame or the JSON-RPC `result`) into a
/// snapshot: hex amounts become `U256`s, and pAMMs/pairs/rungs that are
/// malformed (missing fields, unknown variant) are dropped.
pub fn parse_price_levels_message(raw: &Value) -> Result<PriceLevelsSnapshot> {
    let object = raw
        .as_object()
        .ok_or_else(|| Error::Prices("price-levels message is not a JSON object".into()))?;

    let pamms = object
        .get("pamms")
        .and_then(Value::as_array)
        .map(|entries| entries.iter().filter_map(parse_pamm).collect())
        .unwrap_or_default();

    Ok(PriceLevelsSnapshot {
        block_number: object
            .get("blockNumber")
            .or_else(|| object.get("block_number"))
            .and_then(parse_u64_field),
        slot: object.get("slot").and_then(parse_u64_field),
        // Titan timestamps are nanoseconds; they fit in a u64 and `as_u64`
        // preserves them exactly.
        timestamp_ns: object.get("timestamp").and_then(Value::as_u64),
        pamms,
    })
}

fn parse_pamm(entry: &Value) -> Option<PammPriceLevels> {
    let object = entry.as_object()?;
    let pamm = object
        .get("pamm")
        .and_then(Value::as_str)
        .and_then(|s| parse_address(s).ok())?;
    let pairs = object
        .get("pairs")
        .and_then(Value::as_array)
        .map(|entries| entries.iter().filter_map(parse_pair).collect())
        .unwrap_or_default();
    Some(PammPriceLevels { pamm, pairs })
}

fn parse_pair(entry: &Value) -> Option<PairPriceLevels> {
    let object = entry.as_object()?;
    let token_in = object
        .get("tokenIn")
        .and_then(Value::as_str)
        .and_then(|s| parse_address(s).ok())?;
    let token_out = object
        .get("tokenOut")
        .and_then(Value::as_str)
        .and_then(|s| parse_address(s).ok())?;
    let order_book = object
        .get("orderBook")
        .and_then(Value::as_array)
        .map(|entries| entries.iter().filter_map(parse_level).collect())
        .unwrap_or_default();
    Some(PairPriceLevels {
        token_in,
        token_out,
        order_book,
    })
}

fn parse_level(entry: &Value) -> Option<PriceLevel> {
    let object = entry.as_object()?;
    let amount_in = object
        .get("amountIn")
        .and_then(Value::as_str)
        .and_then(parse_u256_hex)?;
    let amount_out = object
        .get("amountOut")
        .and_then(Value::as_str)
        .and_then(parse_u256_hex)?;
    let variant = object
        .get("variant")
        .and_then(Value::as_str)
        .and_then(PriceVariant::parse)?;
    Some(PriceLevel {
        amount_in,
        amount_out,
        variant,
    })
}

fn parse_titan_quote(raw: &Value) -> Result<TitanQuote> {
    let object = raw
        .as_object()
        .ok_or_else(|| Error::Prices("price-levels quote result is not a JSON object".into()))?;

    let address = |key: &str| {
        object
            .get(key)
            .and_then(Value::as_str)
            .and_then(|s| parse_address(s).ok())
    };
    let amount = |key: &str| {
        object
            .get(key)
            .and_then(Value::as_str)
            .and_then(parse_u256_hex)
    };

    let (
        Some(token_in),
        Some(token_out),
        Some(pamm),
        Some(router),
        Some(amount_in),
        Some(amount_out),
    ) = (
        address("tokenIn"),
        address("tokenOut"),
        address("pamm"),
        address("router"),
        amount("amountIn"),
        amount("amountOut"),
    )
    else {
        return Err(Error::Prices(
            "price-levels quote result is missing required fields".into(),
        ));
    };

    Ok(TitanQuote {
        token_in,
        token_out,
        amount_in,
        amount_out,
        pamm,
        router,
        block_number: object
            .get("blockNumber")
            .or_else(|| object.get("block_number"))
            .and_then(parse_u64_field),
        slot: object.get("slot").and_then(parse_u64_field),
        timestamp_ns: object.get("timestamp").and_then(Value::as_u64),
    })
}

fn parse_u256_hex(s: &str) -> Option<U256> {
    s.strip_prefix("0x")
        .and_then(|h| U256::from_str_radix(h, 16).ok())
}

fn parse_u64_field(value: &Value) -> Option<u64> {
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

/// Validate a JSON-RPC response body and return its `result`.
///
/// A present-but-null `"error"` is treated as success (servers commonly send
/// `{"result": {...}, "error": null}`), mirroring [`crate::overrides`].
fn extract_rpc_result(body: &Value) -> Result<Value> {
    if let Some(error) = body.get("error").filter(|error| !error.is_null()) {
        return Err(Error::Prices(format!("price-levels RPC error: {error}")));
    }
    match body.get("result") {
        Some(result) if !result.is_null() => Ok(result.clone()),
        _ => Err(Error::Prices(
            "price-levels RPC response had neither a result nor an error".into(),
        )),
    }
}

/// Fetch-on-demand source over Titan's JSON-RPC endpoint. Besides the
/// price-level snapshot it exposes the two quote helpers, which share the same
/// endpoint and are served from the latest snapshot (so they skip the on-chain
/// `eth_call` that [`crate::PropAmmRouter::quote`] runs).
#[derive(Debug, Clone)]
pub struct PriceLevelsRpcSource {
    url: String,
    client: reqwest::Client,
}

impl Default for PriceLevelsRpcSource {
    fn default() -> Self {
        Self::new(DEFAULT_PRICE_LEVELS_RPC_URL)
    }
}

impl PriceLevelsRpcSource {
    pub fn new(url: impl Into<String>) -> Self {
        Self {
            url: url.into(),
            client: reqwest::Client::new(),
        }
    }

    /// Best quote across all pAMMs via `titan_getPammQuote`.
    pub async fn get_quote(
        &self,
        token_in: Address,
        token_out: Address,
        amount_in: U256,
    ) -> Result<TitanQuote> {
        let params = serde_json::json!([
            format!("{token_in:#x}"),
            format!("{token_out:#x}"),
            format!("{amount_in:#x}"),
        ]);
        parse_titan_quote(&self.rpc("titan_getPammQuote", params).await?)
    }

    /// Quote from a specific venue via `titan_getPammQuoteVenue`.
    pub async fn get_quote_venue(
        &self,
        venue: Address,
        token_in: Address,
        token_out: Address,
        amount_in: U256,
    ) -> Result<TitanQuote> {
        let params = serde_json::json!([
            format!("{venue:#x}"),
            format!("{token_in:#x}"),
            format!("{token_out:#x}"),
            format!("{amount_in:#x}"),
        ]);
        parse_titan_quote(&self.rpc("titan_getPammQuoteVenue", params).await?)
    }

    async fn rpc(&self, method: &str, params: Value) -> Result<Value> {
        let response = self
            .client
            .post(&self.url)
            .json(&serde_json::json!({
                "jsonrpc": "2.0",
                "id": 1,
                "method": method,
                "params": params,
            }))
            .send()
            .await
            .map_err(|e| Error::Prices(format!("price-levels RPC request failed: {e}")))?;

        if !response.status().is_success() {
            return Err(Error::Prices(format!(
                "price-levels RPC request failed with status {}",
                response.status()
            )));
        }

        let body: Value = response
            .json()
            .await
            .map_err(|e| Error::Prices(format!("price-levels RPC response is not JSON: {e}")))?;
        extract_rpc_result(&body)
    }
}

#[async_trait]
impl PriceLevelsSource for PriceLevelsRpcSource {
    async fn get_price_levels(&self) -> Result<Arc<PriceLevelsSnapshot>> {
        let result = self
            .rpc("titan_getPammPriceLevels", serde_json::json!([]))
            .await?;
        parse_price_levels_message(&result).map(Arc::new)
    }

    fn as_rpc_source(&self) -> Option<PriceLevelsRpcSource> {
        Some(self.clone())
    }
}

/// Configuration for [`PriceLevelsWsSource`].
#[derive(Debug, Clone)]
pub struct PriceLevelsWsSourceConfig {
    /// Titan stream endpoint.
    pub url: String,
    /// How long `get_price_levels` waits for the first frame.
    pub first_frame_timeout: Duration,
    /// Close the socket after this long without a `get_price_levels` call, so
    /// an idle source holds no connection; the next call reconnects
    /// transparently and waits for a fresh frame.
    pub idle_timeout: Duration,
}

impl Default for PriceLevelsWsSourceConfig {
    fn default() -> Self {
        Self {
            url: DEFAULT_PRICE_LEVELS_WS_URL.into(),
            first_frame_timeout: Duration::from_secs(5),
            idle_timeout: Duration::from_secs(30),
        }
    }
}

const RECONNECT_INITIAL: Duration = Duration::from_secs(1);
const RECONNECT_MAX: Duration = Duration::from_secs(30);

/// Streaming source: connects lazily on the first `get_price_levels` call and
/// reconnects with exponential backoff. Unlike the overrides stream, each
/// price-levels frame is a *complete* snapshot, so a frame replaces the cached
/// one outright. The connection is dropped after `idle_timeout` without calls
/// and re-established on demand, so no explicit teardown is needed;
/// [`PriceLevelsSource::close`] tears down immediately and permanently.
pub struct PriceLevelsWsSource {
    config: PriceLevelsWsSourceConfig,
    state: Arc<WsState>,
}

#[derive(Default)]
struct WsShared {
    snapshot: Arc<PriceLevelsSnapshot>,
    has_frame: bool,
    closed: bool,
    last_use: Option<Instant>,
    task: Option<tokio::task::JoinHandle<()>>,
}

#[derive(Default)]
struct WsState {
    shared: Mutex<WsShared>,
    frame_notify: Notify,
    /// Calls currently waiting for a first frame — idle teardown is deferred
    /// while any exist (matters when `idle_timeout` is very small).
    waiters: AtomicUsize,
}

impl Default for PriceLevelsWsSource {
    fn default() -> Self {
        Self::new(PriceLevelsWsSourceConfig::default())
    }
}

impl PriceLevelsWsSource {
    pub fn new(config: PriceLevelsWsSourceConfig) -> Self {
        Self {
            config,
            state: Arc::new(WsState::default()),
        }
    }

    async fn wait_for_snapshot(
        &self,
        deadline: tokio::time::Instant,
    ) -> Result<Arc<PriceLevelsSnapshot>> {
        loop {
            // Register for notification BEFORE checking state, so a frame
            // landing in between can't be missed.
            let notified = self.state.frame_notify.notified();
            {
                let shared = self.state.shared.lock().await;
                if shared.closed {
                    return Err(Error::Prices("price-levels source is closed".into()));
                }
                if shared.has_frame {
                    // Arc clone: one refcount bump, not a deep copy.
                    return Ok(shared.snapshot.clone());
                }
            }
            if tokio::time::timeout_at(deadline, notified).await.is_err() {
                return Err(Error::Timeout(format!(
                    "no price-levels frame received within {:?}",
                    self.config.first_frame_timeout
                )));
            }
        }
    }
}

#[async_trait]
impl PriceLevelsSource for PriceLevelsWsSource {
    async fn get_price_levels(&self) -> Result<Arc<PriceLevelsSnapshot>> {
        // Warm path: a single lock acquisition. Record demand, ensure the read
        // loop is alive (respawn if it died), then hand out a buffered frame's
        // Arc immediately if present.
        {
            let mut shared = self.state.shared.lock().await;
            if shared.closed {
                return Err(Error::Prices("price-levels source is closed".into()));
            }
            shared.last_use = Some(Instant::now());
            let running = shared.task.as_ref().is_some_and(|t| !t.is_finished());
            if !running {
                shared.task = Some(tokio::spawn(run_ws_loop(
                    self.state.clone(),
                    self.config.clone(),
                )));
            }
            if shared.has_frame {
                return Ok(shared.snapshot.clone());
            }
        }

        let deadline = tokio::time::Instant::now() + self.config.first_frame_timeout;
        self.state.waiters.fetch_add(1, Ordering::SeqCst);
        let result = self.wait_for_snapshot(deadline).await;
        self.state.waiters.fetch_sub(1, Ordering::SeqCst);
        result
    }

    fn close(&self) {
        let state = self.state.clone();
        tokio::spawn(async move {
            let mut shared = state.shared.lock().await;
            shared.closed = true;
            if let Some(task) = shared.task.take() {
                task.abort();
            }
            drop(shared);
            state.frame_notify.notify_waiters();
        });
    }
}

/// Background read loop: connect, replace the shared snapshot with each frame,
/// and exit when idle (resetting `has_frame` so the next call waits for fresh
/// data).
async fn run_ws_loop(state: Arc<WsState>, config: PriceLevelsWsSourceConfig) {
    let mut backoff = RECONNECT_INITIAL;

    loop {
        if let Ok((stream, _)) = connect_async(&config.url).await {
            backoff = RECONNECT_INITIAL;
            let (_, mut read) = stream.split();

            loop {
                let idle_deadline = idle_deadline(&state, config.idle_timeout).await;
                tokio::select! {
                    message = read.next() => match message {
                        Some(Ok(Message::Text(text))) => {
                            handle_frame(&state, text.as_str()).await;
                        }
                        Some(Ok(_)) => {}
                        Some(Err(_)) | None => break, // reconnect
                    },
                    _ = tokio::time::sleep_until(idle_deadline) => {
                        if idle_expired(&state, config.idle_timeout).await {
                            return;
                        }
                    }
                }
            }
        }

        // Between reconnect attempts, still honor the idle timeout so a dead
        // endpoint doesn't keep an unused source reconnecting forever.
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(RECONNECT_MAX);
        if idle_expired(&state, config.idle_timeout).await {
            return;
        }
    }
}

async fn handle_frame(state: &WsState, text: &str) {
    let Ok(value) = serde_json::from_str::<Value>(text) else {
        return; // skip undecodable frames, like the reference consumers do
    };
    let Ok(frame) = parse_price_levels_message(&value) else {
        return;
    };

    let mut shared = state.shared.lock().await;
    // Each frame is a complete snapshot, so it replaces the cached one.
    shared.snapshot = Arc::new(frame);
    shared.has_frame = true;
    drop(shared);
    state.frame_notify.notify_waiters();
}

async fn idle_deadline(state: &WsState, idle_timeout: Duration) -> tokio::time::Instant {
    // While a call is waiting for its first frame, push the deadline out so a
    // tiny idle_timeout can't tear the connection down before delivery.
    if state.waiters.load(Ordering::SeqCst) > 0 {
        return tokio::time::Instant::now() + Duration::from_secs(1);
    }
    let shared = state.shared.lock().await;
    let last_use = shared.last_use.unwrap_or_else(Instant::now);
    tokio::time::Instant::now() + idle_timeout.saturating_sub(last_use.elapsed())
}

/// True (and marks the snapshot as needing a fresh frame) when the source has
/// been unused for longer than the idle timeout and nobody is waiting.
async fn idle_expired(state: &WsState, idle_timeout: Duration) -> bool {
    if state.waiters.load(Ordering::SeqCst) > 0 {
        return false;
    }
    let mut shared = state.shared.lock().await;
    let expired = shared
        .last_use
        .is_none_or(|last_use| last_use.elapsed() >= idle_timeout);
    if expired {
        shared.has_frame = false;
    }
    expired
}

/// Entry point for Titan's pAMM price levels, structured like
/// [`crate::PropAmmRouter`]: a single client wrapping a default
/// [`PriceLevelsSource`] you can override.
///
/// - [`PriceLevels::get_price_levels`] reads the latest snapshot from the
///   configured source (one-shot HTTP by default; pass a [`PriceLevelsWsSource`]
///   to stream).
/// - [`PriceLevels::get_quote`] / [`PriceLevels::get_quote_venue`] resolve a
///   single size against Titan's latest snapshot over HTTP JSON-RPC. They are
///   HTTP-only — the stream pushes snapshots, not quotes — so they always go
///   through an RPC source.
pub struct PriceLevels {
    source: Arc<dyn PriceLevelsSource>,
    rpc: PriceLevelsRpcSource,
}

impl Default for PriceLevels {
    fn default() -> Self {
        Self::new()
    }
}

impl PriceLevels {
    /// Client with the default one-shot HTTP snapshot source.
    pub fn new() -> Self {
        Self::with_source(Arc::new(PriceLevelsRpcSource::default()))
    }

    /// Client with an explicit snapshot source. When `source` already speaks
    /// HTTP (a [`PriceLevelsRpcSource`]), the quote helpers reuse it so a custom
    /// endpoint covers both; otherwise quotes go to the default HTTP endpoint.
    pub fn with_source(source: Arc<dyn PriceLevelsSource>) -> Self {
        let rpc = source.as_rpc_source().unwrap_or_default();
        Self { source, rpc }
    }

    /// The snapshot source [`Self::get_price_levels`] pulls from.
    pub fn source(&self) -> &Arc<dyn PriceLevelsSource> {
        &self.source
    }

    /// Latest price-level snapshot from the configured source.
    pub async fn get_price_levels(&self) -> Result<Arc<PriceLevelsSnapshot>> {
        self.source.get_price_levels().await
    }

    /// Best quote across all pAMMs for a size (`titan_getPammQuote`).
    pub async fn get_quote(
        &self,
        token_in: Address,
        token_out: Address,
        amount_in: U256,
    ) -> Result<TitanQuote> {
        self.rpc.get_quote(token_in, token_out, amount_in).await
    }

    /// Quote from a specific venue for a size (`titan_getPammQuoteVenue`).
    pub async fn get_quote_venue(
        &self,
        venue: Address,
        token_in: Address,
        token_out: Address,
        amount_in: U256,
    ) -> Result<TitanQuote> {
        self.rpc
            .get_quote_venue(venue, token_in, token_out, amount_in)
            .await
    }

    /// Tear down the snapshot source (closes the stream socket, if any). The
    /// HTTP quote path holds no connection, so there is nothing else to release.
    pub fn close(&self) {
        self.source.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_price_levels_message_extracts_pamms_pairs_and_rungs() {
        let pamm = "0x5979458912f80b96d30d4220af8e2e4925a33320";
        let token_in = "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599";
        let token_out = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48";
        let raw = serde_json::json!({
            "slot": 14581462,
            "blockNumber": 25345763,
            "timestamp": 1781801564588230787u64,
            "pamms": [{
                "pamm": pamm,
                "pairs": [{
                    "tokenIn": token_in,
                    "tokenOut": token_out,
                    "orderBook": [
                        { "amountIn": "0x989680", "amountOut": "0x174b67393", "variant": "Simulated" },
                        { "amountIn": "0xaa810a", "amountOut": "0x1a0781260", "variant": "Interpolated" },
                    ],
                }],
            }],
        });

        let snapshot = parse_price_levels_message(&raw).unwrap();
        assert_eq!(snapshot.block_number, Some(25_345_763));
        assert_eq!(snapshot.slot, Some(14_581_462));
        assert_eq!(snapshot.timestamp_ns, Some(1_781_801_564_588_230_787));
        assert_eq!(snapshot.pamms.len(), 1);

        let entry = &snapshot.pamms[0];
        assert_eq!(entry.pamm, parse_address(pamm).unwrap());
        assert_eq!(entry.pairs.len(), 1);

        let pair = &entry.pairs[0];
        assert_eq!(pair.token_in, parse_address(token_in).unwrap());
        assert_eq!(pair.token_out, parse_address(token_out).unwrap());
        assert_eq!(pair.order_book.len(), 2);
        assert_eq!(pair.order_book[0].amount_in, U256::from(0x989680u64));
        assert_eq!(pair.order_book[0].amount_out, U256::from(0x1_74b6_7393u64));
        assert_eq!(pair.order_book[0].variant, PriceVariant::Simulated);
        assert_eq!(pair.order_book[1].variant, PriceVariant::Interpolated);
    }

    #[test]
    fn parse_price_levels_message_drops_unknown_variants_and_malformed_rungs() {
        let raw = serde_json::json!({
            "pamms": [{
                "pamm": "0x0000000000000000000000000000000000000abc",
                "pairs": [{
                    "tokenIn": "0x0000000000000000000000000000000000000011",
                    "tokenOut": "0x0000000000000000000000000000000000000022",
                    "orderBook": [
                        { "amountIn": "0x1", "amountOut": "0x2", "variant": "Bogus" },
                        { "amountIn": "0x3", "variant": "Simulated" },
                        { "amountIn": "0x4", "amountOut": "0x5", "variant": "Simulated" },
                    ],
                }],
            }],
        });
        let snapshot = parse_price_levels_message(&raw).unwrap();
        let book = &snapshot.pamms[0].pairs[0].order_book;
        // Only the one well-formed, known-variant rung survives.
        assert_eq!(book.len(), 1);
        assert_eq!(book[0].amount_in, U256::from(4u64));
    }

    #[test]
    fn parse_price_levels_message_tolerates_missing_pamms() {
        let snapshot = parse_price_levels_message(&serde_json::json!({ "slot": 1 })).unwrap();
        assert!(snapshot.pamms.is_empty());
        assert_eq!(snapshot.slot, Some(1));
    }

    #[test]
    fn parse_titan_quote_parses_a_full_result() {
        let raw = serde_json::json!({
            "tokenIn": "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599",
            "tokenOut": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
            "amountIn": "0xde0b6b3a7640000",
            "amountOut": "0xd09dc300",
            "pamm": "0x5979458912f80b96d30d4220af8e2e4925a33320",
            "router": "0x4ddf368080cd7946db5b459ad591c350158175e1",
            "blockNumber": 25051224,
            "slot": 14285824,
            "timestamp": 1778253913749564761u64,
        });
        let quote = parse_titan_quote(&raw).unwrap();
        assert_eq!(quote.amount_in, U256::exp10(18));
        assert_eq!(quote.amount_out, U256::from(0xd09d_c300u64));
        assert_eq!(
            quote.pamm,
            parse_address("0x5979458912f80b96d30d4220af8e2e4925a33320").unwrap()
        );
        assert_eq!(quote.block_number, Some(25_051_224));
        assert_eq!(quote.timestamp_ns, Some(1_778_253_913_749_564_761));
    }

    #[test]
    fn parse_titan_quote_fails_when_a_field_is_missing() {
        let raw = serde_json::json!({
            "tokenIn": "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599",
            "tokenOut": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
            "amountIn": "0x1",
            // amountOut, pamm, router missing
        });
        assert!(matches!(parse_titan_quote(&raw), Err(Error::Prices(_))));
    }

    #[test]
    fn extract_rpc_result_treats_null_error_as_success() {
        let body = serde_json::json!({ "error": null, "result": { "pamms": [] } });
        assert!(extract_rpc_result(&body).is_ok());
    }

    #[test]
    fn extract_rpc_result_surfaces_a_real_error_object() {
        let body = serde_json::json!({ "error": { "code": -32000, "message": "boom" } });
        assert!(matches!(extract_rpc_result(&body), Err(Error::Prices(_))));
    }

    #[test]
    fn extract_rpc_result_errors_without_result_or_error() {
        let body = serde_json::json!({ "jsonrpc": "2.0", "id": 1 });
        assert!(matches!(extract_rpc_result(&body), Err(Error::Prices(_))));
    }
}
