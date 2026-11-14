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

#: ERC-20 decimals of the tokens Titan's price levels quote (lowercased address
#: -> decimals), read from each token's ``decimals()`` on mainnet. The v2
#: price-level stream sends human-unit amounts, and these turn them back into
#: base units.
TOKEN_DECIMALS: dict[str, int] = {
    "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2": 18,  # WETH
    "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": 6,  # USDC
    "0xdac17f958d2ee523a2206206994597c13d831ec7": 6,  # USDT
    "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599": 8,  # WBTC
    "0xcbb7c0000ab88b473b1f5afd9ef808440eed33bf": 8,  # cbBTC
    "0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9": 18,  # AAVE
    "0x514910771af9ca656af840dff83e8264ecf986ca": 18,  # LINK
    "0x4a220e6096b25eadb88358cb44068a3248254675": 18,  # QNT
    "0xc845b2894dbddd03858fd2d643b4ef725fe0849d": 18,  # NVDAx
}
