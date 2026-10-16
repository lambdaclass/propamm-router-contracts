"""pAMM price-level sources.

Alongside the raw state overrides (see :mod:`propamm.overrides`), Titan
publishes prices it has *already quoted*, grouped per pAMM: for each trading
pair an ``order_book`` of rungs mapping an input amount to the output it would
receive. This lets a taker read prices across a range of trade sizes without
running an ``eth_call`` simulation per size.

Titan exposes this through a WebSocket stream and three JSON-RPC methods:

- ``titan_getPammBooks`` — the full snapshot (also streamed at
  ``wss://.../ws/pamm_price_levels_v2`` as *complete* snapshots, not deltas).
- ``titan_getPammQuote`` — the best quote across all pAMMs for a size.
- ``titan_getPammQuoteVenue`` — the same, pinned to one venue.

The v2 payload carries one book per maker and token pair, in human units::

    {
      "slot": 15436468, "block": 26197444, "ts": 1792061637434840374,
      "books": [{
        "maker": "Tempest", "quoteAddress": "0x0000...",
        "token1Address": "0xc02a...", "token2Address": "0xdac1...",
        "bids": [{"price": 2365.0436, "cumVolume": 0.005}],
        "asks": [{"price": 2365.526259, "cumVolume": 0.004227389132525372}]
      }]
    }

A bid rung sells ``cumVolume`` of token1 for ``cumVolume * price`` of token2; an
ask rung buys ``cumVolume`` of token1 for ``cumVolume * price`` of token2. The
parser turns each side into the ``token_in -> token_out`` order book of
base-unit amounts this module has always returned, which needs each token's
decimals (see :data:`propamm.common.tokens.TOKEN_DECIMALS`). Titan sends those
numbers as floats, so a rebuilt amount can be a few base units off the exact
simulated one. The book is filed under the router venue its quote address maps
to (:data:`propamm.common.pamms.QUOTE_ADDRESS_VENUES`).

The v1 payload (``pamms`` of hex ``amountIn``/``amountOut`` rungs) is still
parsed, for sources pointed at the deprecated endpoints.
"""

from __future__ import annotations

import abc
import asyncio
import json
from dataclasses import dataclass, field
from decimal import ROUND_HALF_UP, Context, Decimal, InvalidOperation
from typing import Any, Iterable, Literal

import aiohttp
import websockets
from eth_typing import ChecksumAddress
from eth_utils import to_checksum_address

from .._tls import ssl_context as _ssl_context
from ..common.pamms import QUOTE_ADDRESS_VENUES
from ..common.tokens import TOKEN_DECIMALS
from ..error import PricesError, TimeoutError

#: Default price-levels endpoint. Served from regional hosts (``eu.``,
#: ``ap.``, ``us.``); override the URL to pick the nearest.
DEFAULT_PRICE_LEVELS_RPC_URL = "https://eu.data.titanbuilder.xyz/data"
#: Default price-levels stream endpoint. The stream is served from regional
#: hosts (``eu.``, ``ap.``, ``us.``); override the URL to pick the nearest.
DEFAULT_PRICE_LEVELS_WS_URL = "wss://eu.data.titanbuilder.xyz/ws/pamm_price_levels_v2"

#: Whether a rung came from an EVM simulation or a spline interpolation.
PriceVariant = Literal["Simulated", "Interpolated"]
_PRICE_VARIANTS: frozenset[str] = frozenset(("Simulated", "Interpolated"))


@dataclass
class PriceLevel:
    """One rung of a pair's order book: ``amount_in`` of ``token_in`` quotes ``amount_out``."""

    amount_in: int
    amount_out: int
    #: Only the v1 payload says how a rung was produced.
    variant: PriceVariant | None = None


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


def parse_price_levels_message(
    raw: Any, decimals: dict[str, int] | None = None
) -> PriceLevelsSnapshot:
    """Parse a raw price-levels payload (a WS frame or the JSON-RPC ``result``, v2 or v1).

    Amounts become base-unit ``int``s, addresses are checksummed, and malformed
    books/pairs/rungs are dropped. A v2 book quoting a token absent from
    ``decimals`` (default :data:`TOKEN_DECIMALS`) is skipped.
    """
    if not isinstance(raw, dict):
        raise PricesError("price-levels message is not a JSON object")
    if isinstance(raw.get("books"), list):
        return _parse_books(raw, TOKEN_DECIMALS if decimals is None else decimals)

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


def _parse_books(raw: dict, decimals: dict[str, int]) -> PriceLevelsSnapshot:
    by_pamm: dict[str, dict[tuple[str, str], PairPriceLevels]] = {}
    for book in raw["books"]:
        if not isinstance(book, dict):
            continue
        quote_address = book.get("quoteAddress")
        token1 = _parse_address(book.get("token1Address"))
        token2 = _parse_address(book.get("token2Address"))
        if not isinstance(quote_address, str) or token1 is None or token2 is None:
            continue
        d1 = decimals.get(token1.lower())
        d2 = decimals.get(token2.lower())
        if d1 is None or d2 is None:
            continue

        pamm = _parse_address(QUOTE_ADDRESS_VENUES.get(quote_address.lower(), quote_address))
        if pamm is None:
            continue
        pairs = by_pamm.setdefault(pamm, {})
        # Bids: sell cumVolume of token1, receive cumVolume*price of token2.
        bids = _levels(_rungs(book.get("bids")), d1, d2)
        # Asks: pay cumVolume*price of token2, receive cumVolume of token1.
        asks = _levels(((q, v) for v, q in _rungs(book.get("asks"))), d2, d1)
        # Two quote addresses can map to one venue (Metric); the first book for a
        # pair is kept.
        if bids and (token1, token2) not in pairs:
            pairs[(token1, token2)] = PairPriceLevels(token1, token2, bids)
        if asks and (token2, token1) not in pairs:
            pairs[(token2, token1)] = PairPriceLevels(token2, token1, asks)

    timestamp = raw.get("ts")
    return PriceLevelsSnapshot(
        block_number=_parse_u64_field(raw.get("block")),
        slot=_parse_u64_field(raw.get("slot")),
        timestamp_ns=timestamp
        if isinstance(timestamp, int) and not isinstance(timestamp, bool)
        else None,
        pamms=[PammPriceLevels(pamm, list(pairs.values())) for pamm, pairs in by_pamm.items()],
    )


_EXACT = Context(prec=100)
_MAX_UINT256 = 2**256 - 1


def _rungs(value: Any) -> list[tuple[Decimal, Decimal]]:
    """``(cumVolume, cumVolume * price)`` per well-formed rung, as exact decimals."""
    if not isinstance(value, list):
        return []
    rungs = []
    for entry in value:
        if not isinstance(entry, dict):
            continue
        volume = _decimal(entry.get("cumVolume"))
        price = _decimal(entry.get("price"))
        if volume is not None and price is not None:
            # Exact: the default 28-digit context would round the product.
            rungs.append((volume, _EXACT.multiply(volume, price)))
    return rungs


def _decimal(value: Any) -> Decimal | None:
    # repr() is the shortest decimal that round-trips to the same double, which
    # is what Titan printed.
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    result = Decimal(repr(value))
    return result if result.is_finite() and result >= 0 else None


def _levels(
    rungs: Iterable[tuple[Decimal, Decimal]], decimals_in: int, decimals_out: int
) -> list[PriceLevel]:
    """``(amount_in, amount_out)`` rungs as base-unit levels, dropping any that
    overflow a uint256 or take no input (a zero ``amount_in`` reads as a free fill)."""
    levels = []
    for amount_in, amount_out in rungs:
        base_in = _base_units(amount_in, decimals_in)
        base_out = _base_units(amount_out, decimals_out)
        if base_in and base_out is not None:
            levels.append(PriceLevel(amount_in=base_in, amount_out=base_out))
    return levels


def _base_units(value: Decimal, decimals: int) -> int | None:
    """``value * 10**decimals`` rounded half up, or None past a uint256."""
    try:
        units = int(value.scaleb(decimals, _EXACT).quantize(Decimal(1), ROUND_HALF_UP, _EXACT))
    except InvalidOperation:  # past the context's 100 digits
        return None
    return units if units <= _MAX_UINT256 else None


class _TokenDecimals:
    """Token decimals: the built-in table, caller additions, and cached on-chain reads."""

    def __init__(self, decimals: dict[str, int] | None, eth_rpc_url: str | None) -> None:
        self.table = dict(TOKEN_DECIMALS)
        self.table.update({token.lower(): d for token, d in (decimals or {}).items()})
        self.eth_rpc_url = eth_rpc_url
        self._failed: set[str] = set()

    async def resolve(self, raw: Any) -> dict[str, int]:
        """Read the decimals of the payload's unknown tokens, then return the table."""
        if self.eth_rpc_url is None:
            return self.table
        unknown = [t for t in _book_tokens(raw) if t not in self.table and t not in self._failed]
        if unknown:
            results = await asyncio.gather(*(self._read(t) for t in unknown))
            for token, decimals in zip(unknown, results):
                if decimals is None:
                    self._failed.add(token)  # not retried: its books stay skipped
                else:
                    self.table[token] = decimals
        return self.table

    async def _read(self, token: str) -> int | None:
        # decimals() selector
        call = {"to": token, "data": "0x313ce567"}
        request = {"jsonrpc": "2.0", "id": 1, "method": "eth_call", "params": [call, "latest"]}
        ssl_ctx = _ssl_context() if self.eth_rpc_url.startswith("https") else None
        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(self.eth_rpc_url, json=request, ssl=ssl_ctx) as response:
                    body = await response.json()
            return int(body["result"], 16) if len(body.get("result") or "") == 66 else None
        except (aiohttp.ClientError, ValueError, KeyError, TypeError):
            return None


def _book_tokens(raw: Any) -> list[str]:
    books = raw.get("books") if isinstance(raw, dict) else None
    if not isinstance(books, list):
        return []
    tokens = {
        book[key].lower()
        for book in books
        if isinstance(book, dict)
        for key in ("token1Address", "token2Address")
        if isinstance(book.get(key), str)
    }
    return sorted(tokens)


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

    def __init__(
        self,
        url: str = DEFAULT_PRICE_LEVELS_RPC_URL,
        *,
        decimals: dict[str, int] | None = None,
        eth_rpc_url: str | None = None,
    ) -> None:
        """``decimals`` adds to or overrides :data:`TOKEN_DECIMALS`. With
        ``eth_rpc_url``, a token in neither has its ``decimals()`` read once and
        cached; otherwise books quoting it are skipped."""
        self.url = url
        self._decimals = _TokenDecimals(decimals, eth_rpc_url)

    async def get_price_levels(self) -> PriceLevelsSnapshot:
        """Latest full snapshot via ``titan_getPammBooks``."""
        raw = await self._rpc("titan_getPammBooks", [])
        return parse_price_levels_message(raw, await self._decimals.resolve(raw))

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
        decimals: dict[str, int] | None = None,
        eth_rpc_url: str | None = None,
    ) -> None:
        """``decimals`` and ``eth_rpc_url`` as in :class:`PriceLevelsRpcSource`."""
        self.url = url
        self.first_frame_timeout = first_frame_timeout
        self.idle_timeout = idle_timeout
        self._decimals = _TokenDecimals(decimals, eth_rpc_url)

        # No lock guards this shared state: asyncio is single-threaded and only
        # switches coroutines at `await`, so a block with no `await` is atomic.
        # The writer (`_handle_frame`) is fully synchronous, and the reader takes
        # the raw frame a new frame replaces wholesale, so no torn reads. Frames
        # are kept raw and parsed per call, once any unknown token's decimals
        # are read.
        self._frame: Any = None
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
        frame = self._frame
        return parse_price_levels_message(frame, await self._decimals.resolve(frame))

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
            frame = json.loads(data)
            parse_price_levels_message(frame)  # reject undecodable frames up front
        except (json.JSONDecodeError, PricesError):
            return  # skip undecodable frames

        # Each frame is a complete snapshot, so it replaces the cached one.
        self._frame = frame
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
        decimals: dict[str, int] | None = None,
        eth_rpc_url: str | None = None,
    ) -> None:
        """``decimals`` and ``eth_rpc_url`` as in :class:`PriceLevelsRpcSource`,
        for the default source."""
        _rpc_url = rpc_url or DEFAULT_PRICE_LEVELS_RPC_URL
        self.source: PriceLevelsSource = source or PriceLevelsRpcSource(
            _rpc_url, decimals=decimals, eth_rpc_url=eth_rpc_url
        )
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
