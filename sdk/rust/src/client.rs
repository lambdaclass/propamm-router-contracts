//! Thin wrapper around rex/ethrex's `EthClient` for reading from and writing
//! to contracts. This module owns the JSON-RPC transport, including
//! `eth_call` simulations with state and block overrides (rex's
//! `StateOverrideSet`/`BlockOverrideSet`); ABI encoding/decoding lives in
//! `router::abi` on ethrex's calldata codec.
//!
//! Calls go through rex's `call_with_overrides`, which flattens revert data
//! into its error string — [`parse_call_error`] recovers the payload from the
//! `" (data: 0x…)"` suffix so reverts still decode into named contract errors.

use std::{str::FromStr, sync::Arc};

use ethrex_common::{Address, H256, U256, types::TxType};
use ethrex_l2_rpc::signer::{LocalSigner, Signer};
use ethrex_l2_sdk::{build_generic_tx, send_generic_transaction};
use ethrex_rpc::{EthClient, clients::EthClientError, clients::Overrides};
use rex_sdk::client::eth::call_with_overrides;
use secp256k1::SecretKey;

use crate::error::{Error, Result};
use crate::router::abi;

/// The receipt type returned by the transport (re-exported from ethrex).
pub use ethrex_rpc::types::receipt::RpcReceipt as TransactionReceipt;
/// State and block override sets for `eth_call` (re-exported from rex).
pub use rex_sdk::client::eth::{AccountOverride, BlockOverrideSet, StateOverrideSet};

/// Receipt polling: 2s between attempts inside rex's helper.
const RECEIPT_MAX_RETRIES: u64 = 60;

/// Optional context for `eth_call` simulations.
#[derive(Debug, Clone, Default)]
pub struct CallOverrides {
    /// State overrides applied to the call (third RPC parameter).
    pub state: Option<StateOverrideSet>,
    /// Block overrides applied to the call (fourth RPC parameter), e.g. a
    /// pinned `number`/`time`.
    pub block: Option<BlockOverrideSet>,
}

/// Hardcoded gas limit (gas units) for a given on-chain function signature.
///
/// [`ContractClient::send`] attaches this value directly to the transaction,
/// skipping gas estimation entirely — estimation under-shoots when execution
/// takes a heavier branch than it simulated (e.g. a cheap venue fill estimated,
/// but the ~2x-costlier Uniswap fallback executed). Signatures with no entry
/// return `None` and are estimated by the node as usual.
///
/// The tiers reflect how much quoting each entrypoint does (none → all venues).
/// Values are set above the worst observed gas plus headroom, calibrated against
/// real mainnet swaps and the `test_gas_*` fork tests. `swap`/`*WithFee` quote
/// more venues than the measured paths, so they are kept conservatively higher.
fn gas_limit_for(signature: &str) -> Option<u64> {
    Some(match signature {
        abi::SWAP => 700_000,
        abi::SWAP_WITH_FEE => 750_000,
        abi::SWAP_VIA_SELECTED_VENUES => 700_000,
        abi::SWAP_VIA_SELECTED_VENUES_WITH_FEE => 750_000,
        abi::SWAP_VIA_VENUE => 500_000,
        abi::SWAP_VIA_VENUE_WITH_FEE => 550_000,
        _ => return None,
    })
}

/// JSON-RPC contract client. Construct read-only with [`ContractClient::connect`]
/// or signing with [`ContractClient::connect_with_signer`].
#[derive(Clone)]
pub struct ContractClient {
    client: Arc<EthClient>,
    signer: Option<Signer>,
}

impl ContractClient {
    /// Read-only client (quotes and views work; sends don't).
    pub fn connect(rpc_url: &str) -> Result<Self> {
        Ok(Self {
            client: Self::eth_client(rpc_url)?,
            signer: None,
        })
    }

    /// Signing client from a 0x-prefixed private key.
    pub fn connect_with_signer(rpc_url: &str, private_key: &str) -> Result<Self> {
        let key = SecretKey::from_str(private_key.trim_start_matches("0x"))
            .map_err(|e| Error::InvalidInput(format!("invalid private key: {e}")))?;
        Ok(Self {
            client: Self::eth_client(rpc_url)?,
            signer: Some(LocalSigner::new(key).into()),
        })
    }

    fn eth_client(rpc_url: &str) -> Result<Arc<EthClient>> {
        let url = rpc_url
            .parse()
            .map_err(|e| Error::InvalidInput(format!("invalid RPC url: {e}")))?;
        Ok(Arc::new(EthClient::new(url)?))
    }

    /// The underlying ethrex client, for anything not wrapped here.
    pub fn eth(&self) -> &EthClient {
        &self.client
    }

    /// Address of the configured signer, if any.
    pub fn signer_address(&self) -> Option<Address> {
        self.signer.as_ref().map(|s| s.address())
    }

    /// Simulate a call via `eth_call` and return its raw return data, with
    /// optional state and block overrides. Useful for nonpayable functions
    /// that are effectively queries (e.g. on-chain quotes).
    pub async fn call(
        &self,
        to: Address,
        calldata: Vec<u8>,
        overrides: &CallOverrides,
    ) -> Result<Vec<u8>> {
        let tx_overrides = Overrides {
            from: self.signer_address(),
            ..Default::default()
        };
        // Borrow the caller's override sets directly — cloning would deep-copy
        // the merged slot-diff map on every call. Empty defaults are cheap
        // (no heap allocation) and only used when an override is absent.
        let default_state = StateOverrideSet::default();
        let default_block = BlockOverrideSet::default();
        let state = overrides.state.as_ref().unwrap_or(&default_state);
        let block = overrides.block.as_ref().unwrap_or(&default_block);

        let raw = call_with_overrides(
            &self.client,
            to,
            calldata.into(),
            tx_overrides,
            state,
            block,
        )
        .await
        .map_err(parse_call_error)?;

        hex::decode(raw.trim_start_matches("0x"))
            .map_err(|e| Error::Abi(format!("eth_call returned invalid hex: {e}")))
    }

    /// Sign and send a contract call as an EIP-1559 transaction (nonce filled
    /// by the node). Returns the transaction hash.
    ///
    /// Gas limit precedence: an explicit `gas_limit`, else the per-function
    /// default keyed on `signature` ([`gas_limit_for`]), else the node's
    /// estimation. Passing a limit skips estimation, which can under-shoot the
    /// executed branch.
    pub async fn send(
        &self,
        to: Address,
        signature: &str,
        calldata: Vec<u8>,
        value: Option<U256>,
        gas_limit: Option<u64>,
    ) -> Result<H256> {
        let signer = self.signer.as_ref().ok_or_else(|| {
            Error::InvalidInput(
                "ContractClient was created without a signer; sends are unavailable".into(),
            )
        })?;

        let overrides = Overrides {
            from: Some(signer.address()),
            value,
            gas_limit: gas_limit.or_else(|| gas_limit_for(signature)),
            ..Default::default()
        };
        let tx = build_generic_tx(
            &self.client,
            TxType::EIP1559,
            to,
            signer.address(),
            calldata.into(),
            overrides,
        )
        .await?;
        Ok(send_generic_transaction(&self.client, tx, signer).await?)
    }

    /// Wait until a transaction is mined and return its receipt.
    pub async fn wait_for_transaction(&self, hash: H256) -> Result<TransactionReceipt> {
        let receipt =
            rex_sdk::wait_for_transaction_receipt(hash, &self.client, RECEIPT_MAX_RETRIES, true)
                .await?;
        Ok(receipt)
    }
}

/// Re-shape `call_with_overrides` errors. rex reports `eth_call` RPC errors as
/// `Custom("eth_call rpc error: <message> (data: 0x…)")`, with the revert
/// payload interpolated into the string — recover it so callers can decode
/// named contract errors. Parsing is coupled to rex's format string; if it
/// stops matching, errors degrade to undecoded messages, never wrong data.
fn parse_call_error(error: EthClientError) -> Error {
    let EthClientError::Custom(text) = &error else {
        return Error::Client(error);
    };
    let Some(rest) = text.strip_prefix("eth_call rpc error: ") else {
        return Error::Client(error);
    };

    if let Some((message, suffix)) = rest.rsplit_once(" (data: 0x")
        && let Some(data) = suffix
            .strip_suffix(')')
            .and_then(|hex_data| hex::decode(hex_data).ok())
    {
        return Error::Revert {
            message: message.to_string(),
            data: Some(data),
        };
    }
    Error::Revert {
        message: rest.to_string(),
        data: None,
    }
}
