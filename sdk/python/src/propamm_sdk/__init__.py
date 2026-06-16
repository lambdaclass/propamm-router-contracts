"""Python SDK for interacting with the PropAMM contracts over JSON-RPC.

Mirrors the TypeScript SDK (``sdk/typescript``) and Rust SDK (``sdk/rust``): a
generic :class:`ContractClient`, typed :class:`PropAmmRouter` bindings (quotes,
swaps, and views), and pAMM state-override sources so quotes price fresh
off-chain liquidity.
"""

from __future__ import annotations

from .client import ContractClient
from .error import (
    AbiError,
    ClientError,
    InvalidInputError,
    MissingEventError,
    OverridesError,
    PropAmmError,
    RevertError,
    TransactionRevertedError,
)
from .overrides import (
    OverridesRpcSource,
    OverridesSnapshot,
    OverridesSource,
    OverridesWsSource,
)
from .router import (
    MAX_FEE_BPS,
    FeeCharged,
    FrontendFee,
    PropAmmRouter,
    Quote,
    QuoteOptions,
    SwapOptions,
    SwapParams,
    SwapResult,
)

__all__ = [
    "MAX_FEE_BPS",
    "AbiError",
    "ClientError",
    "ContractClient",
    "FeeCharged",
    "FrontendFee",
    "InvalidInputError",
    "MissingEventError",
    "OverridesError",
    "OverridesRpcSource",
    "OverridesSnapshot",
    "OverridesSource",
    "OverridesWsSource",
    "PropAmmError",
    "PropAmmRouter",
    "Quote",
    "QuoteOptions",
    "RevertError",
    "SwapOptions",
    "SwapParams",
    "SwapResult",
    "TransactionRevertedError",
]
