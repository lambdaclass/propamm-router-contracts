use thiserror::Error;

#[derive(Debug, Error)]
pub enum Error {
    /// JSON-RPC client failure (transport, node errors, tx building/sending).
    #[error("rpc client error: {0}")]
    Client(#[from] ethrex_rpc::clients::EthClientError),

    /// An `eth_call` reverted. `data` carries the raw revert payload when the
    /// node provided one (the router bindings decode it into named errors).
    #[error("call reverted: {message}")]
    Revert {
        message: String,
        data: Option<Vec<u8>>,
    },

    /// ABI encoding/decoding failure.
    #[error("abi error: {0}")]
    Abi(String),

    /// Failure while fetching or parsing pAMM state overrides.
    #[error("overrides error: {0}")]
    Overrides(String),

    /// An operation did not complete within its deadline.
    #[error("timeout: {0}")]
    Timeout(String),

    /// Invalid caller-supplied input (addresses, fee bounds, keys, URLs, ...).
    #[error("invalid input: {0}")]
    InvalidInput(String),

    /// Anything else.
    #[error("{0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, Error>;
