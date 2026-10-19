"""PropAMM venue addresses listed on the router whitelist via ``addVenue``."""

from __future__ import annotations

from eth_typing import ChecksumAddress
from eth_utils import to_checksum_address

FERMI: ChecksumAddress = to_checksum_address("0x5979458912F80B96d30D4220af8E2e4925A33320")
BEBOP: ChecksumAddress = to_checksum_address("0xB09AAA8933626d7E4C48D65dAd2D77021CFBCA9a")
KIPSELI: ChecksumAddress = to_checksum_address("0x71e790dd841c8A9061487cb3E78C288E75cE0B3d")
TEMPEST: ChecksumAddress = to_checksum_address("0x00000003f1ec2379e79F58E12EC6C4F51Ee92149")
TAURUSFI: ChecksumAddress = to_checksum_address("0x20861433D9119B866EEB398cb1ad46652A3cF953")
METRIC: ChecksumAddress = to_checksum_address("0x99Ab7c1C5eab47801F7937075998527a550fbA8a")
EL_ZORRO: ChecksumAddress = to_checksum_address("0xCF211B4dD0D2be5C173Ea57Bcf938FC61d1d3bd3")
STELAXIS: ChecksumAddress = to_checksum_address("0x77047Af6CD8f7f84d96A020a2833d24916b75FDE")
GOLIATH: ChecksumAddress = to_checksum_address("0x4367985A63063fc970b009c6E599e9225181f551")

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
    "goliath": GOLIATH,
}

#: Titan publishes each maker's data under the maker's quote address, which for
#: some makers is not the venue address the router whitelists. This maps those
#: quote addresses (lowercased) to the router venue; makers absent here publish
#: under the venue address itself. Source: the stream-address table in Titan's
#: takers docs.
QUOTE_ADDRESS_VENUES: dict[str, ChecksumAddress] = {
    # Kipseli
    "0xc9a956b5196dfe110debe8781857bc8b97d32091": KIPSELI,
    # Metric publishes under two quote addresses; its venue needs both.
    "0xe844701934d9c6085b292e428f41b911cc0b3872": METRIC,
    "0x30a88bf894d1b806125a23ebf23d715496fd7102": METRIC,
}
