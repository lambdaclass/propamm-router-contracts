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
pub mod router;

pub use client::{CallOverrides, ContractClient};
pub use error::{Error, Result};
pub use router::PropAmmRouter;

// Core primitive types, re-exported so basic usage needs no direct alloy import.
pub use alloy::primitives::{Address, B256, TxHash, U256};
