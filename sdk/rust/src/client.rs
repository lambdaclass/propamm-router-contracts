//! Thin wrapper around rex/ethrex's `EthClient` for reading from and writing
//! to contracts. ABI encoding/decoding stays on alloy's `sol!` types; this
//! module owns the JSON-RPC transport, including `eth_call` simulations with
//! state and block overrides (rex's `StateOverrideSet`/`BlockOverrideSet`).
//!
//! Calls go through rex's `call_with_overrides`, which flattens revert data
//! into its error string — [`parse_call_error`] recovers the payload from the
//! `" (data: 0x…)"` suffix so reverts still decode into named contract errors.

use std::{str::FromStr, sync::Arc};

use alloy_primitives::{Address, TxHash, U256, hex};
use alloy_sol_types::SolCall;
use ethrex_common::types::TxType;
use ethrex_l2_rpc::signer::{LocalSigner, Signer};
use ethrex_l2_sdk::{build_generic_tx, send_generic_transaction};
use ethrex_rpc::{EthClient, clients::EthClientError, clients::Overrides};
use rex_sdk::client::eth::call_with_overrides;
use secp256k1::SecretKey;

use crate::convert::{h256_to_b256, to_alloy_address, to_ethrex_address, to_ethrex_u256};
use crate::error::{Error, Result};

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
        self.signer.as_ref().map(|s| to_alloy_address(s.address()))
    }

    /// Simulate a function via `eth_call` and decode its return value, with
    /// optional state and block overrides. Useful for nonpayable functions
    /// that are effectively queries (e.g. on-chain quotes).
    pub async fn call<C: SolCall>(
        &self,
        to: Address,
        call: &C,
        overrides: &CallOverrides,
    ) -> Result<C::Return> {
        let tx_overrides = Overrides {
            from: self.signer.as_ref().map(|s| s.address()),
            ..Default::default()
        };
        let state = overrides.state.clone().unwrap_or_default();
        let block = overrides.block.clone().unwrap_or_default();

        let raw = call_with_overrides(
            &self.client,
            to_ethrex_address(to),
            call.abi_encode().into(),
            tx_overrides,
            &state,
            &block,
        )
        .await
        .map_err(parse_call_error)?;

        let data = hex::decode(raw.trim_start_matches("0x"))
            .map_err(|e| Error::Abi(format!("eth_call returned invalid hex: {e}")))?;
        C::abi_decode_returns(&data)
            .map_err(|e| Error::Abi(format!("failed to decode {} return: {e}", C::SIGNATURE)))
    }

    /// Sign and send a contract call as an EIP-1559 transaction (gas and
    /// nonce are filled by the node). Returns the transaction hash.
    pub async fn send<C: SolCall>(
        &self,
        to: Address,
        call: &C,
        value: Option<U256>,
    ) -> Result<TxHash> {
        let signer = self.signer.as_ref().ok_or_else(|| {
            Error::InvalidInput(
                "ContractClient was created without a signer; sends are unavailable".into(),
            )
        })?;

        let overrides = Overrides {
            from: Some(signer.address()),
            value: value.map(to_ethrex_u256),
            ..Default::default()
        };
        let tx = build_generic_tx(
            &self.client,
            TxType::EIP1559,
            to_ethrex_address(to),
            signer.address(),
            call.abi_encode().into(),
            overrides,
        )
        .await?;
        let hash = send_generic_transaction(&self.client, tx, signer).await?;
        Ok(h256_to_b256(hash))
    }

    /// Wait until a transaction is mined and return its receipt.
    pub async fn wait_for_transaction(&self, hash: TxHash) -> Result<TransactionReceipt> {
        let receipt = rex_sdk::wait_for_transaction_receipt(
            crate::convert::b256_to_h256(hash),
            &self.client,
            RECEIPT_MAX_RETRIES,
            true,
        )
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
