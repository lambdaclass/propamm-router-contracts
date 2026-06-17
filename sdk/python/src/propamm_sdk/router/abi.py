"""Router ABI, loaded from the contract's own compiled artifact.

``propamm_router_abi.json`` is ``forge inspect PropAMMRouter abi`` verbatim, so
web3.py handles the encoding/decoding for us — calldata, return values, and
events. The one thing it doesn't do is name a custom error: a reverted call
surfaces only the raw 4-byte selector (web3 never maps it back to a signature,
in any path). :func:`name_error` covers that, decoding the selector against the
ABI's error entries — built on ``web3.utils`` helpers plus ``eth-abi``.
"""

from __future__ import annotations

import json
from functools import lru_cache
from importlib.resources import files

from eth_abi import decode as abi_decode
from web3.utils import (
    filter_abi_by_type,
    function_abi_to_4byte_selector,
    get_abi_input_types,
)

#: The router's full ABI (the compiled contract's own ABI).
ROUTER_ABI = json.loads((files(__package__) / "propamm_router_abi.json").read_text())

#: Minimal ERC-20 ABI for router approvals (not part of the router's ABI).
ERC20_ABI = [
    {
        "type": "function",
        "name": "approve",
        "stateMutability": "nonpayable",
        "inputs": [
            {"name": "spender", "type": "address"},
            {"name": "amount", "type": "uint256"},
        ],
        "outputs": [{"name": "", "type": "bool"}],
    },
    {
        "type": "function",
        "name": "allowance",
        "stateMutability": "view",
        "inputs": [
            {"name": "owner", "type": "address"},
            {"name": "spender", "type": "address"},
        ],
        "outputs": [{"name": "", "type": "uint256"}],
    },
]


@lru_cache(maxsize=1)
def _error_table() -> dict[bytes, dict]:
    """selector -> error ABI, for every custom error in ``ROUTER_ABI``."""
    return {
        function_abi_to_4byte_selector(entry): entry
        for entry in filter_abi_by_type("error", ROUTER_ABI)
    }


def name_error(data: bytes) -> str | None:
    """Name a raw revert payload against the router's custom errors.

    E.g. ``InsufficientOutput(1000, 900)``. ``None`` when the selector is
    unknown or the payload is too short.
    """
    data = bytes(data)
    if len(data) < 4:
        return None
    entry = _error_table().get(data[:4])
    if entry is None:
        return None
    types = get_abi_input_types(entry)
    if not types:
        return f"{entry['name']}()"
    values = abi_decode(types, data[4:])
    return f"{entry['name']}({', '.join(str(value) for value in values)})"
