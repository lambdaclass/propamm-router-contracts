"""Python SDK for interacting with the PropAMM contracts over JSON-RPC.

Provides a generic :class:`ContractClient`, typed :class:`PropAmmRouter`
bindings (quotes, swaps, and views), and pAMM state-override sources so quotes
price fresh off-chain liquidity.
"""

from __future__ import annotations

from .client import ContractClient
from .error import (
    ClientError,
    InvalidInputError,
    MissingEventError,
    OverridesError,
    PropAmmError,
    RevertError,
    TimeoutError,
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
    "TimeoutError",
    "TransactionRevertedError",
]
