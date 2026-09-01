//! Typed bindings for the `PropAMMRouter` contract, built on
//! [`ContractClient`]. Method names drop the on-chain `V1` suffix:
//! `router.swap(...)` calls `swapV1`, and so on.

pub mod abi;

use std::sync::Arc;

use ethrex_common::{Address, H256, U256};
use ethrex_l2_sdk::calldata::encode_calldata;

use crate::client::{BlockOverrideSet, CallOverrides, ContractClient, TransactionReceipt};
use crate::common::tokens::ETH_SENTINEL;
use crate::error::{Error, Result};
use crate::overrides::{
    OverridesSnapshot, OverridesSource, OverridesWsSource, ToStateOverrideOptions,
    to_state_override,
};
use abi::Value;

/// Maximum frontend fee accepted by the router, in bps.
pub const MAX_FEE_BPS: u16 = 100;

/// Frontend fee skimmed from a swap's output — pass via
/// [`SwapOptions::frontend_fee`]. Encodes as the contract's `FrontendFee` struct.
#[derive(Debug, Clone, Copy)]
pub struct FrontendFee {
    pub bps: u16,
    pub recipient: Address,
}

impl FrontendFee {
    fn to_value(self) -> Value {
        Value::Tuple(vec![
            Value::Uint(U256::from(self.bps)),
            Value::Address(self.recipient),
        ])
    }
}

/// Common parameters shared by every swap entrypoint.
#[derive(Debug, Clone)]
pub struct SwapParams {
    /// Token being sold, or [`ETH_SENTINEL`] for native ETH.
    pub token_in: Address,
    /// Token being bought, or [`ETH_SENTINEL`] for native ETH.
    pub token_out: Address,
    /// Exact amount of `token_in` to sell, in atomic units.
    pub amount_in: U256,
    /// Minimum acceptable amount of `token_out` (net of the frontend fee, when one is passed).
    pub amount_out_min: U256,
    /// Address that receives `token_out`.
    pub recipient: Address,
    /// Unix timestamp after which the swap is no longer valid (see `deadline_in`).
    pub deadline: U256,
}

impl SwapParams {
    /// The trailing argument list shared by every swap entrypoint.
    fn values(&self) -> Vec<Value> {
        vec![
            Value::Address(self.token_in),
            Value::Address(self.token_out),
            Value::Uint(self.amount_in),
            Value::Uint(self.amount_out_min),
            Value::Address(self.recipient),
            Value::Uint(self.deadline),
        ]
    }
}

/// Result of an on-chain quote: best output and the venue that produced it.
#[derive(Debug, Clone)]
pub struct Quote {
    pub amount_out: U256,
    pub venue: Address,
}

/// Decoded outcome of a mined swap (from the `Swapped` event).
#[derive(Debug)]
pub struct SwapResult {
    pub hash: H256,
    pub receipt: TransactionReceipt,
    pub amount_in: U256,
    pub amount_out: U256,
    /// The venue that filled, or the Uniswap fallback router address.
    pub executed_venue: Address,
    pub recipient: Address,
    /// Present when the swap charged a frontend fee (`FrontendFeeCharged`).
    pub fee: Option<FeeCharged>,
}

/// Frontend fee actually charged by a swap.
#[derive(Debug, Clone)]
pub struct FeeCharged {
    pub recipient: Address,
    pub amount: U256,
}

/// Override source for a single quote call.
#[derive(Default)]
pub enum QuoteOverrides {
    /// Use the router's attached source (the default).
    #[default]
    Attached,
    /// Quote without state overrides.
    Skip,
    /// Use this source for this call only.
    Source(Arc<dyn OverridesSource>),
    /// Use this fixed snapshot.
    Snapshot(OverridesSnapshot),
}

/// Per-call quote options; `Default` mirrors the plain [`PropAmmRouter::quote`].
#[derive(Default)]
pub struct QuoteOptions {
    pub overrides: QuoteOverrides,
    /// Skip injecting the Bebop default slot when no Bebop entry is present.
    pub skip_bebop_default: bool,
    /// Restrict the quote to these venues: a single entry quotes that venue
    /// directly, several pick the best among them. Must be non-empty when
    /// present; `None` quotes across every whitelisted venue.
    pub venues: Option<Vec<Address>>,
}

/// Per-swap options; `Default` mirrors the plain [`PropAmmRouter::swap`].
#[derive(Default)]
pub struct SwapOptions {
    /// Restrict the swap to these venues: a single entry executes through
    /// that venue directly (failing `UnknownVenue` on a bad address), several
    /// re-quote on-chain and fill via the best of them (unpriceable entries
    /// are skipped). Must be non-empty when present; `None` swaps through the
    /// best-quoting venue overall.
    pub venues: Option<Vec<Address>>,
    /// Optional frontend fee skimmed from the output. When present the swap
    /// is routed through the contract's `WithFee` selector; `bps` must be in
    /// [1, [`MAX_FEE_BPS`]] and the recipient non-zero (validated before
    /// sending).
    pub frontend_fee: Option<FrontendFee>,
    /// Explicit gas limit (gas units) for the transaction. Overrides the
    /// hardcoded per-function default.
    pub gas_limit: Option<u64>,
}

/// Typed `PropAMMRouter` bindings. Quotes apply pAMM state overrides from the
/// attached source by default (a streaming [`OverridesWsSource`] unless one
/// is provided).
pub struct PropAmmRouter {
    address: Address,
    client: ContractClient,
    overrides: Arc<dyn OverridesSource>,
}

impl PropAmmRouter {
    /// Router with the default streaming overrides source (connects lazily on
    /// the first quote).
    pub fn new(client: ContractClient, address: Address) -> Self {
        Self::with_overrides(client, address, Arc::new(OverridesWsSource::default()))
    }

    /// Router with an explicit overrides source.
    pub fn with_overrides(
        client: ContractClient,
        address: Address,
        overrides: Arc<dyn OverridesSource>,
    ) -> Self {
        Self {
            address,
            client,
            overrides,
        }
    }

    pub fn address(&self) -> Address {
        self.address
    }

    pub fn client(&self) -> &ContractClient {
        &self.client
    }

    /// The attached overrides source quotes use by default.
    pub fn overrides(&self) -> &Arc<dyn OverridesSource> {
        &self.overrides
    }

    //--------//
    // Quotes //
    //--------//
    // The quote functions are nonpayable on-chain, so they go through
    // `ContractClient::call` (eth_call simulation). By default the simulation
    // carries the latest pAMM state overrides (plus their block
    // number/timestamp) so venues quote fresh off-chain liquidity.

    /// Best quote across all whitelisted venues and the Uniswap V3 fallback.
    pub async fn quote(
        &self,
        token_in: Address,
        token_out: Address,
        amount_in: U256,
    ) -> Result<Quote> {
        self.quote_with(token_in, token_out, amount_in, &QuoteOptions::default())
            .await
    }

    /// [`Self::quote`] with explicit per-call options: `opts.venues` restricts
    /// the quote (see [`QuoteOptions::venues`]). Restricted quotes fall back
    /// to the Uniswap V3 quote (reporting the fallback router as `venue`)
    /// when no listed venue can be priced.
    pub async fn quote_with(
        &self,
        token_in: Address,
        token_out: Address,
        amount_in: U256,
        opts: &QuoteOptions,
    ) -> Result<Quote> {
        let (mode, mut args) = venue_dispatch(opts.venues.as_deref())?;
        args.extend([
            Value::Address(token_in),
            Value::Address(token_out),
            Value::Uint(amount_in),
        ]);
        self.quote_call(mode.quote_selector(), &args, opts).await
    }

    //-------//
    // Swaps //
    //-------//
    // ETH input: when `token_in` is `ETH_SENTINEL` the router expects
    // `msg.value == amount_in`; the bindings attach it automatically. ERC-20
    // input requires a prior allowance for the router (see `approve`).

    /// Swap through the best-quoting venue.
    pub async fn swap(&self, params: &SwapParams) -> Result<H256> {
        self.swap_with(params, &SwapOptions::default()).await
    }

    /// [`Self::swap`] with explicit per-call options: `opts.venues` restricts
    /// the swap (see [`SwapOptions::venues`]) and `opts.frontend_fee` routes
    /// the call through the contract's `WithFee` selector, which skims the
    /// fee from the output.
    pub async fn swap_with(&self, params: &SwapParams, opts: &SwapOptions) -> Result<H256> {
        let (mode, mut args) = venue_dispatch(opts.venues.as_deref())?;
        args.extend(params.values());
        if let Some(fee) = &opts.frontend_fee {
            validate_fee(fee)?;
            // The `WithFee` selectors take the same tuple plus the fee struct last.
            args.push(fee.to_value());
        }
        let signature = mode.swap_selector(opts.frontend_fee.is_some());
        // Native-ETH input is signalled by the sentinel and paid via msg.value.
        let value = (params.token_in == ETH_SENTINEL).then_some(params.amount_in);
        self.client
            .send(
                self.address,
                signature,
                encode(signature, &args)?,
                value,
                opts.gas_limit,
            )
            .await
    }

    /// Same as [`Self::swap`], but waits for the receipt and decodes the result.
    pub async fn swap_and_wait(&self, params: &SwapParams) -> Result<SwapResult> {
        self.wait_for_swap(self.swap(params).await?).await
    }

    /// Same as [`Self::swap_with`], but waits for the receipt and decodes the result.
    pub async fn swap_and_wait_with(
        &self,
        params: &SwapParams,
        opts: &SwapOptions,
    ) -> Result<SwapResult> {
        self.wait_for_swap(self.swap_with(params, opts).await?)
            .await
    }

    /// Wait until a swap transaction is mined and decode its outcome from the
    /// router's `Swapped` (and, when present, `FrontendFeeCharged`) events.
    /// Fails if the transaction reverted or emitted no `Swapped` event.
    pub async fn wait_for_swap(&self, hash: H256) -> Result<SwapResult> {
        let receipt = self.client.wait_for_transaction(hash).await?;
        if !receipt.receipt.status {
            return Err(Error::TransactionReverted {
                hash,
                receipt: Box::new(receipt),
            });
        }

        let swapped_topic = abi::event_topic(abi::SWAPPED_EVENT);
        let fee_topic = abi::event_topic(abi::FRONTEND_FEE_CHARGED_EVENT);

        let mut swapped = None;
        let mut fee = None;
        for log in &receipt.logs {
            if log.log.address != self.address {
                continue;
            }
            let Some(topic0) = log.log.topics.first() else {
                continue;
            };
            if *topic0 == swapped_topic && swapped.is_none() {
                // Swapped data fields: (amountIn, amountOut, recipient, marketMaker)
                let values = abi::decode_values("uint256,uint256,address,address", &log.log.data)?;
                swapped = Some((
                    abi::as_u256(&values[0])?,
                    abi::as_u256(&values[1])?,
                    abi::as_address(&values[2])?,
                    abi::as_address(&values[3])?,
                ));
            } else if *topic0 == fee_topic && fee.is_none() {
                // FrontendFeeCharged: feeRecipient is indexed (topic 1),
                // feeAmount is the only data field.
                let recipient = log
                    .log
                    .topics
                    .get(1)
                    .map(abi::topic_as_address)
                    .ok_or_else(|| Error::Abi("FrontendFeeCharged missing topic".into()))?;
                let values = abi::decode_values("uint256", &log.log.data)?;
                fee = Some(FeeCharged {
                    recipient,
                    amount: abi::as_u256(&values[0])?,
                });
            }
        }

        let (amount_in, amount_out, recipient, market_maker) =
            swapped.ok_or(Error::MissingEvent {
                hash,
                event: "Swapped",
            })?;

        Ok(SwapResult {
            hash,
            receipt,
            amount_in,
            amount_out,
            executed_venue: market_maker,
            recipient,
            fee,
        })
    }

    //--------//
    // ERC-20 //
    //--------//

    /// Approve the router to pull `amount` of `token` from the signer.
    pub async fn approve(&self, token: Address, amount: U256) -> Result<H256> {
        let calldata = encode(
            abi::ERC20_APPROVE,
            &[Value::Address(self.address), Value::Uint(amount)],
        )?;
        self.client
            .send(token, abi::ERC20_APPROVE, calldata, None, None)
            .await
    }

    /// Current router allowance of `token` granted by `owner`.
    pub async fn allowance(&self, token: Address, owner: Address) -> Result<U256> {
        let calldata = encode(
            abi::ERC20_ALLOWANCE,
            &[Value::Address(owner), Value::Address(self.address)],
        )?;
        let data = self
            .client
            .call(token, calldata, &CallOverrides::default())
            .await?;
        abi::as_u256(&abi::decode_values("uint256", &data)?[0])
    }

    //-------//
    // Views //
    //-------//

    /// The Uniswap fallback "venue" address (dynamic router configuration).
    pub async fn fallback_swap_router(&self) -> Result<Address> {
        self.view_address(abi::FALLBACK_SWAP_ROUTER).await
    }

    pub async fn fallback_quoter(&self) -> Result<Address> {
        self.view_address(abi::FALLBACK_QUOTER).await
    }

    pub async fn fallback_fee(&self) -> Result<u32> {
        let data = self
            .call_router(abi::FALLBACK_FEE, &[], &CallOverrides::default())
            .await?;
        Ok(abi::as_u256(&abi::decode_values("uint24", &data)?[0])?.low_u32())
    }

    /// Raw per-pair fee override (0 if unset). Order-independent.
    pub async fn get_pair_fee(&self, token_a: Address, token_b: Address) -> Result<u32> {
        let args = [Value::Address(token_a), Value::Address(token_b)];
        let data = self
            .call_router(abi::GET_PAIR_FEE, &args, &CallOverrides::default())
            .await?;
        Ok(abi::as_u256(&abi::decode_values("uint24", &data)?[0])?.low_u32())
    }

    /// Effective Uniswap V3 fallback tier for a pair (override or global).
    pub async fn resolved_fee(&self, token_in: Address, token_out: Address) -> Result<u32> {
        let args = [Value::Address(token_in), Value::Address(token_out)];
        let data = self
            .call_router(abi::RESOLVED_FEE, &args, &CallOverrides::default())
            .await?;
        Ok(abi::as_u256(&abi::decode_values("uint24", &data)?[0])?.low_u32())
    }

    pub async fn is_whitelisted_venue(&self, venue: Address) -> Result<bool> {
        let data = self
            .call_router(
                abi::IS_WHITELISTED_VENUE,
                &[Value::Address(venue)],
                &CallOverrides::default(),
            )
            .await?;
        abi::as_bool(&abi::decode_values("bool", &data)?[0])
    }

    /// Every whitelisted propAMM venue (excludes the Uniswap fallback).
    pub async fn get_whitelisted_venues(&self) -> Result<Vec<Address>> {
        let data = self
            .call_router(abi::GET_WHITELISTED_VENUES, &[], &CallOverrides::default())
            .await?;
        abi::as_address_array(&abi::decode_values("address[]", &data)?[0])
    }

    pub async fn paused(&self) -> Result<bool> {
        let data = self
            .call_router(abi::PAUSED, &[], &CallOverrides::default())
            .await?;
        abi::as_bool(&abi::decode_values("bool", &data)?[0])
    }

    //-----------//
    // Internals //
    //-----------//

    /// Encode + call a quote entrypoint with resolved overrides and decode
    /// its `(uint256, address)` result.
    async fn quote_call(
        &self,
        signature: &str,
        args: &[Value],
        opts: &QuoteOptions,
    ) -> Result<Quote> {
        let overrides = self.resolve_overrides(opts).await?;
        let data = self.call_router(signature, args, &overrides).await?;
        let values = abi::decode_values("uint256,address", &data)?;
        Ok(Quote {
            amount_out: abi::as_u256(&values[0])?,
            venue: abi::as_address(&values[1])?,
        })
    }

    /// Encode + `eth_call` against the router, with revert data decoded into
    /// the contract's named errors when possible.
    async fn call_router(
        &self,
        signature: &str,
        args: &[Value],
        overrides: &CallOverrides,
    ) -> Result<Vec<u8>> {
        self.client
            .call(self.address, encode(signature, args)?, overrides)
            .await
            .map_err(decode_revert)
    }

    async fn view_address(&self, signature: &str) -> Result<Address> {
        let data = self
            .call_router(signature, &[], &CallOverrides::default())
            .await?;
        abi::as_address(&abi::decode_values("address", &data)?[0])
    }

    /// Resolve a quote's override options into eth_call parameters. The
    /// snapshot's block number and timestamp are attached only alongside
    /// overrides — venues revert when the simulated block context doesn't
    /// match their pushed state.
    async fn resolve_overrides(&self, opts: &QuoteOptions) -> Result<CallOverrides> {
        // Source-backed arms own an Arc (a cheap pointer clone); the
        // caller-supplied snapshot is borrowed in place. `owned` keeps the Arc
        // alive so both resolve to a single `&OverridesSnapshot`, with no deep
        // copy of the caller's snapshot.
        let owned;
        let snapshot: &OverridesSnapshot = match &opts.overrides {
            QuoteOverrides::Skip => return Ok(CallOverrides::default()),
            QuoteOverrides::Attached => {
                owned = self.overrides.get_overrides().await?;
                &owned
            }
            QuoteOverrides::Source(source) => {
                owned = source.get_overrides().await?;
                &owned
            }
            QuoteOverrides::Snapshot(snapshot) => snapshot,
        };

        let state = to_state_override(
            snapshot,
            &ToStateOverrideOptions {
                pamms: None,
                skip_bebop_default: opts.skip_bebop_default,
            },
        );
        if state.is_empty() {
            return Ok(CallOverrides::default());
        }

        Ok(CallOverrides {
            state: Some(state),
            block: Some(BlockOverrideSet {
                number: snapshot.block_number,
                // Canonical slot time (genesis + slot*12); emit time as fallback.
                time: snapshot.block_time_secs(),
                ..Default::default()
            }),
        })
    }
}

/// Venue-restriction mode resolved from an options' `venues` field.
#[derive(Clone, Copy)]
enum VenueMode {
    All,
    Single,
    Selected,
}

impl VenueMode {
    fn quote_selector(self) -> &'static str {
        match self {
            Self::All => abi::QUOTE,
            Self::Single => abi::QUOTE_VENUE,
            Self::Selected => abi::QUOTE_SELECTED_VENUES,
        }
    }

    fn swap_selector(self, with_fee: bool) -> &'static str {
        match (self, with_fee) {
            (Self::All, false) => abi::SWAP,
            (Self::All, true) => abi::SWAP_WITH_FEE,
            (Self::Single, false) => abi::SWAP_VIA_VENUE,
            (Self::Single, true) => abi::SWAP_VIA_VENUE_WITH_FEE,
            (Self::Selected, false) => abi::SWAP_VIA_SELECTED_VENUES,
            (Self::Selected, true) => abi::SWAP_VIA_SELECTED_VENUES_WITH_FEE,
        }
    }
}

/// Resolve a venue restriction into the selector mode and its leading args: a
/// single venue targets the direct `Venue` entrypoint, several the
/// `SelectedVenues` one. Empty restrictions fail — omit `venues` instead.
fn venue_dispatch(venues: Option<&[Address]>) -> Result<(VenueMode, Vec<Value>)> {
    match venues {
        None => Ok((VenueMode::All, vec![])),
        Some([]) => Err(Error::InvalidInput(
            "venues must not be empty — omit it to use every whitelisted venue".into(),
        )),
        Some([venue]) => Ok((VenueMode::Single, vec![Value::Address(*venue)])),
        Some(venues) => Ok((VenueMode::Selected, vec![address_array(venues.to_vec())])),
    }
}

/// Fails unless the fee has bps in [1, [`MAX_FEE_BPS`]] and a non-zero recipient.
fn validate_fee(fee: &FrontendFee) -> Result<()> {
    if !(1..=MAX_FEE_BPS).contains(&fee.bps) {
        return Err(Error::InvalidInput(format!(
            "fee bps must be in [1, {MAX_FEE_BPS}], got {}",
            fee.bps
        )));
    }
    if fee.recipient == Address::zero() {
        return Err(Error::InvalidInput(
            "fee recipient must not be the zero address".into(),
        ));
    }
    Ok(())
}

fn encode(signature: &str, args: &[Value]) -> Result<Vec<u8>> {
    encode_calldata(signature, args)
        .map_err(|e| Error::Abi(format!("failed to encode {signature}: {e}")))
}

fn address_array(addresses: Vec<Address>) -> Value {
    Value::Array(addresses.into_iter().map(Value::Address).collect())
}

/// Re-shape a raw revert into the contract's named error when the revert data
/// matches one (e.g. `InsufficientOutput(...)`).
fn decode_revert(error: Error) -> Error {
    let Error::Revert {
        message,
        data: Some(data),
    } = &error
    else {
        return error;
    };
    match abi::decode_error(data) {
        Some(decoded) => Error::Revert {
            message: format!("{message} ({decoded})"),
            data: Some(data.clone()),
        },
        None => error,
    }
}
