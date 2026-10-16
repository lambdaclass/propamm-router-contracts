//! pAMM price-level sources.
//!
//! Alongside the raw state overrides (see [`crate::overrides`]), Titan
//! publishes prices it has *already quoted*, grouped per pAMM: for each trading
//! pair an `order_book` of rungs mapping an input amount to the output it would
//! receive. This lets a taker read prices across a range of trade sizes without
//! running an `eth_call` simulation per size.
//!
//! Titan exposes this through a WebSocket stream and three JSON-RPC methods:
//!
//! - `titan_getPammBooks` — the full snapshot (also streamed at
//!   `wss://.../ws/pamm_price_levels_v2` as *complete* snapshots, not deltas).
//! - `titan_getPammQuote` — the best quote across all pAMMs for a size.
//! - `titan_getPammQuoteVenue` — the same, pinned to one venue.
//!
//! The v2 payload carries one book per maker and token pair, in human units:
//!
//! ```json
//! {
//!   "slot": 15436468, "block": 26197444, "ts": 1792061637434840374,
//!   "books": [{
//!     "maker": "Tempest", "quoteAddress": "0x0000...",
//!     "token1Address": "0xc02a...", "token2Address": "0xdac1...",
//!     "bids": [{ "price": 2365.0436, "cumVolume": 0.005 }],
//!     "asks": [{ "price": 2365.526259, "cumVolume": 0.004227389132525372 }]
//!   }]
//! }
//! ```
//!
//! A bid rung sells `cumVolume` of token1 for `cumVolume * price` of token2; an
//! ask rung buys `cumVolume` of token1 for `cumVolume * price` of token2. The
//! parser turns each side into the `token_in → token_out` order book of
//! base-unit amounts this module has always returned, which needs each token's
//! decimals (see [`crate::common::tokens::TOKEN_DECIMALS`]). Titan sends those
//! numbers as floats, so a rebuilt amount can be a few base units off the exact
//! simulated one. The book is filed under the router venue its quote address
//! maps to ([`crate::common::pamms::QUOTE_ADDRESS_VENUES`]).
//!
//! The v1 payload (`pamms` of hex `amountIn`/`amountOut` rungs) is still
//! parsed, for sources pointed at the deprecated endpoints.

use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex},
    time::Duration,
};

use async_trait::async_trait;
use ethrex_common::{Address, U256};
use serde_json::Value;

use crate::common::helpers::parse_address;
use crate::common::pamms::venue_for_quote_address;
use crate::common::tokens::TOKEN_DECIMALS;
use crate::error::{Error, Result};
use crate::ws::{WsConnection, WsHandler};

/// Default price-levels endpoint. Served from regional hosts (`eu.`, `ap.`,
/// `us.`); override the URL to pick the nearest.
pub const DEFAULT_PRICE_LEVELS_RPC_URL: &str = "https://eu.data.titanbuilder.xyz/data";
/// Default price-levels stream endpoint. The stream is served from regional
/// hosts (`eu.`, `ap.`, `us.`); override the URL to pick the nearest.
pub const DEFAULT_PRICE_LEVELS_WS_URL: &str =
    "wss://eu.data.titanbuilder.xyz/ws/pamm_price_levels_v2";

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
    /// Only the v1 payload says how a rung was produced.
    pub variant: Option<PriceVariant>,
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

/// Parse a raw price-levels payload (a WS frame or the JSON-RPC `result`, v2 or
/// v1 shape) into a snapshot, with [`TOKEN_DECIMALS`] for the v2 conversion.
/// See [`parse_price_levels_message_with`].
pub fn parse_price_levels_message(raw: &Value) -> Result<PriceLevelsSnapshot> {
    parse_price_levels_message_with(raw, &TOKEN_DECIMALS.into_iter().collect())
}

/// Parse a raw price-levels payload (a WS frame or the JSON-RPC `result`, v2 or
/// v1 shape) into a snapshot: amounts become base-unit `U256`s, and malformed
/// books/pairs/rungs are dropped. A v2 book quoting a token absent from
/// `decimals` is skipped.
pub fn parse_price_levels_message_with(
    raw: &Value,
    decimals: &HashMap<Address, u8>,
) -> Result<PriceLevelsSnapshot> {
    let object = raw
        .as_object()
        .ok_or_else(|| Error::Prices("price-levels message is not a JSON object".into()))?;
    if let Some(books) = object.get("books").and_then(Value::as_array) {
        return Ok(parse_books(object, books, decimals));
    }

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

fn parse_books(
    object: &serde_json::Map<String, Value>,
    books: &[Value],
    decimals: &HashMap<Address, u8>,
) -> PriceLevelsSnapshot {
    let address = |book: &Value, key: &str| {
        book.get(key)
            .and_then(Value::as_str)
            .and_then(|s| parse_address(s).ok())
    };
    let mut pamms: Vec<PammPriceLevels> = Vec::new();
    for book in books {
        let (Some(quote_address), Some(token1), Some(token2)) = (
            address(book, "quoteAddress"),
            address(book, "token1Address"),
            address(book, "token2Address"),
        ) else {
            continue;
        };
        let (Some(&d1), Some(&d2)) = (decimals.get(&token1), decimals.get(&token2)) else {
            continue;
        };

        // Bids: sell cumVolume of token1, receive cumVolume*price of token2.
        let bids: Vec<PriceLevel> = rungs(book.get("bids"))
            .filter_map(|(volume, quote)| {
                Some(PriceLevel {
                    amount_in: volume.base_units(d1)?,
                    amount_out: quote.base_units(d2)?,
                    variant: None,
                })
            })
            .collect();
        // Asks: pay cumVolume*price of token2, receive cumVolume of token1.
        let asks: Vec<PriceLevel> = rungs(book.get("asks"))
            .filter_map(|(volume, quote)| {
                Some(PriceLevel {
                    amount_in: quote.base_units(d2)?,
                    amount_out: volume.base_units(d1)?,
                    variant: None,
                })
            })
            .collect();

        let pamm = venue_for_quote_address(quote_address);
        let index = match pamms.iter().position(|p| p.pamm == pamm) {
            Some(index) => index,
            None => {
                pamms.push(PammPriceLevels {
                    pamm,
                    pairs: Vec::new(),
                });
                pamms.len() - 1
            }
        };
        let pairs = &mut pamms[index].pairs;
        // Two quote addresses can map to one venue (Metric); the first book for
        // a pair is kept.
        for (token_in, token_out, order_book) in [(token1, token2, bids), (token2, token1, asks)] {
            let present = pairs
                .iter()
                .any(|p| p.token_in == token_in && p.token_out == token_out);
            if !order_book.is_empty() && !present {
                pairs.push(PairPriceLevels {
                    token_in,
                    token_out,
                    order_book,
                });
            }
        }
    }

    PriceLevelsSnapshot {
        block_number: object.get("block").and_then(parse_u64_field),
        slot: object.get("slot").and_then(parse_u64_field),
        timestamp_ns: object.get("ts").and_then(Value::as_u64),
        pamms,
    }
}

/// A decimal as `digits / 10^scale`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Decimal {
    digits: U256,
    scale: u32,
}

impl Decimal {
    /// A JSON number as an exact decimal. `f64`'s `Display` prints the
    /// shortest decimal that round-trips to the same double, which is what
    /// Titan printed.
    fn from_json(value: &Value) -> Option<Self> {
        let number = value.as_f64().filter(|n| n.is_finite() && *n >= 0.0)?;
        let text = number.to_string();
        let (whole, fraction) = text.split_once('.').unwrap_or((&text, ""));
        Some(Self {
            digits: U256::from_dec_str(&format!("{whole}{fraction}")).ok()?,
            scale: fraction.len() as u32,
        })
    }

    /// The exact product, or `None` when its digits overflow a `U256`.
    fn times(self, other: Self) -> Option<Self> {
        Some(Self {
            digits: self.digits.checked_mul(other.digits)?,
            scale: self.scale + other.scale,
        })
    }

    /// `self * 10^decimals`, rounded to the nearest integer (half up), or
    /// `None` when it overflows a `U256`.
    fn base_units(self, decimals: u8) -> Option<U256> {
        let decimals = u32::from(decimals);
        if decimals >= self.scale {
            return self.digits.checked_mul(pow10(decimals - self.scale)?);
        }
        // A divisor past `U256::MAX` is over twice any `digits`: rounds to zero.
        let Some(divisor) = pow10(self.scale - decimals) else {
            return Some(U256::zero());
        };
        let (quotient, remainder) = (self.digits / divisor, self.digits % divisor);
        // `remainder * 2 >= divisor`, without the overflow.
        Some(if remainder >= divisor - remainder {
            quotient + 1
        } else {
            quotient
        })
    }
}

/// `10^exponent`, or `None` past `U256::MAX`.
fn pow10(exponent: u32) -> Option<U256> {
    U256::from(10u8).checked_pow(U256::from(exponent))
}

/// `(cumVolume, cumVolume * price)` per well-formed rung whose product fits a
/// `U256`.
fn rungs(value: Option<&Value>) -> impl Iterator<Item = (Decimal, Decimal)> + '_ {
    value
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|rung| {
            let volume = rung.get("cumVolume").and_then(Decimal::from_json)?;
            let price = rung.get("price").and_then(Decimal::from_json)?;
            Some((volume, volume.times(price)?))
        })
}

/// Token decimals: the built-in table, caller additions, and cached on-chain
/// reads. Shared by a source's clones.
#[derive(Debug)]
struct TokenDecimals {
    table: Mutex<HashMap<Address, u8>>,
    failed: Mutex<HashSet<Address>>,
    eth_rpc_url: Option<String>,
    client: reqwest::Client,
}

impl TokenDecimals {
    fn new(extra: HashMap<Address, u8>, eth_rpc_url: Option<String>) -> Self {
        let mut table: HashMap<Address, u8> = TOKEN_DECIMALS.into_iter().collect();
        table.extend(extra);
        Self {
            table: Mutex::new(table),
            failed: Mutex::new(HashSet::new()),
            eth_rpc_url,
            client: reqwest::Client::new(),
        }
    }

    /// Read the decimals of the payload's unknown tokens, then return the table.
    async fn resolve(&self, raw: &Value) -> HashMap<Address, u8> {
        if let Some(url) = &self.eth_rpc_url {
            let unknown: Vec<Address> = {
                let table = self.table.lock().expect("decimals lock");
                let failed = self.failed.lock().expect("decimals lock");
                book_tokens(raw)
                    .into_iter()
                    .filter(|t| !table.contains_key(t) && !failed.contains(t))
                    .collect()
            };
            let reads = unknown.iter().map(|token| self.read(url, *token));
            let results = futures_util::future::join_all(reads).await;
            let mut table = self.table.lock().expect("decimals lock");
            let mut failed = self.failed.lock().expect("decimals lock");
            for (token, result) in unknown.into_iter().zip(results) {
                match result {
                    Some(decimals) => {
                        table.insert(token, decimals);
                    }
                    // Not retried: its books stay skipped.
                    None => {
                        failed.insert(token);
                    }
                }
            }
        }
        self.table.lock().expect("decimals lock").clone()
    }

    async fn read(&self, url: &str, token: Address) -> Option<u8> {
        // decimals() selector
        let call = serde_json::json!({ "to": format!("{token:#x}"), "data": "0x313ce567" });
        let body: Value = self
            .client
            .post(url)
            .json(&serde_json::json!({
                "jsonrpc": "2.0", "id": 1, "method": "eth_call", "params": [call, "latest"],
            }))
            .send()
            .await
            .ok()?
            .json()
            .await
            .ok()?;
        let word = body.get("result")?.as_str()?.strip_prefix("0x")?;
        if word.len() != 64 {
            return None;
        }
        u8::from_str_radix(word.get(62..)?, 16)
            .ok()
            .filter(|_| word[..62].bytes().all(|b| b == b'0'))
    }
}

fn book_tokens(raw: &Value) -> Vec<Address> {
    let mut tokens: Vec<Address> = raw
        .get("books")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .flat_map(|book| ["token1Address", "token2Address"].map(|k| book.get(k)))
        .flatten()
        .filter_map(|v| v.as_str().and_then(|s| parse_address(s).ok()))
        .collect();
    tokens.sort();
    tokens.dedup();
    tokens
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
        variant: Some(variant),
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
    decimals: Arc<TokenDecimals>,
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
            decimals: Arc::new(TokenDecimals::new(HashMap::new(), None)),
        }
    }

    /// Add to or override [`TOKEN_DECIMALS`]; with `eth_rpc_url`, a token in
    /// neither has its `decimals()` read once and cached, otherwise books
    /// quoting it are skipped.
    pub fn with_decimals(
        mut self,
        decimals: HashMap<Address, u8>,
        eth_rpc_url: Option<String>,
    ) -> Self {
        self.decimals = Arc::new(TokenDecimals::new(decimals, eth_rpc_url));
        self
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
            .rpc("titan_getPammBooks", serde_json::json!([]))
            .await?;
        let decimals = self.decimals.resolve(&result).await;
        parse_price_levels_message_with(&result, &decimals).map(Arc::new)
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

struct PriceLevelsWsHandler;

impl WsHandler for PriceLevelsWsHandler {
    // Kept raw and parsed per call, once any unknown token's decimals are read.
    type Snapshot = Value;

    fn apply_frame(snapshot: &mut Arc<Self::Snapshot>, text: &str) -> bool {
        let Ok(value) = serde_json::from_str::<Value>(text) else {
            return false;
        };
        // Reject undecodable frames up front.
        if parse_price_levels_message(&value).is_err() {
            return false;
        }
        // Each frame is a complete snapshot, so it replaces the cached one.
        *snapshot = Arc::new(value);
        true
    }

    fn closed_error() -> Error {
        Error::Prices("price-levels source is closed".into())
    }

    fn timeout_error(timeout: Duration) -> Error {
        Error::Timeout(format!("no price-levels frame received within {timeout:?}"))
    }
}

/// Streaming source: connects lazily on the first `get_price_levels` call and
/// reconnects with exponential backoff. Unlike the overrides stream, each
/// price-levels frame is a *complete* snapshot, so a frame replaces the cached
/// one outright. The connection is dropped after `idle_timeout` without calls
/// and re-established on demand, so no explicit teardown is needed;
/// [`PriceLevelsSource::close`] tears down immediately and permanently.
pub struct PriceLevelsWsSource {
    conn: WsConnection<PriceLevelsWsHandler>,
    decimals: TokenDecimals,
}

impl Default for PriceLevelsWsSource {
    fn default() -> Self {
        Self::new(PriceLevelsWsSourceConfig::default())
    }
}

impl PriceLevelsWsSource {
    pub fn new(config: PriceLevelsWsSourceConfig) -> Self {
        Self {
            conn: WsConnection::new(config.url, config.idle_timeout, config.first_frame_timeout),
            decimals: TokenDecimals::new(HashMap::new(), None),
        }
    }

    /// As [`PriceLevelsRpcSource::with_decimals`].
    pub fn with_decimals(
        mut self,
        decimals: HashMap<Address, u8>,
        eth_rpc_url: Option<String>,
    ) -> Self {
        self.decimals = TokenDecimals::new(decimals, eth_rpc_url);
        self
    }
}

#[async_trait]
impl PriceLevelsSource for PriceLevelsWsSource {
    async fn get_price_levels(&self) -> Result<Arc<PriceLevelsSnapshot>> {
        let frame = self.conn.get_snapshot().await?;
        let decimals = self.decimals.resolve(&frame).await;
        parse_price_levels_message_with(&frame, &decimals).map(Arc::new)
    }

    fn close(&self) {
        self.conn.close();
    }
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

    /// Client with an explicit snapshot source and a specific RPC URL for the
    /// quote helpers. Use this when pairing a [`PriceLevelsWsSource`] with a
    /// private or regional deployment so quotes go to the same host as the
    /// stream. When `source` is a [`PriceLevelsRpcSource`], `rpc_url` is
    /// ignored and the source's own URL is reused.
    pub fn with_source_and_rpc_url(
        source: Arc<dyn PriceLevelsSource>,
        rpc_url: impl Into<String>,
    ) -> Self {
        let rpc = source
            .as_rpc_source()
            .unwrap_or_else(|| PriceLevelsRpcSource::new(rpc_url));
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
        assert_eq!(pair.order_book[0].variant, Some(PriceVariant::Simulated));
        assert_eq!(pair.order_book[1].variant, Some(PriceVariant::Interpolated));
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

    /// One real Tempest WETH/USDT book from the v2 stream, captured in the same
    /// Titan snapshot (slot 15445198) as the v1 payload, whose exact rungs were
    /// WETH -> USDT (5000000000000000, 12155777), (8118883695943608, 19738268)
    /// and USDT -> WETH (10000000, 4112431530672673), (17040037, 7007598544262898).
    fn v2_book(quote_address: &str) -> Value {
        serde_json::json!({
            "maker": "Tempest",
            "quoteAddress": quote_address,
            "token1Address": "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
            "token2Address": "0xdac17f958d2ee523a2206206994597c13d831ec7",
            "bids": [
                { "price": 2431.1554, "cumVolume": 0.005 },
                { "price": 2431.155407468359, "cumVolume": 0.008118883695943609 },
            ],
            "asks": [
                { "price": 2431.6514270000002, "cumVolume": 0.004112431530672673 },
                { "price": 2431.6514270000002, "cumVolume": 0.007007598544262898 },
            ],
        })
    }

    fn rungs(pair: &PairPriceLevels) -> Vec<(u128, u128)> {
        pair.order_book
            .iter()
            .map(|l| (l.amount_in.as_u128(), l.amount_out.as_u128()))
            .collect()
    }

    #[test]
    fn parse_v2_books_rebuilds_the_v1_base_unit_rungs() {
        let raw = serde_json::json!({
            "slot": 15445198, "block": 26206152, "ts": 1792166395085440933u64,
            "books": [v2_book("0x00000003f1ec2379e79f58e12ec6c4f51ee92149")],
        });
        let snapshot = parse_price_levels_message(&raw).unwrap();
        assert_eq!(snapshot.slot, Some(15_445_198));
        assert_eq!(snapshot.block_number, Some(26_206_152));
        assert_eq!(snapshot.timestamp_ns, Some(1_792_166_395_085_440_933));

        let pairs = &snapshot.pamms[0].pairs;
        // Bids sell token1 for token2; one amount lands 1 wei off v1 (Titan's float).
        assert_eq!(
            rungs(&pairs[0]),
            vec![
                (5_000_000_000_000_000, 12_155_777),
                (8_118_883_695_943_609, 19_738_268)
            ]
        );
        // Asks buy token1 with token2.
        assert_eq!(
            rungs(&pairs[1]),
            vec![
                (10_000_000, 4_112_431_530_672_673),
                (17_040_037, 7_007_598_544_262_898)
            ]
        );
        assert!(
            pairs
                .iter()
                .flat_map(|p| &p.order_book)
                .all(|l| l.variant.is_none())
        );
    }

    #[test]
    fn parse_v2_books_files_books_under_the_router_venue() {
        use crate::common::pamms::{KIPSELI, METRIC};
        let raw = serde_json::json!({ "books": [
            v2_book("0xc9a956b5196dfe110debe8781857bc8b97d32091"),
            v2_book("0xe844701934d9c6085b292e428f41b911cc0b3872"),
            v2_book("0x30a88bf894d1b806125a23ebf23d715496fd7102"),
        ]});
        let snapshot = parse_price_levels_message(&raw).unwrap();
        // Metric's two quote addresses collapse into one venue, one book per pair.
        let venues: Vec<_> = snapshot
            .pamms
            .iter()
            .map(|p| (p.pamm, p.pairs.len()))
            .collect();
        assert_eq!(venues, vec![(KIPSELI, 2), (METRIC, 2)]);
    }

    #[test]
    fn parse_v2_books_skips_unknown_tokens_and_empty_sides() {
        let dai = "0x6b175474e89094c44da98b954eedeac495271d0f";
        let mut unknown = v2_book("0x00000003f1ec2379e79f58e12ec6c4f51ee92149");
        unknown["token1Address"] = dai.into();
        let mut one_sided = v2_book("0x00000003f1ec2379e79f58e12ec6c4f51ee92149");
        one_sided["token2Address"] = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48".into();
        one_sided["bids"] = serde_json::json!([]);
        let raw = serde_json::json!({ "books": [unknown.clone(), one_sided] });

        let pairs = &parse_price_levels_message(&raw).unwrap().pamms[0].pairs;
        assert_eq!(pairs.len(), 1);
        assert_eq!(
            pairs[0].token_in,
            parse_address("0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48").unwrap()
        );

        // A caller-supplied decimals table makes the unknown token's book parse.
        let mut decimals: HashMap<Address, u8> = TOKEN_DECIMALS.into_iter().collect();
        decimals.insert(parse_address(dai).unwrap(), 18);
        let raw = serde_json::json!({ "books": [unknown] });
        let snapshot = parse_price_levels_message_with(&raw, &decimals).unwrap();
        assert_eq!(snapshot.pamms[0].pairs.len(), 2);
    }

    #[test]
    fn parse_v2_books_drops_rungs_past_u256_instead_of_panicking() {
        let mut book = v2_book("0x00000003f1ec2379e79f58e12ec6c4f51ee92149");
        book["bids"] = serde_json::json!([
            // cumVolume * price overflows a U256.
            { "price": 1e40, "cumVolume": 1e40 },
            // Fits as a decimal, but not once scaled to 18 decimals.
            { "price": 1.0, "cumVolume": 1e70 },
            { "price": 2431.1554, "cumVolume": 0.005 },
        ]);
        // Small enough that 10^scale overflows; it rounds to zero base units.
        book["asks"] = serde_json::json!([{ "price": 1e-90, "cumVolume": 1.0 }]);
        let raw = serde_json::json!({ "books": [book] });

        let pairs = &parse_price_levels_message(&raw).unwrap().pamms[0].pairs;
        assert_eq!(rungs(&pairs[0]), vec![(5_000_000_000_000_000, 12_155_777)]);
        assert_eq!(rungs(&pairs[1]), vec![(0, 1_000_000_000_000_000_000)]);
    }

    #[test]
    fn extract_rpc_result_errors_without_result_or_error() {
        let body = serde_json::json!({ "jsonrpc": "2.0", "id": 1 });
        assert!(matches!(extract_rpc_result(&body), Err(Error::Prices(_))));
    }
}
