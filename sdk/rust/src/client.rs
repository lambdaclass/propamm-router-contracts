//! Thin wrapper around an alloy provider for reading from and writing to
//! contracts, including `eth_call` simulations with state and block
//! overrides (which typed contract calls don't carry).

use std::time::Duration;

use alloy::{
    network::{EthereumWallet, TransactionBuilder},
    primitives::{Address, Bytes, TxHash, U256},
    providers::{DynProvider, Provider, ProviderBuilder},
    rpc::types::{BlockOverrides, TransactionReceipt, TransactionRequest, state::StateOverride},
    signers::local::PrivateKeySigner,
    sol_types::SolCall,
};

use crate::error::{Error, Result};

const RECEIPT_POLL_INTERVAL: Duration = Duration::from_secs(1);
const RECEIPT_TIMEOUT: Duration = Duration::from_secs(120);

/// Optional context for `eth_call` simulations.
#[derive(Debug, Clone, Default)]
pub struct CallOverrides {
    /// State overrides applied to the call (third RPC parameter).
    pub state: Option<StateOverride>,
    /// Pin the simulated `block.number` (block override, fourth RPC parameter).
    pub block_number: Option<u64>,
    /// Pin the simulated `block.timestamp`, in seconds (block override).
    pub block_timestamp: Option<u64>,
}

impl CallOverrides {
    fn is_empty(&self) -> bool {
        self.state.is_none() && self.block_number.is_none() && self.block_timestamp.is_none()
    }
}

/// JSON-RPC contract client. Construct read-only with [`ContractClient::connect`]
/// or signing with [`ContractClient::connect_with_signer`].
#[derive(Debug, Clone)]
pub struct ContractClient {
    provider: DynProvider,
    signer_address: Option<Address>,
}

impl ContractClient {
    /// Read-only client (quotes and views work; sends don't).
    pub fn connect(rpc_url: &str) -> Result<Self> {
        let url = rpc_url
            .parse()
            .map_err(|e| Error::Other(format!("invalid RPC url: {e}")))?;
        let provider = ProviderBuilder::new().connect_http(url).erased();
        Ok(Self {
            provider,
            signer_address: None,
        })
    }

    /// Signing client from a 0x-prefixed private key.
    pub fn connect_with_signer(rpc_url: &str, private_key: &str) -> Result<Self> {
        let signer: PrivateKeySigner = private_key
            .parse()
            .map_err(|e| Error::Other(format!("invalid private key: {e}")))?;
        let signer_address = signer.address();
        let url = rpc_url
            .parse()
            .map_err(|e| Error::Other(format!("invalid RPC url: {e}")))?;
        let provider = ProviderBuilder::new()
            .wallet(EthereumWallet::from(signer))
            .connect_http(url)
            .erased();
        Ok(Self {
            provider,
            signer_address: Some(signer_address),
        })
    }

    /// The underlying type-erased provider, for anything not wrapped here.
    pub fn provider(&self) -> &DynProvider {
        &self.provider
    }

    /// Address of the configured signer, if any.
    pub fn signer_address(&self) -> Option<Address> {
        self.signer_address
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
        let tx = TransactionRequest::default()
            .with_to(to)
            .with_input(Bytes::from(call.abi_encode()));

        let data: Bytes = if overrides.is_empty() {
            self.provider.call(tx).await?
        } else {
            let block_overrides = (overrides.block_number.is_some()
                || overrides.block_timestamp.is_some())
            .then(|| BlockOverrides {
                number: overrides.block_number.map(U256::from),
                time: overrides.block_timestamp,
                ..Default::default()
            });

            // The raw 4-positional-parameter form: call object, block tag,
            // state overrides, block overrides.
            self.provider
                .client()
                .request(
                    "eth_call",
                    (
                        tx,
                        "latest",
                        overrides.state.clone().unwrap_or_default(),
                        block_overrides.unwrap_or_default(),
                    ),
                )
                .await?
        };

        C::abi_decode_returns(&data)
            .map_err(|e| Error::Other(format!("failed to decode {} return: {e}", C::SIGNATURE)))
    }

    /// Wait until a transaction is mined and return its receipt.
    pub async fn wait_for_transaction(&self, hash: TxHash) -> Result<TransactionReceipt> {
        let deadline = tokio::time::Instant::now() + RECEIPT_TIMEOUT;
        loop {
            if let Some(receipt) = self.provider.get_transaction_receipt(hash).await? {
                return Ok(receipt);
            }
            if tokio::time::Instant::now() >= deadline {
                return Err(Error::Timeout(format!(
                    "transaction {hash} not mined within {RECEIPT_TIMEOUT:?}"
                )));
            }
            tokio::time::sleep(RECEIPT_POLL_INTERVAL).await;
        }
    }
}
