//! Rust SDK for interacting with the PropAMM contracts over JSON-RPC.
//!
//! Mirrors the TypeScript SDK (`sdk/typescript`): a generic
//! [`ContractClient`], typed [`PropAmmRouter`] bindings (quotes, swaps, and
//! views), and pAMM state-override sources so quotes price fresh off-chain
//! liquidity.

pub mod client;
pub mod common;
pub mod error;
pub mod overrides;
pub mod prices;
pub mod router;
pub(crate) mod ws;

pub use client::{CallOverrides, ContractClient};
pub use error::{Error, Result};
pub use prices::PriceLevels;
pub use router::PropAmmRouter;

// Core primitive types, re-exported from ethrex.
pub use ethrex_common::{Address, H256, U256};
/// Transaction hash.
pub type TxHash = H256;
