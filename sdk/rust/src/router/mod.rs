//! Typed bindings for the `PropAMMRouter` contract, built on
//! [`ContractClient`]. Method names drop the on-chain `V1` suffix:
//! `router.swap(...)` calls `swapV1`, and so on.

pub mod abi;

use std::sync::Arc;

use alloy_primitives::{Address, TxHash, U256};
use alloy_sol_types::{SolEvent, SolInterface};

use crate::client::{BlockOverrideSet, CallOverrides, ContractClient, TransactionReceipt};
use crate::common::tokens::ETH_SENTINEL;
use crate::convert::{h256_to_b256, to_ethrex_address};
use crate::error::{Error, Result};
use crate::overrides::{
    OverridesSnapshot, OverridesSource, OverridesWsSource, ToStateOverrideOptions,
    to_state_override,
};
use abi::{IERC20, IPropAMMRouter};

pub use abi::IPropAMMRouter::FrontendFee;

/// Maximum frontend fee accepted by the `swap_*_with_fee` entrypoints, in bps.
pub const MAX_FEE_BPS: u16 = 100;

/// Validated [`FrontendFee`] builder. Fails if `bps` exceeds [`MAX_FEE_BPS`]
/// or the recipient is the zero address.
pub fn frontend_fee(bps: u16, recipient: Address) -> Result<FrontendFee> {
    if bps > MAX_FEE_BPS {
        return Err(Error::InvalidInput(format!(
            "fee bps must be in [0, {MAX_FEE_BPS}], got {bps}"
        )));
    }
    if recipient == Address::ZERO {
        return Err(Error::InvalidInput(
            "fee recipient must not be the zero address".into(),
        ));
    }
    Ok(FrontendFee { bps, recipient })
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
    /// Minimum acceptable amount of `token_out` (net of fee, on the `with_fee` paths).
    pub amount_out_min: U256,
    /// Address that receives `token_out`.
    pub recipient: Address,
    /// Unix timestamp after which the swap is no longer valid (see `deadline_in`).
    pub deadline: U256,
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
    pub hash: TxHash,
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

/// Per-call quote options; `Default` mirrors the plain quote methods.
#[derive(Default)]
pub struct QuoteOptions {
    pub overrides: QuoteOverrides,
    /// Skip injecting the Bebop default slot when no Bebop entry is present.
    pub skip_bebop_default: bool,
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

    /// [`Self::quote`] with explicit per-call options.
    pub async fn quote_with(
        &self,
        token_in: Address,
        token_out: Address,
        amount_in: U256,
        opts: &QuoteOptions,
    ) -> Result<Quote> {
        let overrides = self.resolve_overrides(opts).await?;
        let ret = self
            .call_router(
                &IPropAMMRouter::quoteV1Call {
                    tokenIn: token_in,
                    tokenOut: token_out,
                    amount: amount_in,
                },
                &overrides,
            )
            .await?;
        Ok(Quote {
            amount_out: ret.bestQuote,
            venue: ret.venue,
        })
    }

    /// Quote a specific venue. Falls back to the Uniswap V3 quote (reporting
    /// the fallback router as `venue`) when the venue cannot be priced.
    pub async fn quote_venue(
        &self,
        venue: Address,
        token_in: Address,
        token_out: Address,
        amount_in: U256,
    ) -> Result<Quote> {
        self.quote_venue_with(
            venue,
            token_in,
            token_out,
            amount_in,
            &QuoteOptions::default(),
        )
        .await
    }

    /// [`Self::quote_venue`] with explicit per-call options.
    pub async fn quote_venue_with(
        &self,
        venue: Address,
        token_in: Address,
        token_out: Address,
        amount_in: U256,
        opts: &QuoteOptions,
    ) -> Result<Quote> {
        let overrides = self.resolve_overrides(opts).await?;
        let ret = self
            .call_router(
                &IPropAMMRouter::quoteVenueV1Call {
                    venue,
                    tokenIn: token_in,
                    tokenOut: token_out,
                    amount: amount_in,
                },
                &overrides,
            )
            .await?;
        Ok(Quote {
            amount_out: ret.amountOut,
            venue: ret.quotedVenue,
        })
    }

    /// Best quote among a caller-supplied set of venues.
    pub async fn quote_selected_venues(
        &self,
        venues: Vec<Address>,
        token_in: Address,
        token_out: Address,
        amount_in: U256,
    ) -> Result<Quote> {
        self.quote_selected_venues_with(
            venues,
            token_in,
            token_out,
            amount_in,
            &QuoteOptions::default(),
        )
        .await
    }

    /// [`Self::quote_selected_venues`] with explicit per-call options.
    pub async fn quote_selected_venues_with(
        &self,
        venues: Vec<Address>,
        token_in: Address,
        token_out: Address,
        amount_in: U256,
        opts: &QuoteOptions,
    ) -> Result<Quote> {
        let overrides = self.resolve_overrides(opts).await?;
        let ret = self
            .call_router(
                &IPropAMMRouter::quoteSelectedVenuesV1Call {
                    venues,
                    tokenIn: token_in,
                    tokenOut: token_out,
                    amountIn: amount_in,
                },
                &overrides,
            )
            .await?;
        Ok(Quote {
            amount_out: ret.bestAmountOut,
            venue: ret.bestVenue,
        })
    }

    /// Quote the Uniswap V3 fallback route directly. Never applies overrides —
    /// the fallback quoter only reads live on-chain pool state.
    pub async fn quote_uniswap_v3(
        &self,
        token_in: Address,
        token_out: Address,
        amount_in: U256,
    ) -> Result<U256> {
        self.call_router(
            &IPropAMMRouter::quoteUniswapV3Call {
                tokenIn: token_in,
                tokenOut: token_out,
                amount: amount_in,
            },
            &CallOverrides::default(),
        )
        .await
    }

    //-------//
    // Swaps //
    //-------//
    // ETH input: when `token_in` is `ETH_SENTINEL` the router expects
    // `msg.value == amount_in`; the bindings attach it automatically. ERC-20
    // input requires a prior allowance for the router (see `approve`).

    /// Swap through the best-quoting venue.
    pub async fn swap(&self, params: &SwapParams) -> Result<TxHash> {
        self.send_swap(
            &IPropAMMRouter::swapV1Call {
                tokenIn: params.token_in,
                tokenOut: params.token_out,
                amountIn: params.amount_in,
                amountOutMin: params.amount_out_min,
                recipient: params.recipient,
                deadline: params.deadline,
            },
            params,
        )
        .await
    }

    /// Best-venue swap that skims a frontend fee from the output.
    pub async fn swap_with_fee(&self, params: &SwapParams, fee: FrontendFee) -> Result<TxHash> {
        self.send_swap(
            &IPropAMMRouter::swapWithFeeV1Call {
                tokenIn: params.token_in,
                tokenOut: params.token_out,
                amountIn: params.amount_in,
                amountOutMin: params.amount_out_min,
                recipient: params.recipient,
                deadline: params.deadline,
                fee,
            },
            params,
        )
        .await
    }

    /// Swap through an explicit venue (a whitelisted propAMM or the fallback router).
    pub async fn swap_via_venue(&self, venue: Address, params: &SwapParams) -> Result<TxHash> {
        self.send_swap(
            &IPropAMMRouter::swapViaVenueV1Call {
                venue,
                tokenIn: params.token_in,
                tokenOut: params.token_out,
                amountIn: params.amount_in,
                amountOutMin: params.amount_out_min,
                recipient: params.recipient,
                deadline: params.deadline,
            },
            params,
        )
        .await
    }

    /// Explicit-venue swap that skims a frontend fee from the output.
    pub async fn swap_via_venue_with_fee(
        &self,
        venue: Address,
        params: &SwapParams,
        fee: FrontendFee,
    ) -> Result<TxHash> {
        self.send_swap(
            &IPropAMMRouter::swapViaVenueWithFeeV1Call {
                venue,
                tokenIn: params.token_in,
                tokenOut: params.token_out,
                amountIn: params.amount_in,
                amountOutMin: params.amount_out_min,
                recipient: params.recipient,
                deadline: params.deadline,
                fee,
            },
            params,
        )
        .await
    }

    /// Swap through the best of a caller-supplied set of venues.
    pub async fn swap_via_selected_venues(
        &self,
        venues: Vec<Address>,
        params: &SwapParams,
    ) -> Result<TxHash> {
        self.send_swap(
            &IPropAMMRouter::swapViaSelectedVenuesV1Call {
                venues,
                tokenIn: params.token_in,
                tokenOut: params.token_out,
                amountIn: params.amount_in,
                amountOutMin: params.amount_out_min,
                recipient: params.recipient,
                deadline: params.deadline,
            },
            params,
        )
        .await
    }

    /// Selected-venues swap that skims a frontend fee from the output.
    pub async fn swap_via_selected_venues_with_fee(
        &self,
        venues: Vec<Address>,
        params: &SwapParams,
        fee: FrontendFee,
    ) -> Result<TxHash> {
        self.send_swap(
            &IPropAMMRouter::swapViaSelectedVenuesWithFeeV1Call {
                venues,
                tokenIn: params.token_in,
                tokenOut: params.token_out,
                amountIn: params.amount_in,
                amountOutMin: params.amount_out_min,
                recipient: params.recipient,
                deadline: params.deadline,
                fee,
            },
            params,
        )
        .await
    }

    //----------------//
    // Combined swaps //
    //----------------//
    // Same as the methods above, but wait for the receipt and decode the result.

    pub async fn swap_and_wait(&self, params: &SwapParams) -> Result<SwapResult> {
        self.wait_for_swap(self.swap(params).await?).await
    }

    pub async fn swap_with_fee_and_wait(
        &self,
        params: &SwapParams,
        fee: FrontendFee,
    ) -> Result<SwapResult> {
        self.wait_for_swap(self.swap_with_fee(params, fee).await?)
            .await
    }

    pub async fn swap_via_venue_and_wait(
        &self,
        venue: Address,
        params: &SwapParams,
    ) -> Result<SwapResult> {
        self.wait_for_swap(self.swap_via_venue(venue, params).await?)
            .await
    }

    pub async fn swap_via_venue_with_fee_and_wait(
        &self,
        venue: Address,
        params: &SwapParams,
        fee: FrontendFee,
    ) -> Result<SwapResult> {
        self.wait_for_swap(self.swap_via_venue_with_fee(venue, params, fee).await?)
            .await
    }

    pub async fn swap_via_selected_venues_and_wait(
        &self,
        venues: Vec<Address>,
        params: &SwapParams,
    ) -> Result<SwapResult> {
        self.wait_for_swap(self.swap_via_selected_venues(venues, params).await?)
            .await
    }

    pub async fn swap_via_selected_venues_with_fee_and_wait(
        &self,
        venues: Vec<Address>,
        params: &SwapParams,
        fee: FrontendFee,
    ) -> Result<SwapResult> {
        self.wait_for_swap(
            self.swap_via_selected_venues_with_fee(venues, params, fee)
                .await?,
        )
        .await
    }

    /// Wait until a swap transaction is mined and decode its outcome from the
    /// router's `Swapped` (and, when present, `FrontendFeeCharged`) events.
    /// Fails if the transaction reverted or emitted no `Swapped` event.
    pub async fn wait_for_swap(&self, hash: TxHash) -> Result<SwapResult> {
        let receipt = self.client.wait_for_transaction(hash).await?;
        if !receipt.receipt.status {
            return Err(Error::Other(format!("swap transaction {hash} reverted")));
        }

        let swapped = self
            .decode_router_logs::<IPropAMMRouter::Swapped>(&receipt)
            .into_iter()
            .next()
            .ok_or_else(|| {
                Error::Other(format!(
                    "transaction {hash} emitted no Swapped event from {}",
                    self.address
                ))
            })?;

        let fee = self
            .decode_router_logs::<IPropAMMRouter::FrontendFeeCharged>(&receipt)
            .into_iter()
            .next()
            .map(|event| FeeCharged {
                recipient: event.feeRecipient,
                amount: event.feeAmount,
            });

        Ok(SwapResult {
            hash,
            amount_in: swapped.amountIn,
            amount_out: swapped.amountOut,
            executed_venue: swapped.marketMaker,
            recipient: swapped.recipient,
            fee,
            receipt,
        })
    }

    //--------//
    // ERC-20 //
    //--------//

    /// Approve the router to pull `amount` of `token` from the signer.
    pub async fn approve(&self, token: Address, amount: U256) -> Result<TxHash> {
        self.client
            .send(
                token,
                &IERC20::approveCall {
                    spender: self.address,
                    amount,
                },
                None,
            )
            .await
    }

    /// Current router allowance of `token` granted by `owner`.
    pub async fn allowance(&self, token: Address, owner: Address) -> Result<U256> {
        self.client
            .call(
                token,
                &IERC20::allowanceCall {
                    owner,
                    spender: self.address,
                },
                &CallOverrides::default(),
            )
            .await
    }

    //-------//
    // Views //
    //-------//

    /// The Uniswap fallback "venue" address (dynamic router configuration).
    pub async fn fallback_swap_router(&self) -> Result<Address> {
        self.call_router(
            &IPropAMMRouter::fallbackSwapRouterCall {},
            &CallOverrides::default(),
        )
        .await
    }

    pub async fn fallback_quoter(&self) -> Result<Address> {
        self.call_router(
            &IPropAMMRouter::fallbackQuoterCall {},
            &CallOverrides::default(),
        )
        .await
    }

    pub async fn fallback_fee(&self) -> Result<u32> {
        let fee = self
            .call_router(
                &IPropAMMRouter::fallbackFeeCall {},
                &CallOverrides::default(),
            )
            .await?;
        Ok(fee.to::<u32>())
    }

    /// Raw per-pair fee override (0 if unset). Order-independent.
    pub async fn get_pair_fee(&self, token_a: Address, token_b: Address) -> Result<u32> {
        let fee = self
            .call_router(
                &IPropAMMRouter::getPairFeeCall {
                    tokenA: token_a,
                    tokenB: token_b,
                },
                &CallOverrides::default(),
            )
            .await?;
        Ok(fee.to::<u32>())
    }

    /// Effective Uniswap V3 fallback tier for a pair (override or global).
    pub async fn resolved_fee(&self, token_in: Address, token_out: Address) -> Result<u32> {
        let fee = self
            .call_router(
                &IPropAMMRouter::resolvedFeeCall {
                    tokenIn: token_in,
                    tokenOut: token_out,
                },
                &CallOverrides::default(),
            )
            .await?;
        Ok(fee.to::<u32>())
    }

    pub async fn is_whitelisted_venue(&self, venue: Address) -> Result<bool> {
        self.call_router(
            &IPropAMMRouter::isWhitelistedVenueCall { venue },
            &CallOverrides::default(),
        )
        .await
    }

    /// Every whitelisted propAMM venue (excludes the Uniswap fallback).
    pub async fn get_whitelisted_venues(&self) -> Result<Vec<Address>> {
        self.call_router(
            &IPropAMMRouter::getWhitelistedVenuesCall {},
            &CallOverrides::default(),
        )
        .await
    }

    pub async fn paused(&self) -> Result<bool> {
        self.call_router(&IPropAMMRouter::pausedCall {}, &CallOverrides::default())
            .await
    }

    //-----------//
    // Internals //
    //-----------//

    /// `ContractClient::call` against the router, with revert data decoded
    /// into the contract's named errors when possible.
    async fn call_router<C: alloy_sol_types::SolCall>(
        &self,
        call: &C,
        overrides: &CallOverrides,
    ) -> Result<C::Return> {
        self.client
            .call(self.address, call, overrides)
            .await
            .map_err(decode_revert)
    }

    fn decode_router_logs<E: SolEvent>(&self, receipt: &TransactionReceipt) -> Vec<E> {
        let router = to_ethrex_address(self.address);
        receipt
            .logs
            .iter()
            .filter(|log| log.log.address == router)
            .filter_map(|log| {
                let topics: Vec<_> = log.log.topics.iter().copied().map(h256_to_b256).collect();
                E::decode_raw_log(topics, &log.log.data).ok()
            })
            .collect()
    }

    /// Resolve a quote's override options into eth_call parameters. The
    /// snapshot's block number and timestamp are attached only alongside
    /// overrides — venues revert when the simulated block context doesn't
    /// match their pushed state.
    async fn resolve_overrides(&self, opts: &QuoteOptions) -> Result<CallOverrides> {
        let snapshot = match &opts.overrides {
            QuoteOverrides::Skip => return Ok(CallOverrides::default()),
            QuoteOverrides::Attached => self.overrides.get_overrides().await?,
            QuoteOverrides::Source(source) => source.get_overrides().await?,
            QuoteOverrides::Snapshot(snapshot) => snapshot.clone(),
        };

        let state = to_state_override(
            &snapshot,
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
                time: snapshot.timestamp_ns.map(|ns| ns / 1_000_000_000),
                ..Default::default()
            }),
        })
    }

    async fn send_swap<C: alloy_sol_types::SolCall>(
        &self,
        call: &C,
        params: &SwapParams,
    ) -> Result<TxHash> {
        // Native-ETH input is signalled by the sentinel and paid via msg.value.
        let value = (params.token_in == ETH_SENTINEL).then_some(params.amount_in);
        self.client.send(self.address, call, value).await
    }
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
    match IPropAMMRouter::IPropAMMRouterErrors::abi_decode(data) {
        Ok(decoded) => Error::Revert {
            message: format!("{message} ({decoded:?})"),
            data: Some(data.clone()),
        },
        Err(_) => error,
    }
}
