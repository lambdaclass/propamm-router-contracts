"""pAMM state-override sources.

The proprietary AMMs price off-chain liquidity that mainnet state does not
reflect, so plain ``eth_call`` quotes see stale prices. Titan publishes fresh
state overrides through a WebSocket stream and a JSON-RPC method; the sources
here consume either one and produce snapshots that the router's quote calls
attach to ``eth_call`` (third parameter, plus a block-number/timestamp override
so venues that check block context don't revert).

Both payloads share one shape — top-level metadata plus one entry per pAMM::

    {
      "blockNumber": 24285034,
      "0x<pamm>": {"stateOverride": {"0x<contract>": {"stateDiff": {"0x<slot>": "0x<value>"}}}}
    }
"""

from __future__ import annotations

import abc
import asyncio
import copy
import json
import ssl
from dataclasses import dataclass, field
from functools import lru_cache
from typing import Any

import aiohttp
import certifi
import websockets

from ..common.pamms import BEBOP
from ..error import OverridesError, TimeoutError

DEFAULT_OVERRIDES_RPC_URL = "https://rpc.titanbuilder.xyz"
DEFAULT_OVERRIDES_WS_URL = "wss://rpc.titanbuilder.xyz/ws/pamm_quote_stream"


@lru_cache(maxsize=1)
def _ssl_context() -> ssl.SSLContext:
    """TLS context backed by certifi's CA bundle.

    Avoids relying on the system cert store, which is empty on some Python
    builds (e.g. python.org installers on macOS) and would otherwise make every
    secure connection fail to verify.
    """
    return ssl.create_default_context(cafile=certifi.where())

#: Bebop prices from a single registry slot. When a snapshot carries no Bebop
#: entry, :func:`to_state_override` zeroes this slot by default so a stale
#: on-chain Bebop price cannot win a best-quote selection it could never fill.
BEBOP_DEFAULT_SLOT = "0x3ca381a3d43d4e593578057c4abe441ad9df02f080defd17d2b6e6190cdcd936"

_BEBOP_LOWER = BEBOP.lower()
_META_KEYS = {"slot", "blockNumber", "block_number", "timestamp"}

# Storage slot diffs for one contract: slot -> value (both ints).
SlotDiffs = dict[int, int]
# Per-contract slot diffs: contract address (lowercased) -> slots.
ContractDiffs = dict[str, SlotDiffs]


@dataclass
class OverridesSnapshot:
    """A parsed overrides payload: per-pAMM contract diffs plus block context."""

    #: Block the overrides were generated against.
    block_number: int | None = None
    #: Generation time in nanoseconds since epoch.
    timestamp_ns: int | None = None
    #: pAMM address (lowercased) -> contract address (lowercased) -> slot diffs.
    per_pamm: dict[str, ContractDiffs] = field(default_factory=dict)

    def copy(self) -> OverridesSnapshot:
        """A deep-ish copy so a later frame can't mutate a handed-out snapshot."""
        return OverridesSnapshot(
            block_number=self.block_number,
            timestamp_ns=self.timestamp_ns,
            per_pamm={
                pamm: {contract: dict(slots) for contract, slots in contracts.items()}
                for pamm, contracts in self.per_pamm.items()
            },
        )


def _parse_word(value: str) -> int | None:
    if not isinstance(value, str) or not value.startswith("0x"):
        return None
    try:
        return int(value[2:], 16)
    except ValueError:
        return None


def _parse_block_number(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value:
        if value.startswith("0x"):
            try:
                return int(value[2:], 16)
            except ValueError:
                return None
        try:
            return int(value)
        except ValueError:
            return None
    return None


def _parse_contract_diffs(payload: Any) -> ContractDiffs | None:
    if not isinstance(payload, dict):
        return None
    override_map = payload.get("stateOverride") or payload.get("state_override")
    if not isinstance(override_map, dict):
        return None

    contracts: ContractDiffs = {}
    for address, spec in override_map.items():
        state_diff = spec.get("stateDiff") if isinstance(spec, dict) else None
        if not isinstance(state_diff, dict):
            continue
        slots: SlotDiffs = {}
        for slot, value in state_diff.items():
            parsed_slot = _parse_word(slot)
            parsed_value = _parse_word(value) if isinstance(value, str) else None
            if parsed_slot is None or parsed_value is None:
                continue
            slots[parsed_slot] = parsed_value
        if slots:
            contracts[address.lower()] = slots
    return contracts or None


def parse_overrides_message(raw: Any) -> OverridesSnapshot:
    """Parse a raw overrides payload (a WS frame or the JSON-RPC ``result``).

    Metadata keys are split out, addresses and slots are lowercased, and
    pAMMs/contracts with empty ``stateDiff``s are dropped.
    """
    if not isinstance(raw, dict):
        raise OverridesError("overrides message is not a JSON object")

    per_pamm: dict[str, ContractDiffs] = {}
    for key, payload in raw.items():
        if key in _META_KEYS or not key.startswith("0x"):
            continue
        contracts = _parse_contract_diffs(payload)
        if contracts:
            per_pamm[key.lower()] = contracts

    return OverridesSnapshot(
        block_number=_parse_block_number(raw.get("blockNumber", raw.get("block_number"))),
        timestamp_ns=raw["timestamp"] if isinstance(raw.get("timestamp"), int) else None,
        per_pamm=per_pamm,
    )


def _word(value: int) -> str:
    return "0x" + format(value, "064x")


def to_state_override(
    snapshot: OverridesSnapshot,
    *,
    pamms: list[str] | None = None,
    bebop_default: bool = True,
) -> dict[str, dict[str, dict[str, str]]]:
    """Merge a snapshot's per-pAMM diffs into the ``eth_call`` state-override map.

    Diffs are merged at slot level when multiple pAMM entries touch the same
    contract. Returns ``{address: {"stateDiff": {slot: value}}}`` with 32-byte
    hex words, ready for the ``eth_call`` third parameter.
    """
    selected = {pamm.lower() for pamm in pamms} if pamms is not None else None

    merged: dict[str, SlotDiffs] = {}
    has_bebop = False
    for pamm, contracts in snapshot.per_pamm.items():
        if selected is not None and pamm not in selected:
            continue
        if pamm == _BEBOP_LOWER:
            has_bebop = True
        for address, slots in contracts.items():
            merged.setdefault(address, {}).update(slots)

    if bebop_default and not has_bebop:
        merged.setdefault(_BEBOP_LOWER, {})[int(BEBOP_DEFAULT_SLOT, 16)] = 0

    from eth_utils import to_checksum_address

    return {
        to_checksum_address(address): {
            "stateDiff": {_word(slot): _word(value) for slot, value in slots.items()}
        }
        for address, slots in merged.items()
    }


class OverridesSource(abc.ABC):
    """Anything quotes can pull override snapshots from."""

    @abc.abstractmethod
    async def get_overrides(self) -> OverridesSnapshot | None:
        ...

    async def close(self) -> None:
        """Immediate, permanent teardown. Default: no-op."""


class OverridesRpcSource(OverridesSource):
    """Fetch-on-demand source: one ``titan_getPammStateOverrides`` call per fetch."""

    def __init__(self, url: str = DEFAULT_OVERRIDES_RPC_URL) -> None:
        self.url = url

    async def get_overrides(self) -> OverridesSnapshot:
        request = {"jsonrpc": "2.0", "id": 1, "method": "titan_getPammStateOverrides", "params": []}
        ssl_ctx = _ssl_context() if self.url.startswith("https") else None
        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(self.url, json=request, ssl=ssl_ctx) as response:
                    if response.status != 200:
                        raise OverridesError(
                            f"overrides RPC request failed with status {response.status}"
                        )
                    body = await response.json()
        except aiohttp.ClientError as exc:
            raise OverridesError(f"overrides RPC request failed: {exc}") from exc
        return _parse_rpc_response(body)


def _parse_rpc_response(body: Any) -> OverridesSnapshot:
    """Parse a ``titan_getPammStateOverrides`` response body into a snapshot.

    A present-but-null ``"error"`` is treated as success: many JSON-RPC servers
    send ``{"result": {...}, "error": null}``, and the field's mere presence
    must not be read as a failure.
    """
    if not isinstance(body, dict):
        raise OverridesError("overrides RPC response is not a JSON object")
    error = body.get("error")
    if error is not None:
        raise OverridesError(f"overrides RPC error: {error}")
    result = body.get("result")
    if result is None:
        raise OverridesError("overrides RPC response had neither a result nor an error")
    return parse_overrides_message(result)


_RECONNECT_INITIAL = 1.0
_RECONNECT_MAX = 30.0


class OverridesWsSource(OverridesSource):
    """Streaming source: connects lazily on the first ``get_overrides`` call.

    Accumulates per-pAMM entries across frames (a frame only carries the pAMMs
    it updates), reconnecting with exponential backoff. The connection is
    dropped after ``idle_timeout`` without calls and re-established on demand,
    so no explicit teardown is needed; :meth:`close` tears down immediately and
    permanently.
    """

    def __init__(
        self,
        url: str = DEFAULT_OVERRIDES_WS_URL,
        *,
        first_frame_timeout: float = 5.0,
        idle_timeout: float = 30.0,
    ) -> None:
        self.url = url
        self.first_frame_timeout = first_frame_timeout
        self.idle_timeout = idle_timeout

        self._snapshot = OverridesSnapshot()
        self._has_frame = False
        self._closed = False
        self._last_use = 0.0
        self._task: asyncio.Task | None = None
        self._frame_event = asyncio.Event()
        self._lock = asyncio.Lock()

    async def get_overrides(self) -> OverridesSnapshot:
        async with self._lock:
            if self._closed:
                raise OverridesError("overrides source is closed")
            self._last_use = asyncio.get_event_loop().time()
            if self._task is None or self._task.done():
                self._frame_event.clear()
                self._task = asyncio.ensure_future(self._run())
            if self._has_frame:
                return self._snapshot.copy()

        try:
            await asyncio.wait_for(self._frame_event.wait(), self.first_frame_timeout)
        except asyncio.TimeoutError as exc:
            raise TimeoutError(
                f"no overrides frame received within {self.first_frame_timeout}s"
            ) from exc

        async with self._lock:
            if self._closed:
                raise OverridesError("overrides source is closed")
            return self._snapshot.copy()

    async def close(self) -> None:
        async with self._lock:
            self._closed = True
            task = self._task
            self._task = None
            self._frame_event.set()
        if task is not None:
            task.cancel()

    async def _run(self) -> None:
        """Background read loop: connect, merge frames, exit when idle."""
        backoff = _RECONNECT_INITIAL
        ssl_ctx = _ssl_context() if self.url.startswith("wss") else None
        while not self._closed:
            try:
                async with websockets.connect(self.url, ssl=ssl_ctx) as ws:
                    backoff = _RECONNECT_INITIAL
                    while not self._closed:
                        idle_remaining = self._idle_remaining()
                        if idle_remaining <= 0:
                            self._has_frame = False
                            return
                        try:
                            message = await asyncio.wait_for(ws.recv(), idle_remaining)
                        except asyncio.TimeoutError:
                            continue
                        self._handle_frame(message)
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001 - reconnect on any transport error
                pass

            if self._closed or self._idle_remaining() <= 0:
                self._has_frame = False
                return
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, _RECONNECT_MAX)

    def _idle_remaining(self) -> float:
        elapsed = asyncio.get_event_loop().time() - self._last_use
        return self.idle_timeout - elapsed

    def _handle_frame(self, data: Any) -> None:
        if not isinstance(data, (str, bytes, bytearray)):
            return
        try:
            frame = parse_overrides_message(json.loads(data))
        except (json.JSONDecodeError, OverridesError):
            return  # skip undecodable frames, like the reference consumers do

        # A frame only carries the pAMMs it updates; entries for other pAMMs
        # stay cached from earlier frames.
        self._snapshot.per_pamm.update(copy.deepcopy(frame.per_pamm))
        if frame.block_number is not None:
            self._snapshot.block_number = frame.block_number
        if frame.timestamp_ns is not None:
            self._snapshot.timestamp_ns = frame.timestamp_ns
        self._has_frame = True
        self._frame_event.set()
