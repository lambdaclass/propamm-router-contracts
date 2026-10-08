"""PropAMM venue addresses listed on the router whitelist via ``addVenue``."""

from __future__ import annotations

from eth_typing import ChecksumAddress
from eth_utils import to_checksum_address

FERMI: ChecksumAddress = to_checksum_address("0x5979458912F80B96d30D4220af8E2e4925A33320")
BEBOP: ChecksumAddress = to_checksum_address("0xB09AAA8933626d7E4C48D65dAd2D77021CFBCA9a")
KIPSELI: ChecksumAddress = to_checksum_address("0x71e790dd841c8A9061487cb3E78C288E75cE0B3d")
TEMPEST: ChecksumAddress = to_checksum_address("0x00000003f1ec2379e79F58E12EC6C4F51Ee92149")
TAURUSFI: ChecksumAddress = to_checksum_address("0x3ce2672Aa806138585920421406Bf0dEcB8130Cb")
METRIC: ChecksumAddress = to_checksum_address("0xE715Dc29d2c273D0FC5A03e5Cca9CcB0Abb1dCDB")
EL_ZORRO: ChecksumAddress = to_checksum_address("0xCF211B4dD0D2be5C173Ea57Bcf938FC61d1d3bd3")
STELAXIS: ChecksumAddress = to_checksum_address("0x77047Af6CD8f7f84d96A020a2833d24916b75FDE")

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
    "elzorro": EL_ZORRO,
    "stelaxis": STELAXIS,
}
