"""Titan pAMM state overrides: fetch them, and replay them into an anvil fork.

The propAMMs price off-chain liquidity that mainnet state does not reflect, so a
plain `eth_call` against committed state sees stale lanes and most venues revert.
Titan publishes the missing state two ways, both consumed here:

  * a WebSocket stream, `wss://eu.data.titanbuilder.xyz/ws/pamm_quote_stream`,
    one frame per pAMM update;
  * a pull-based twin, `titan_getPammStateOverrides` on
    `https://eu.data.titanbuilder.xyz`, which returns every pAMM in one payload.

Both share one shape -- top-level metadata plus one entry per pAMM::

    {
      "blockNumber": "0x18cb1fe",
      "slot": 15235932,
      "0x<pamm>": {"stateOverride": {"0x<addr>": {"balance": ..., "nonce": ...,
                                                  "stateDiff": {"0x<slot>": "0x<word>"}}}}
    }

The SDKs attach this to `eth_call`'s third parameter, which applies for one call
only -- which is why `forge test` cannot use it. This module instead replays the
same diffs into an anvil fork with `anvil_setStorageAt` / `anvil_setBalance` /
`anvil_setNonce`, making them ordinary fork state that *real transactions* execute
against. Gas accounting is unaffected: EIP-2929 charges on access pattern, not on
whether a slot came from the remote node or a local write.

TWO FACTS THAT ARE LOAD-BEARING, both established empirically (see
`scripts/README.md` section 6):

  1. `blockNumber` is **head + 1** -- the block Titan is *building*, which no
     public node has yet. Fork at `blockNumber - 1` and execute as `blockNumber`.
     This is exactly what the SDKs mean by `blockOverrides{number: N}` against
     `latest` state.
  2. Venues check `block.timestamp` against the lane they published, so the fork
     must be pinned to the slot's canonical time, `1606824023 + slot * 12`.
     Without it Fermi does not merely go inactive -- it reverts with an
     arithmetic underflow on its own staleness math.

Standard library only, per `scripts/README.md`.
"""

from __future__ import annotations

import base64
import json
import os
import socket
import ssl
import struct
import time
import urllib.request
from dataclasses import dataclass, field
from typing import Any

#: Served from regional hosts (``eu.``, ``ap.``, ``us.``); pass a different URL
#: to pick the nearest. Kept in step with the SDKs' own defaults --
#: `sdk/python/src/propamm/overrides/__init__.py`, and its TS/Rust mirrors.
DEFAULT_OVERRIDES_RPC_URL = "https://eu.data.titanbuilder.xyz"
DEFAULT_OVERRIDES_WS_URL = "wss://eu.data.titanbuilder.xyz/ws/pamm_quote_stream"

#: Mainnet beacon-chain genesis time and slot length. A block's canonical
#: timestamp is `genesis + slot * 12`. Mirrors `sdk/python/src/propamm/overrides`.
BEACON_GENESIS_TS = 1_606_824_023
SECS_PER_SLOT = 12

#: Keys in the payload that are metadata rather than a pAMM entry.
META_KEYS = frozenset({"slot", "blockNumber", "block_number", "timestamp"})

#: The venues `addVenue` has listed on the router, lowercased. Mirrors
#: `sdk/python/src/propamm/common/pamms.py`; Titan serves other pAMMs too, and
#: those are carried through the snapshot but are not router venues.
WHITELIST_VENUES: dict[str, str] = {
    "fermi": "0x5979458912F80B96d30D4220af8E2e4925A33320",
    "bebop": "0xB09AaA5614916d7AEb59C295C52c92ca82aDdD76",
    "kipseli": "0x71e790dd841c8A9061487cb3E78C288E75cE0B3d",
    "tempest": "0x00000003f1ec2379e79F58E12EC6C4F51Ee92149",
    "taurusfi": "0x217d58931A8549ca539426AA8152E33dAfc3d95A",
    "metric": "0xE715Dc29d2c273D0FC5A03e5Cca9CcB0Abb1dCDB",
    "elzorro": "0xCF211B4dD0D2be5C173Ea57Bcf938FC61d1d3bd3",
}
_VENUE_BY_ADDR = {addr.lower(): name for name, addr in WHITELIST_VENUES.items()}


def venue_name(address: str) -> str:
    """Human name for a pAMM address, or the address itself if not a router venue."""
    return _VENUE_BY_ADDR.get(address.lower(), address.lower())


def as_int(value: Any) -> int:
    """Parse a field that arrives as an int on the stream but hex over RPC."""
    if isinstance(value, bool):
        raise ValueError("expected a number, got a bool")
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return int(value, 16) if value.startswith("0x") else int(value)
    raise ValueError(f"cannot read {value!r} as a number")


@dataclass
class Snapshot:
    """One internally consistent set of overrides, all targeting the same block."""

    block_number: int
    slot: int
    #: pAMM address (lowercased) -> the raw `stateOverride` map for that pAMM.
    per_pamm: dict[str, dict[str, Any]] = field(default_factory=dict)

    @property
    def fork_block(self) -> int:
        """The block to fork at: Titan targets the block it is *building*."""
        return self.block_number - 1

    @property
    def timestamp(self) -> int:
        """The canonical timestamp venues check their published lane against."""
        return BEACON_GENESIS_TS + self.slot * SECS_PER_SLOT

    @property
    def router_venues(self) -> list[str]:
        """Names of router-whitelisted venues carrying overrides in this snapshot."""
        return sorted(venue_name(p) for p in self.per_pamm if p.lower() in _VENUE_BY_ADDR)

    def counts(self) -> tuple[int, int]:
        """(accounts touched, storage slots written) this snapshot would apply."""
        accounts = slots = 0
        for entry in self.per_pamm.values():
            for spec in entry.values():
                accounts += 1
                slots += len(spec.get("stateDiff") or {})
        return accounts, slots


def _split_payload(raw: dict[str, Any]) -> tuple[int, int, dict[str, dict[str, Any]]]:
    """Split a payload into (blockNumber, slot, per-pAMM stateOverride maps)."""
    block_number = as_int(raw["blockNumber"] if "blockNumber" in raw else raw["block_number"])
    slot = as_int(raw["slot"])
    per_pamm: dict[str, dict[str, Any]] = {}
    for key, value in raw.items():
        if key in META_KEYS or not isinstance(value, dict):
            continue
        overrides = value.get("stateOverride") or value.get("state_override")
        if isinstance(overrides, dict) and overrides:
            per_pamm[key.lower()] = overrides
    return block_number, slot, per_pamm


# --------------------------------------------------------------------------- #
# JSON-RPC
# --------------------------------------------------------------------------- #


def rpc(url: str, method: str, params: list[Any], timeout: float = 60.0) -> Any:
    """One JSON-RPC call. Returns `result`; raises on a transport or RPC error."""
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    request = urllib.request.Request(url, data=body, headers={"content-type": "application/json"})
    context = ssl.create_default_context() if url.startswith("https") else None
    with urllib.request.urlopen(request, timeout=timeout, context=context) as response:
        payload = json.loads(response.read())
    if payload.get("error"):
        raise RuntimeError(f"{method} failed: {payload['error']}")
    return payload.get("result")


def fetch_snapshot_rpc(url: str = DEFAULT_OVERRIDES_RPC_URL) -> Snapshot:
    """Pull one complete snapshot via `titan_getPammStateOverrides`."""
    raw = rpc(url, "titan_getPammStateOverrides", [])
    if raw is None:
        raise RuntimeError("titan_getPammStateOverrides returned no result")
    block_number, slot, per_pamm = _split_payload(raw)
    return Snapshot(block_number=block_number, slot=slot, per_pamm=per_pamm)


# --------------------------------------------------------------------------- #
# Minimal RFC 6455 client, so the stream needs no third-party dependency
# --------------------------------------------------------------------------- #


class _WebSocket:
    """Just enough WebSocket to read text frames from a TLS endpoint."""

    def __init__(self, url: str, timeout: float = 20.0) -> None:
        if not url.startswith("wss://"):
            raise ValueError("only wss:// is supported")
        hostpath = url[len("wss://") :]
        host, _, path = hostpath.partition("/")
        host, _, port = host.partition(":")
        self._sock = ssl.create_default_context().wrap_socket(
            socket.create_connection((host, int(port or 443)), timeout=timeout),
            server_hostname=host,
        )
        self._sock.settimeout(timeout)
        self._buffer = b""

        key = base64.b64encode(os.urandom(16)).decode()
        # The endpoint 403s a bare handshake, so send the headers a browser or
        # the `websockets` library would: Origin and a User-Agent.
        handshake = (
            f"GET /{path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
            f"Origin: https://{host}\r\nUser-Agent: propamm-split-gas/1.0\r\n\r\n"
        )
        self._sock.sendall(handshake.encode())
        while b"\r\n\r\n" not in self._buffer:
            self._recv_more()
        head, _, rest = self._buffer.partition(b"\r\n\r\n")
        if b"101" not in head.split(b"\r\n")[0]:
            raise RuntimeError(f"websocket handshake refused: {head.splitlines()[0]!r}")
        self._buffer = rest

    def _recv_more(self) -> None:
        chunk = self._sock.recv(65536)
        if not chunk:
            raise ConnectionError("websocket closed by peer")
        self._buffer += chunk

    def _take(self, count: int) -> bytes:
        while len(self._buffer) < count:
            self._recv_more()
        head, self._buffer = self._buffer[:count], self._buffer[count:]
        return head

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        """Client frames must be masked (RFC 6455 section 5.3)."""
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        header = struct.pack("!BB", 0x80 | opcode, 0x80 | len(payload))
        self._sock.sendall(header + mask + masked)

    def recv_text(self) -> str | None:
        """Next text frame, or None for a close. Answers pings transparently."""
        while True:
            byte0, byte1 = struct.unpack("!BB", self._take(2))
            opcode, length = byte0 & 0x0F, byte1 & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._take(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._take(8))[0]
            masked = bool(byte1 & 0x80)
            payload = self._take(length)
            if masked:  # servers must not mask, but be forgiving
                mask, payload = payload[:4], payload[4:]
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x8:
                return None
            if opcode == 0x9:
                self._send_frame(0xA, payload)
                continue
            if opcode in (0x1, 0x2):
                return payload.decode("utf-8", "replace")
            # continuation / pong: nothing this reader needs

    def close(self) -> None:
        try:
            self._send_frame(0x8, b"")
        except OSError:
            pass
        finally:
            self._sock.close()


def fetch_snapshot_ws(
    url: str = DEFAULT_OVERRIDES_WS_URL,
    *,
    seconds: float = 12.0,
    verbose: bool = False,
) -> Snapshot:
    """Accumulate stream frames into one **internally consistent** snapshot.

    Each frame carries a single pAMM, so a snapshot has to be assembled. Frames
    are grouped by the block they target and the newest fully-observed block
    wins: a pAMM that last published for an older block is left out rather than
    mixed in, because its lane really is stale for the block we simulate.
    """
    by_block: dict[int, dict[str, dict[str, Any]]] = {}
    slots: dict[int, int] = {}
    frames = 0
    deadline = time.monotonic() + seconds
    sock = _WebSocket(url, timeout=max(5.0, seconds))
    try:
        while time.monotonic() < deadline:
            sock._sock.settimeout(max(0.1, deadline - time.monotonic()))
            try:
                message = sock.recv_text()
            except (socket.timeout, TimeoutError):
                break
            if message is None:
                break
            frames += 1
            try:
                block_number, slot, per_pamm = _split_payload(json.loads(message))
            except (ValueError, KeyError):
                continue
            if per_pamm:
                by_block.setdefault(block_number, {}).update(per_pamm)
                slots[block_number] = slot
    finally:
        sock.close()

    if not by_block:
        raise RuntimeError(f"no usable frames from {url} in {seconds:.0f}s")

    # The newest block is still filling when the window closes, so prefer the
    # newest block that has at least as many pAMMs as the best block seen.
    best = max(by_block, key=lambda b: (len(by_block[b]), b))
    chosen = max(b for b in by_block if len(by_block[b]) >= len(by_block[best]))
    if verbose:
        print(
            f"  stream: {frames} frames in {seconds:.0f}s; "
            f"blocks {min(by_block)}..{max(by_block)}; "
            f"chose block {chosen} with {len(by_block[chosen])} pAMMs"
        )
    return Snapshot(block_number=chosen, slot=slots[chosen], per_pamm=by_block[chosen])


#: The stream rate-limits reconnects and answers 403 for a while after a burst,
#: so a single refusal says nothing about availability -- back off and retry.
_WS_ATTEMPTS = 4
_WS_BACKOFF = 5.0


def fetch_snapshot(source: str = "ws", *, seconds: float = 12.0, verbose: bool = False) -> Snapshot:
    """Fetch a snapshot from the stream, falling back to the RPC twin."""
    if source in ("ws", "auto"):
        last: Exception | None = None
        for attempt in range(_WS_ATTEMPTS):
            try:
                return fetch_snapshot_ws(seconds=seconds, verbose=verbose)
            except Exception as exc:  # noqa: BLE001 - any stream failure is recoverable
                last = exc
                if attempt + 1 < _WS_ATTEMPTS:
                    delay = _WS_BACKOFF * (attempt + 1)
                    if verbose:
                        print(f"  stream attempt {attempt + 1} failed ({exc}); retrying in {delay:.0f}s")
                    time.sleep(delay)
        if source == "ws":
            raise RuntimeError(f"stream unavailable after {_WS_ATTEMPTS} attempts: {last}")
        print(f"  stream unavailable ({last}); falling back to titan_getPammStateOverrides")
    return fetch_snapshot_rpc()


# --------------------------------------------------------------------------- #
# Replay into anvil
# --------------------------------------------------------------------------- #


def _word(value: str) -> str:
    """Left-pad a hex quantity to a full 32-byte word, as setStorageAt wants."""
    return "0x" + value[2:].rjust(64, "0")


def apply_to_anvil(anvil_url: str, snapshot: Snapshot, *, only: set[str] | None = None) -> tuple[int, int]:
    """Replay a snapshot's balance / nonce / storage diffs into an anvil fork.

    `only` restricts the replay to the named pAMMs (by venue name or address),
    which is how a run isolates "what would this venue set cost" without the
    other venues' lanes competing.

    Returns (accounts touched, storage slots written).
    """
    wanted = None
    if only is not None:
        wanted = {WHITELIST_VENUES.get(name, name).lower() for name in only}

    accounts = written = 0
    for pamm, overrides in snapshot.per_pamm.items():
        if wanted is not None and pamm not in wanted:
            continue
        for address, spec in overrides.items():
            if "balance" in spec:
                rpc(anvil_url, "anvil_setBalance", [address, spec["balance"]])
            if "nonce" in spec:
                rpc(anvil_url, "anvil_setNonce", [address, spec["nonce"]])
            accounts += 1
            for slot, value in (spec.get("stateDiff") or {}).items():
                rpc(anvil_url, "anvil_setStorageAt", [address, _word(slot), _word(value)])
                written += 1
    return accounts, written


def freeze_time_at(anvil_url: str, timestamp: int) -> None:
    """Pin the fork to `timestamp` and hold it there across every later block.

    A zero block-timestamp interval is what makes a multi-transaction measurement
    possible at all: lanes are valid for about one slot, so letting anvil's
    default +1s per block run would expire them partway through a run and turn a
    gas measurement into a study of the Uniswap fallback.
    """
    rpc(anvil_url, "anvil_setBlockTimestampInterval", [0])
    rpc(anvil_url, "evm_setNextBlockTimestamp", [timestamp])
    rpc(anvil_url, "evm_mine", [])


if __name__ == "__main__":  # a quick look at what Titan is publishing right now
    import argparse

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source", choices=("ws", "rpc", "auto"), default="auto")
    parser.add_argument("--seconds", type=float, default=12.0, help="stream window")
    args = parser.parse_args()

    snap = fetch_snapshot(args.source, seconds=args.seconds, verbose=True)
    n_accounts, n_slots = snap.counts()
    print(f"block {snap.block_number} (fork at {snap.fork_block}), slot {snap.slot} -> ts {snap.timestamp}")
    print(f"{len(snap.per_pamm)} pAMMs, {n_accounts} accounts, {n_slots} storage slots")
    print(f"router-whitelisted venues present: {', '.join(snap.router_venues) or 'NONE'}")
