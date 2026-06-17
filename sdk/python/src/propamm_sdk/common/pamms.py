"""PropAMM venue addresses seeded into the router whitelist at initialization."""

from __future__ import annotations

from eth_typing import ChecksumAddress
from eth_utils import to_checksum_address

FERMI: ChecksumAddress = to_checksum_address("0x5979458912F80B96d30D4220af8E2e4925A33320")
BEBOP: ChecksumAddress = to_checksum_address("0xdB13ad0fcD134E9c48f2fDaEa8f6751a0F5349ca")
KIPSELI: ChecksumAddress = to_checksum_address("0x71e790dd841c8A9061487cb3E78C288E75cE0B3d")

#: Curated propAMM name -> venue address mapping, for the ``venues`` option of
#: quotes and swaps.
#:
#: The Uniswap V3 fallback is intentionally absent: its address is router
#: configuration, read it via ``PropAmmRouter.fallback_swap_router()``.
PAMMS: dict[str, ChecksumAddress] = {
    "fermi": FERMI,
    "bebop": BEBOP,
    "kipseli": KIPSELI,
}
