use thiserror::Error;

#[derive(Debug, Error)]
pub enum Error {
    /// JSON-RPC transport failure (connection, serialization, node errors).
    #[error("transport error: {0}")]
    Transport(#[from] alloy::transports::TransportError),

    /// Contract interaction failure (revert, ABI decoding, ...).
    #[error("contract error: {0}")]
    Contract(#[from] alloy::contract::Error),

    /// Failure while fetching or parsing pAMM state overrides.
    #[error("overrides error: {0}")]
    Overrides(String),

    /// An operation did not complete within its deadline.
    #[error("timeout: {0}")]
    Timeout(String),

    /// Invalid caller-supplied input (addresses, fee bounds, ...).
    #[error("invalid input: {0}")]
    InvalidInput(String),

    /// Anything else (signer parsing, URL parsing, decoding, ...).
    #[error("{0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, Error>;
