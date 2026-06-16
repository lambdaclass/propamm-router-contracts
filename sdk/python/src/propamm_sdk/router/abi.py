"""Router ABI, loaded from the contract's own compiled artifact.

``propamm_router_abi.json`` is ``forge inspect PropAMMRouter abi`` verbatim, so
web3.py handles all encoding/decoding (calldata, return values, events, custom
errors). The only thing web3 can't decode for us is a custom error recovered
from a *raw* ``eth_call`` (the block-override quote path) — :func:`name_error`
covers that, built on ``eth-utils``/``eth-abi`` primitives.
"""

from __future__ import annotations

import json
from functools import lru_cache
from importlib.resources import files

from eth_abi import decode as abi_decode
from eth_utils import function_signature_to_4byte_selector
from eth_utils.abi import collapse_if_tuple

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


def _error_signature(error_abi: dict) -> str:
    types = ",".join(collapse_if_tuple(arg) for arg in error_abi["inputs"])
    return f"{error_abi['name']}({types})"


@lru_cache(maxsize=1)
def _error_table() -> dict[bytes, dict]:
    """selector -> error ABI, for every custom error in ``ROUTER_ABI``."""
    table: dict[bytes, dict] = {}
    for entry in ROUTER_ABI:
        if entry.get("type") == "error":
            signature = _error_signature(entry)
            table[function_signature_to_4byte_selector(signature)] = entry
    return table


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
    name = entry["name"]
    if not entry["inputs"]:
        return f"{name}()"
    types = [collapse_if_tuple(arg) for arg in entry["inputs"]]
    values = abi_decode(types, data[4:])
    return f"{name}({', '.join(str(value) for value in values)})"
