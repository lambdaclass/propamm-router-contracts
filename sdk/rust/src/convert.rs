//! Conversions between alloy primitives (used by the `sol!`-typed ABI
//! surface) and ethrex primitives (used by the rex/ethrex transport).

use alloy_primitives::{Address, B256, U256};
use ethrex_common::{Address as EthrexAddress, H256, U256 as EthrexU256};

pub(crate) fn to_ethrex_address(address: Address) -> EthrexAddress {
    EthrexAddress::from_slice(address.as_slice())
}

pub(crate) fn to_alloy_address(address: EthrexAddress) -> Address {
    Address::from_slice(address.as_bytes())
}

pub(crate) fn to_ethrex_u256(value: U256) -> EthrexU256 {
    EthrexU256::from_big_endian(&value.to_be_bytes::<32>())
}

pub(crate) fn b256_to_h256(value: B256) -> H256 {
    H256::from_slice(value.as_slice())
}

pub(crate) fn h256_to_b256(value: H256) -> B256 {
    B256::from_slice(value.as_bytes())
}

/// A 32-byte storage word reinterpreted as an ethrex `U256` (the type rex's
/// state-override maps carry values in).
pub(crate) fn word_to_ethrex_u256(value: B256) -> EthrexU256 {
    EthrexU256::from_big_endian(value.as_slice())
}
