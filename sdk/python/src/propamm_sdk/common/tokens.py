"""Well-known token addresses (see src/libraries/Constants.sol)."""

from __future__ import annotations

from eth_typing import ChecksumAddress
from eth_utils import to_checksum_address

#: Sentinel passed as ``token_in`` or ``token_out`` to signal native ETH.
ETH_SENTINEL: ChecksumAddress = to_checksum_address("0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE")

# Mainnet token addresses.
USDC: ChecksumAddress = to_checksum_address("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")
USDT: ChecksumAddress = to_checksum_address("0xdAC17F958D2ee523a2206206994597C13D831ec7")
WETH: ChecksumAddress = to_checksum_address("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")
