"""pAMM price-level sources.

Alongside the raw state overrides (see :mod:`propamm.overrides`), Titan
publishes prices it has *already quoted*, grouped per pAMM: for each trading
pair an ``order_book`` of rungs mapping an input amount to the output it would
receive. This lets a taker read prices across a range of trade sizes without
running an ``eth_call`` simulation per size. Rungs come in two flavours —
``Simulated`` (derived from an EVM simulation of a synthesized taker tx) and
``Interpolated`` (a linear spline between simulated rungs, for finer
granularity).

Titan exposes this through a WebSocket stream and three JSON-RPC methods:

- ``titan_getPammPriceLevels`` — the full per-pAMM snapshot (also streamed as
  *complete* snapshots, not deltas).
- ``titan_getPammQuote`` — the best quote across all pAMMs for a size.
- ``titan_getPammQuoteVenue`` — the same, pinned to one venue.

The snapshot payload (the JSON-RPC ``result`` or a WS frame) looks like::

    {
      "slot": 14581462,
      "blockNumber": 25345763,
      "timestamp": 1781801564588230787,
      "pamms": [{
        "pamm": "0x5979...",
        "pairs": [{
          "tokenIn": "0x2260...", "tokenOut": "0xa0b8...",
          "orderBook": [{"amountIn": "0x989680", "amountOut": "0x174b67393", "variant": "Simulated"}]
        }]
      }]
    }
"""

from __future__ import annotations

import abc
import asyncio
import json
from dataclasses import dataclass, field
from typing import Any, Literal

import aiohttp
import websockets
from eth_typing import ChecksumAddress
from eth_utils import to_checksum_address

from .._tls import ssl_context as _ssl_context
from ..error import PricesError, TimeoutError

DEFAULT_PRICE_LEVELS_RPC_URL = "https://rpc.titanbuilder.xyz"
#: Default price-levels stream endpoint. The stream is served from regional
#: hosts (``eu.``, ``ap.``, ``us.``); override the URL to pick the nearest.
DEFAULT_PRICE_LEVELS_WS_URL = "wss://eu.rpc.titanbuilder.xyz/ws/pamm_price_levels"

#: Whether a rung came from an EVM simulation or a spline interpolation.
PriceVariant = Literal["Simulated", "Interpolated"]
_PRICE_VARIANTS: frozenset[str] = frozenset(("Simulated", "Interpolated"))


@dataclass
class PriceLevel:
    """One rung of a pair's order book: ``amount_in`` of ``token_in`` quotes ``amount_out``."""

    amount_in: int
    amount_out: int
    variant: PriceVariant


@dataclass
class PairPriceLevels:
    """The order book a pAMM quotes for one ``token_in``/``token_out`` pair."""

    token_in: ChecksumAddress
    token_out: ChecksumAddress
    order_book: list[PriceLevel] = field(default_factory=list)


@dataclass
class PammPriceLevels:
    """One pAMM's price levels across all the pairs it quotes."""

    pamm: ChecksumAddress
    pairs: list[PairPriceLevels] = field(default_factory=list)


@dataclass
class PriceLevelsSnapshot:
    """A parsed price-levels payload: per-pAMM order books plus block context."""

    #: Block the levels were generated against.
    block_number: int | None = None
    #: Slot the levels were generated against.
    slot: int | None = None
    #: Generation time in nanoseconds since epoch.
    timestamp_ns: int | None = None
    pamms: list[PammPriceLevels] = field(default_factory=list)


@dataclass
class TitanQuote:
    """A single quote from ``titan_getPammQuote`` / ``titan_getPammQuoteVenue``."""

    token_in: ChecksumAddress
    token_out: ChecksumAddress
    amount_in: int
    amount_out: int
    #: pAMM that produced the quote.
    pamm: ChecksumAddress
    #: Router associated with the quote.
    router: ChecksumAddress
    block_number: int | None = None
    slot: int | None = None
    timestamp_ns: int | None = None


def _parse_u256_hex(value: Any) -> int | None:
    if not isinstance(value, str) or not value.startswith("0x"):
        return None
    try:
        return int(value[2:], 16)
    except ValueError:
        return None


def _parse_u64_field(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value:
        try:
            return int(value[2:], 16) if value.startswith("0x") else int(value)
        except ValueError:
            return None
    return None


def _parse_address(value: Any) -> ChecksumAddress | None:
    if not isinstance(value, str):
        return None
    try:
        return to_checksum_address(value)
    except ValueError:
        return None


def parse_price_levels_message(raw: Any) -> PriceLevelsSnapshot:
    """Parse a raw price-levels payload (a WS frame or the JSON-RPC ``result``).

    Hex amounts become ``int``s, addresses are checksummed, and pAMMs/pairs/rungs
    that are malformed (missing fields, unknown variant) are dropped.
    """
    if not isinstance(raw, dict):
        raise PricesError("price-levels message is not a JSON object")

    raw_pamms = raw.get("pamms")
    pamms = (
        [p for entry in raw_pamms if (p := _parse_pamm(entry)) is not None]
        if isinstance(raw_pamms, list)
        else []
    )

    timestamp = raw.get("timestamp")
    return PriceLevelsSnapshot(
        block_number=_parse_u64_field(raw.get("blockNumber", raw.get("block_number"))),
        slot=_parse_u64_field(raw.get("slot")),
        # Titan timestamps are nanoseconds; Python ints are unbounded, so no overflow.
        timestamp_ns=timestamp
        if isinstance(timestamp, int) and not isinstance(timestamp, bool)
        else None,
        pamms=pamms,
    )


def _parse_pamm(entry: Any) -> PammPriceLevels | None:
    if not isinstance(entry, dict):
        return None
    pamm = _parse_address(entry.get("pamm"))
    if pamm is None:
        return None
    raw_pairs = entry.get("pairs")
    pairs = (
        [p for raw_pair in raw_pairs if (p := _parse_pair(raw_pair)) is not None]
        if isinstance(raw_pairs, list)
        else []
    )
    return PammPriceLevels(pamm=pamm, pairs=pairs)


def _parse_pair(entry: Any) -> PairPriceLevels | None:
    if not isinstance(entry, dict):
        return None
    token_in = _parse_address(entry.get("tokenIn"))
    token_out = _parse_address(entry.get("tokenOut"))
    if token_in is None or token_out is None:
        return None
    raw_book = entry.get("orderBook")
    order_book = (
        [lvl for rung in raw_book if (lvl := _parse_level(rung)) is not None]
        if isinstance(raw_book, list)
        else []
    )
    return PairPriceLevels(token_in=token_in, token_out=token_out, order_book=order_book)


def _parse_level(entry: Any) -> PriceLevel | None:
    if not isinstance(entry, dict):
        return None
    amount_in = _parse_u256_hex(entry.get("amountIn"))
    amount_out = _parse_u256_hex(entry.get("amountOut"))
    variant = entry.get("variant")
    if amount_in is None or amount_out is None or variant not in _PRICE_VARIANTS:
        return None
    return PriceLevel(amount_in=amount_in, amount_out=amount_out, variant=variant)


def _parse_titan_quote(raw: Any) -> TitanQuote:
    if not isinstance(raw, dict):
        raise PricesError("price-levels quote result is not a JSON object")
    token_in = _parse_address(raw.get("tokenIn"))
    token_out = _parse_address(raw.get("tokenOut"))
    pamm = _parse_address(raw.get("pamm"))
    router = _parse_address(raw.get("router"))
    amount_in = _parse_u256_hex(raw.get("amountIn"))
    amount_out = _parse_u256_hex(raw.get("amountOut"))
    if None in (token_in, token_out, pamm, router) or amount_in is None or amount_out is None:
        raise PricesError("price-levels quote result is missing required fields")

    timestamp = raw.get("timestamp")
    return TitanQuote(
        token_in=token_in,
        token_out=token_out,
        amount_in=amount_in,
        amount_out=amount_out,
        pamm=pamm,
        router=router,
        block_number=_parse_u64_field(raw.get("blockNumber", raw.get("block_number"))),
        slot=_parse_u64_field(raw.get("slot")),
        timestamp_ns=timestamp
        if isinstance(timestamp, int) and not isinstance(timestamp, bool)
        else None,
    )


def _extract_rpc_result(body: Any) -> Any:
    """Validate a JSON-RPC response body and return its ``result``.

    A present-but-null ``"error"`` is treated as success (servers commonly send
    ``{"result": {...}, "error": null}``), mirroring :mod:`propamm.overrides`.
    """
    if not isinstance(body, dict):
        raise PricesError("price-levels RPC response is not a JSON object")
    error = body.get("error")
    if error is not None:
        raise PricesError(f"price-levels RPC error: {error}")
    result = body.get("result")
    if result is None:
        raise PricesError("price-levels RPC response had neither a result nor an error")
    return result


class PriceLevelsSource(abc.ABC):
    """Anything callers can pull price-level snapshots from."""

    @abc.abstractmethod
    async def get_price_levels(self) -> PriceLevelsSnapshot: ...

    async def close(self) -> None:
        """Immediate, permanent teardown. Default: no-op."""


class PriceLevelsRpcSource(PriceLevelsSource):
    """Fetch-on-demand source over Titan's JSON-RPC endpoint.

    Besides the price-level snapshot it exposes the two quote helpers, which
    share the same endpoint and are served from the latest snapshot (so they
    skip the on-chain ``eth_call`` that :meth:`PropAmmRouter.quote` runs).
    """

    def __init__(self, url: str = DEFAULT_PRICE_LEVELS_RPC_URL) -> None:
        self.url = url

    async def get_price_levels(self) -> PriceLevelsSnapshot:
        """Latest full snapshot via ``titan_getPammPriceLevels``."""
        return parse_price_levels_message(await self._rpc("titan_getPammPriceLevels", []))

    async def get_quote(self, token_in: str, token_out: str, amount_in: int) -> TitanQuote:
        """Best quote across all pAMMs via ``titan_getPammQuote``."""
        params = [to_checksum_address(token_in), to_checksum_address(token_out), hex(amount_in)]
        return _parse_titan_quote(await self._rpc("titan_getPammQuote", params))

    async def get_quote_venue(
        self, venue: str, token_in: str, token_out: str, amount_in: int
    ) -> TitanQuote:
        """Quote from a specific venue via ``titan_getPammQuoteVenue``."""
        params = [
            to_checksum_address(venue),
            to_checksum_address(token_in),
            to_checksum_address(token_out),
            hex(amount_in),
        ]
        return _parse_titan_quote(await self._rpc("titan_getPammQuoteVenue", params))

    async def _rpc(self, method: str, params: list) -> Any:
        request = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
        ssl_ctx = _ssl_context() if self.url.startswith("https") else None
        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(self.url, json=request, ssl=ssl_ctx) as response:
                    if response.status != 200:
                        raise PricesError(
                            f"price-levels RPC request failed with status {response.status}"
                        )
                    body = await response.json()
        except aiohttp.ClientError as exc:
            raise PricesError(f"price-levels RPC request failed: {exc}") from exc
        return _extract_rpc_result(body)


_RECONNECT_INITIAL = 1.0
_RECONNECT_MAX = 30.0


class PriceLevelsWsSource(PriceLevelsSource):
    """Streaming source: connects lazily on the first ``get_price_levels`` call.

    Reconnects with exponential backoff. Unlike the overrides stream, each
    price-levels frame is a *complete* snapshot, so a frame replaces the cached
    one outright. The connection is dropped after ``idle_timeout`` without calls
    and re-established on demand, so no explicit teardown is needed; :meth:`close`
    tears down immediately and permanently.
    """

    def __init__(
        self,
        url: str = DEFAULT_PRICE_LEVELS_WS_URL,
        *,
        first_frame_timeout: float = 5.0,
        idle_timeout: float = 30.0,
    ) -> None:
        self.url = url
        self.first_frame_timeout = first_frame_timeout
        self.idle_timeout = idle_timeout

        # No lock guards this shared state: asyncio is single-threaded and only
        # switches coroutines at `await`, so a block with no `await` is atomic.
        # The writer (`_handle_frame`) is fully synchronous, and the reader hands
        # back the snapshot object a frame replaces wholesale, so no torn reads.
        self._snapshot = PriceLevelsSnapshot()
        self._has_frame = False
        self._closed = False
        self._last_use = 0.0
        self._last_error: Exception | None = None
        self._task: asyncio.Task | None = None
        self._frame_event = asyncio.Event()

    async def get_price_levels(self) -> PriceLevelsSnapshot:
        """Return the latest complete snapshot, waiting for the first frame if needed."""
        if self._closed:
            raise PricesError("price-levels source is closed")
        self._last_use = asyncio.get_event_loop().time()
        self._ensure_running()

        if not self._has_frame:
            try:
                await asyncio.wait_for(self._frame_event.wait(), self.first_frame_timeout)
            except asyncio.TimeoutError as exc:
                detail = f": {self._last_error}" if self._last_error else ""
                raise TimeoutError(
                    f"no price-levels frame received within {self.first_frame_timeout}s{detail}"
                ) from exc

        if self._closed:
            raise PricesError("price-levels source is closed")
        return self._snapshot

    async def close(self) -> None:
        """Immediate, permanent teardown."""
        self._closed = True
        self._frame_event.set()
        task, self._task = self._task, None
        if task is not None:
            task.cancel()

    def _ensure_running(self) -> None:
        """Spawn the listener if it isn't running (never started, or exited on idle/error)."""
        if self._task is None or self._task.done():
            self._frame_event.clear()
            self._task = asyncio.create_task(self._run())

    async def _run(self) -> None:
        """Background listener: connect, replace the snapshot per frame, reconnect, idle out."""
        backoff = _RECONNECT_INITIAL
        ssl_ctx = _ssl_context() if self.url.startswith("wss") else None
        while not self._closed and self._idle_remaining() > 0:
            try:
                # Complete snapshots are large; lift websockets' default frame cap.
                async with websockets.connect(self.url, ssl=ssl_ctx, max_size=None) as ws:
                    backoff = _RECONNECT_INITIAL
                    while not self._closed:
                        timeout = self._idle_remaining()
                        if timeout <= 0:
                            break
                        try:
                            message = await asyncio.wait_for(ws.recv(), timeout)
                        except asyncio.TimeoutError:
                            continue  # re-check idle, then keep listening
                        self._handle_frame(message)
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # reconnect on any transport error
                self._last_error = exc

            if self._closed or self._idle_remaining() <= 0:
                break
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, _RECONNECT_MAX)

        # Require a fresh frame after a respawn, so a stale snapshot isn't served.
        self._has_frame = False

    def _idle_remaining(self) -> float:
        elapsed = asyncio.get_event_loop().time() - self._last_use
        return self.idle_timeout - elapsed

    def _handle_frame(self, data: Any) -> None:
        if not isinstance(data, (str, bytes, bytearray)):
            return
        try:
            frame = parse_price_levels_message(json.loads(data))
        except (json.JSONDecodeError, PricesError):
            return  # skip undecodable frames

        # Each frame is a complete snapshot, so it replaces the cached one.
        self._snapshot = frame
        self._has_frame = True
        self._frame_event.set()


class PriceLevels:
    """Entry point for Titan's pAMM price levels, structured like :class:`PropAmmRouter`.

    A single client wrapping a default :class:`PriceLevelsSource` you can
    override in the constructor:

    - :meth:`get_price_levels` reads the latest snapshot from the configured
      source (one-shot HTTP by default; pass a :class:`PriceLevelsWsSource` to
      stream).
    - :meth:`get_quote` / :meth:`get_quote_venue` resolve a single size against
      Titan's latest snapshot over HTTP JSON-RPC. They are HTTP-only — the stream
      pushes snapshots, not quotes — so they always go through an RPC source.
    """

    def __init__(
        self,
        source: PriceLevelsSource | None = None,
        *,
        rpc_url: str | None = None,
    ) -> None:
        _rpc_url = rpc_url or DEFAULT_PRICE_LEVELS_RPC_URL
        self.source: PriceLevelsSource = source or PriceLevelsRpcSource(_rpc_url)
        # Quote helpers are HTTP-only. Reuse the snapshot source when it already
        # speaks HTTP so a custom endpoint covers both; otherwise use rpc_url (or
        # the default) so a WsSource paired with a private deployment doesn't
        # silently route quotes to the public endpoint.
        if isinstance(self.source, PriceLevelsRpcSource):
            self._rpc = self.source
        else:
            self._rpc = PriceLevelsRpcSource(_rpc_url)

    async def get_price_levels(self) -> PriceLevelsSnapshot:
        """Latest price-level snapshot from the configured source."""
        return await self.source.get_price_levels()

    async def get_quote(self, token_in: str, token_out: str, amount_in: int) -> TitanQuote:
        """Best quote across all pAMMs for a size (``titan_getPammQuote``)."""
        return await self._rpc.get_quote(token_in, token_out, amount_in)

    async def get_quote_venue(
        self, venue: str, token_in: str, token_out: str, amount_in: int
    ) -> TitanQuote:
        """Quote from a specific venue for a size (``titan_getPammQuoteVenue``)."""
        return await self._rpc.get_quote_venue(venue, token_in, token_out, amount_in)

    async def close(self) -> None:
        """Tear down the snapshot source (closes the stream socket, if any). The
        HTTP quote path holds no connection, so there is nothing else to release.
        """
        await self.source.close()
