"""Hand-rolled ABI surface for ``PropAMMRouter`` (src/PropAMMRouter.sol).

Mirrors the Rust SDK's ``abi.rs``: canonical function-signature strings (the
selector source — verify against ``forge inspect PropAMMRouter
methodIdentifiers``), tuple decoding for return data / event data / error
args, event topics, and a custom-error table.

Self-call-only internals (``_dispatchVenue``, ``_dispatchQuoteVenue``) and
UUPS plumbing are intentionally omitted.
"""

from __future__ import annotations

from eth_abi import decode as abi_decode
from eth_abi import encode as abi_encode
from eth_utils import keccak, to_checksum_address

from ..error import AbiError

# --- Swaps. Struct params (`FrontendFee`) appear as tuples. ---
SWAP = "swapV1(address,address,uint256,uint256,address,uint256)"
SWAP_WITH_FEE = "swapWithFeeV1(address,address,uint256,uint256,address,uint256,(uint16,address))"
SWAP_VIA_VENUE = "swapViaVenueV1(address,address,address,uint256,uint256,address,uint256)"
SWAP_VIA_VENUE_WITH_FEE = (
    "swapViaVenueWithFeeV1(address,address,address,uint256,uint256,address,uint256,(uint16,address))"
)
SWAP_VIA_SELECTED_VENUES = (
    "swapViaSelectedVenuesV1(address[],address,address,uint256,uint256,address,uint256)"
)
SWAP_VIA_SELECTED_VENUES_WITH_FEE = (
    "swapViaSelectedVenuesWithFeeV1"
    "(address[],address,address,uint256,uint256,address,uint256,(uint16,address))"
)

# --- Quotes — nonpayable (not view) on-chain; call off-chain via simulation. ---
QUOTE = "quoteV1(address,address,uint256)"
QUOTE_VENUE = "quoteVenueV1(address,address,address,uint256)"
QUOTE_SELECTED_VENUES = "quoteSelectedVenuesV1(address[],address,address,uint256)"
QUOTE_UNISWAP_V3 = "quoteUniswapV3(address,address,uint256)"

# --- Views ---
FALLBACK_SWAP_ROUTER = "fallbackSwapRouter()"
FALLBACK_QUOTER = "fallbackQuoter()"
FALLBACK_FEE = "fallbackFee()"
GET_PAIR_FEE = "getPairFee(address,address)"
RESOLVED_FEE = "resolvedFee(address,address)"
IS_WHITELISTED_VENUE = "isWhitelistedVenue(address)"
GET_WHITELISTED_VENUES = "getWhitelistedVenues()"
WHITELISTED_VENUE_COUNT = "whitelistedVenueCount()"
WHITELISTED_VENUE_AT = "whitelistedVenueAt(uint256)"
PAUSED = "paused()"
AUTHORITY = "authority()"

# --- Administration (access-controlled via the AccessManager authority).
# No typed bindings — encode with these and send through `ContractClient.send`. ---
SET_FALLBACK_SWAP_ROUTER = "setFallbackSwapRouter(address)"
SET_FALLBACK_QUOTER = "setFallbackQuoter(address)"
SET_FALLBACK_FEE = "setFallbackFee(uint24)"
SET_PAIR_FEE = "setPairFee(address,address,uint24)"
SET_PAIR_FEES = "setPairFees(address[],address[],uint24[])"
ADD_VENUE = "addVenue(address)"
REMOVE_VENUE = "removeVenue(address)"
PAUSE = "pause()"
UNPAUSE = "unpause()"
RESCUE_TOKENS = "rescueTokens(address,address,uint256)"

# --- ERC-20 (for router approvals) ---
ERC20_APPROVE = "approve(address,uint256)"
ERC20_ALLOWANCE = "allowance(address,address)"

# --- Events ---
SWAPPED_EVENT = "Swapped(address,address,address,uint256,uint256,address,address)"
FRONTEND_FEE_CHARGED_EVENT = "FrontendFeeCharged(address,address,uint256,address)"
FALLBACK_FEE_UPDATED_EVENT = "FallbackFeeUpdated(uint24,uint24)"
FALLBACK_SWAP_ROUTER_UPDATED_EVENT = "FallbackSwapRouterUpdated(address,address)"
FALLBACK_QUOTER_UPDATED_EVENT = "FallbackQuoterUpdated(address,address)"
PAIR_FEE_UPDATED_EVENT = "PairFeeUpdated(address,address,uint24,uint24)"
TOKENS_RESCUED_EVENT = "TokensRescued(address,address,uint256)"
VENUE_WHITELISTED_EVENT = "VenueWhitelisted(address)"
VENUE_REMOVED_EVENT = "VenueRemoved(address)"

#: Every router function the SDK binds (the ERC-20 helpers are not part of the
#: router's ABI). Keep in sync when adding signature constants.
FUNCTIONS = [
    SWAP,
    SWAP_WITH_FEE,
    SWAP_VIA_VENUE,
    SWAP_VIA_VENUE_WITH_FEE,
    SWAP_VIA_SELECTED_VENUES,
    SWAP_VIA_SELECTED_VENUES_WITH_FEE,
    QUOTE,
    QUOTE_VENUE,
    QUOTE_SELECTED_VENUES,
    QUOTE_UNISWAP_V3,
    FALLBACK_SWAP_ROUTER,
    FALLBACK_QUOTER,
    FALLBACK_FEE,
    GET_PAIR_FEE,
    RESOLVED_FEE,
    IS_WHITELISTED_VENUE,
    GET_WHITELISTED_VENUES,
    WHITELISTED_VENUE_COUNT,
    WHITELISTED_VENUE_AT,
    PAUSED,
    AUTHORITY,
    SET_FALLBACK_SWAP_ROUTER,
    SET_FALLBACK_QUOTER,
    SET_FALLBACK_FEE,
    SET_PAIR_FEE,
    SET_PAIR_FEES,
    ADD_VENUE,
    REMOVE_VENUE,
    PAUSE,
    UNPAUSE,
    RESCUE_TOKENS,
]

#: Every router event the SDK knows.
EVENTS = [
    SWAPPED_EVENT,
    FRONTEND_FEE_CHARGED_EVENT,
    FALLBACK_FEE_UPDATED_EVENT,
    FALLBACK_SWAP_ROUTER_UPDATED_EVENT,
    FALLBACK_QUOTER_UPDATED_EVENT,
    PAIR_FEE_UPDATED_EVENT,
    TOKENS_RESCUED_EVENT,
    VENUE_WHITELISTED_EVENT,
    VENUE_REMOVED_EVENT,
]

#: Custom errors, for naming revert payloads. Mirrors src/libraries/Errors.sol
#: plus OpenZeppelin's ``EnforcedPause`` (what swaps revert with while paused).
ERROR_SIGNATURES = [
    "OnlySelf()",
    "UnknownVenue()",
    "InsufficientOutput(uint256,uint256)",
    "Expired()",
    "NoQuotesAvailable()",
    "TokenOutBalanceDecreased()",
    "InvalidFallbackFee(uint24)",
    "ZeroAddress()",
    "ArrayLengthMismatch()",
    "VenueAlreadyWhitelisted(address)",
    "VenueNotWhitelisted(address)",
    "InvalidValue(uint256,uint256)",
    "ETHTransferFailed()",
    "UnexpectedETHSender()",
    "IdenticalTokens()",
    "FeeBpsTooHigh(uint16,uint16)",
    "EnforcedPause()",
]


def _arg_string(signature: str) -> str:
    """The comma-separated arg-type list inside a signature's outer parens."""
    return signature[signature.index("(") + 1 : signature.rindex(")")]


def split_types(types: str) -> list[str]:
    """Split a top-level comma list, respecting nested tuple parens.

    ``"address[],(uint16,address)"`` -> ``["address[]", "(uint16,address)"]``.
    """
    parts: list[str] = []
    depth = 0
    current = ""
    for char in types:
        if char == "," and depth == 0:
            parts.append(current.strip())
            current = ""
            continue
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        current += char
    if current.strip():
        parts.append(current.strip())
    return parts


def selector(signature: str) -> bytes:
    """4-byte selector of a canonical function/error signature."""
    return keccak(text=signature)[:4]


def event_topic(signature: str) -> bytes:
    """keccak topic0 of an event signature."""
    return keccak(text=signature)


def encode_calldata(signature: str, values: list) -> bytes:
    """ABI-encode a call: 4-byte selector + encoded args."""
    types = split_types(_arg_string(signature))
    try:
        return selector(signature) + abi_encode(types, values)
    except Exception as exc:  # noqa: BLE001 - normalize codec failures
        raise AbiError(f"failed to encode {signature}: {exc}") from exc


def decode_values(types: str, data: bytes) -> list:
    """Decode ABI-encoded return/event/error data against a type list.

    ``decode_values("uint256,address", data)``. Addresses come back as
    checksum strings.
    """
    type_list = split_types(types)
    try:
        decoded = list(abi_decode(type_list, bytes(data)))
    except Exception as exc:  # noqa: BLE001 - normalize codec failures
        raise AbiError(f"failed to decode ({types}): {exc}") from exc
    return [_normalize(value, type_name) for value, type_name in zip(decoded, type_list)]


def _normalize(value, type_name: str):
    """Checksum addresses (eth_abi yields lowercase) for stable comparison."""
    if type_name == "address":
        return to_checksum_address(value)
    if type_name == "address[]":
        return [to_checksum_address(item) for item in value]
    return value


def topic_as_address(topic: bytes) -> str:
    """An indexed event argument (a full 32-byte topic) read as an address."""
    return to_checksum_address(bytes(topic)[12:])


def decode_error(data: bytes) -> str | None:
    """Name a revert payload against the router's known custom errors.

    E.g. ``InsufficientOutput(1000, 900)``. ``None`` when the selector is
    unknown or the payload is too short.
    """
    data = bytes(data)
    if len(data) < 4:
        return None
    match = next((sig for sig in ERROR_SIGNATURES if selector(sig) == data[:4]), None)
    if match is None:
        return None

    name = match[: match.index("(")]
    types = _arg_string(match)
    if not types:
        return f"{name}()"
    values = decode_values(types, data[4:])
    rendered = ", ".join(_format_value(value) for value in values)
    return f"{name}({rendered})"


def _format_value(value) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)
