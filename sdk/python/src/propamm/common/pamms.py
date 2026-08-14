"""PropAMM venue addresses seeded into the router whitelist at initialization."""

from __future__ import annotations

from eth_typing import ChecksumAddress
from eth_utils import to_checksum_address

FERMI: ChecksumAddress = to_checksum_address("0x5979458912F80B96d30D4220af8E2e4925A33320")
BEBOP: ChecksumAddress = to_checksum_address("0xB09AaA5614916d7AEb59C295C52c92ca82aDdD76")
KIPSELI: ChecksumAddress = to_checksum_address("0x71e790dd841c8A9061487cb3E78C288E75cE0B3d")
TEMPEST: ChecksumAddress = to_checksum_address("0x00000003f1ec2379e79F58E12EC6C4F51Ee92149")
TAURUSFI: ChecksumAddress = to_checksum_address("0x97CC760E40897D6A52c28fAa97593dB88e551223")
METRIC: ChecksumAddress = to_checksum_address("0xE715Dc29d2c273D0FC5A03e5Cca9CcB0Abb1dCDB")

#: Curated propAMM name -> venue address mapping, for the ``venues`` option of
#: quotes and swaps.
#:
#: The Uniswap V3 fallback is intentionally absent: its address is router
#: configuration, read it via ``PropAmmRouter.fallback_swap_router()``.
PAMMS: dict[str, ChecksumAddress] = {
    "fermi": FERMI,
    "bebop": BEBOP,
    "kipseli": KIPSELI,
    "tempest": TEMPEST,
    "taurusfi": TAURUSFI,
    "metric": METRIC,
}
