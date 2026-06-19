"""Thin wrappers around ``eth_account`` for building signing accounts."""

from __future__ import annotations

from eth_account import Account
from eth_account.signers.local import LocalAccount


def account_from_key(private_key: str) -> LocalAccount:
    """Build a local signing account from a 0x-prefixed (or bare) private key."""
    return Account.from_key(private_key)


def account_from_mnemonic(mnemonic: str, account_path: str = "m/44'/60'/0'/0/0") -> LocalAccount:
    """Build a local signing account from a BIP-39 mnemonic."""
    Account.enable_unaudited_hdwallet_features()
    return Account.from_mnemonic(mnemonic, account_path=account_path)
