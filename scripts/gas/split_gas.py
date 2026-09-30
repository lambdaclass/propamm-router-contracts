#!/usr/bin/env python3
"""Realistic router gas, measured against live propAMMs with Titan's overrides.

    RPC_URL=<mainnet rpc> python3 scripts/gas/split_gas.py

What makes this different from every earlier gas rig in this repo: it does not
patch venue lanes with `vm.store` to force them fresh. It replays the *real*
state Titan is publishing right now (see `titan_overrides.py`) into an anvil
fork, so several propAMMs are genuinely quotable at the same block with the
prices their market makers actually published. Both the gas and the prices are
honest, where forward-patching only ever kept the gas honest.

Every number is the `gasUsed` of a **real transaction receipt**, so it includes
the 21,000 intrinsic cost and calldata -- what a user actually pays -- rather
than a `gasleft()` delta around an internal call.

Method, and why each step is there:

  * fork at `titanBlock - 1` and execute as `titanBlock`, because Titan
    publishes overrides for the block it is *building*;
  * freeze the fork's timestamp at the slot's canonical time, so lanes stay
    valid for the whole run instead of expiring a few transactions in;
  * `evm_snapshot` / `evm_revert` around every single measurement, so each shape
    executes against byte-identical state, at the same block, against venue
    inventory no earlier measurement has drained (this repo has published a
    wrong number to that exact mistake before -- see `scripts/README.md`);
  * hold order size constant while varying venue count, so a per-venue marginal
    means something (the other trap that produced a wrong published number).

Nothing here is mocked: real router bytecode behind a real ERC1967 proxy, the
real Uniswap V3 SwapRouter02 and QuoterV2, the real propAMM venues.

Standard library only; shells out to `cast` for keccak-dependent bits
(selectors, mapping slots) and to `forge` to deploy.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from titan_overrides import (  # noqa: E402
    WHITELIST_VENUES,
    Snapshot,
    apply_to_anvil,
    fetch_snapshot,
    rpc,
    venue_name,
)

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
UNISWAP_ROUTER_02 = "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45"
QUOTER_V2 = "0x61fFE014bA17989E743c5F6cB21bF9697530B21e"

#: FiatTokenV2_2 (USDC) keeps balances at slot 9; WETH9 keeps them at slot 3.
BALANCE_SLOT = {USDC.lower(): 9, WETH.lower(): 3}
DECIMALS = {USDC.lower(): 6, WETH.lower(): 18}
SYMBOL = {USDC.lower(): "USDC", WETH.lower(): "WETH"}

#: anvil's first dev account and its well-known key. Local fork only.
TAKER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
TAKER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

#: `Swapped(address,address,address,uint256,uint256,address,address)`.
SWAPPED_TOPIC = "0xfc01a2d4af46d04923f77211f1c96af350517eee1a9fc8fd3e7e1a8b78bab17f"

MAX_UINT256 = (1 << 256) - 1
GAS_CAP = 29_000_000

SIGNATURES = {
    "initialize": "initialize(address,address,address)",
    "addVenue": "addVenue(address)",
    "removeVenue": "removeVenue(address)",
    "approve": "approve(address,uint256)",
    "balanceOf": "balanceOf(address)",
    "quoteVenueV1": "quoteVenueV1(address,address,address,uint256)",
    "swapViaVenueV1": "swapViaVenueV1(address,address,address,uint256,uint256,address,uint256)",
    "swapV1": "swapV1(address,address,uint256,uint256,address,uint256)",
    "swapSplitV1": "swapSplitV1(address,address,uint256,uint256,address,uint256)",
    "fallbackSwapRouter": "fallbackSwapRouter()",
    "whitelistedVenueCount": "whitelistedVenueCount()",
    "isSplitAvailable": "isSplitAvailable()",
}


# --------------------------------------------------------------------------- #
# Shelling out
# --------------------------------------------------------------------------- #


def run(cmd: list[str], **kwargs) -> str:
    result = subprocess.run(cmd, cwd=REPO_ROOT, capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd[:3])}... failed:\n{result.stdout}\n{result.stderr}")
    return result.stdout.strip()


def selectors() -> dict[str, str]:
    """Resolve every selector once. `cast` owns keccak; the stdlib has no Keccak-256."""
    return {name: run(["cast", "sig", sig]) for name, sig in SIGNATURES.items()}


_SLOT_CACHE: dict[tuple[str, int], str] = {}


def mapping_slot(holder: str, slot: int) -> str:
    """`keccak256(abi.encode(holder, slot))` -- an ERC-20 balance's storage key."""
    key = (holder.lower(), slot)
    if key not in _SLOT_CACHE:
        _SLOT_CACHE[key] = run(["cast", "index", "address", holder, str(slot)])
    return _SLOT_CACHE[key]


# --------------------------------------------------------------------------- #
# ABI encoding: every argument in this script is a static address or uint256,
# so encoding is just 32-byte words -- no need for a dependency.
# --------------------------------------------------------------------------- #


def word(value) -> str:
    if isinstance(value, str):
        return value.lower().replace("0x", "").rjust(64, "0")
    return format(int(value), "064x")


def encode(selector: str, *args) -> str:
    return selector + "".join(word(a) for a in args)


def decode_words(data: str) -> list[int]:
    raw = data[2:] if data.startswith("0x") else data
    return [int(raw[i : i + 64], 16) for i in range(0, len(raw) - len(raw) % 64, 64)]


def as_address(value: int) -> str:
    return "0x" + format(value, "040x")


# --------------------------------------------------------------------------- #
# anvil
# --------------------------------------------------------------------------- #


class Anvil:
    def __init__(self, fork_block: int, port: int, log_path: str) -> None:
        self.url = f"http://127.0.0.1:{port}"
        self._log = open(log_path, "w")
        self._proc = subprocess.Popen(
            [
                "anvil",
                "--fork-url", os.environ["RPC_URL"],
                "--fork-block-number", str(fork_block),
                "--port", str(port),
                "--gas-limit", str(GAS_CAP + 1_000_000),
                "--silent",
            ],
            stdout=self._log,
            stderr=subprocess.STDOUT,
        )
        for _ in range(240):
            if self._proc.poll() is not None:
                raise RuntimeError(f"anvil exited early; see {log_path}")
            try:
                rpc(self.url, "eth_blockNumber", [], timeout=2)
                return
            except Exception:  # noqa: BLE001 - still starting
                time.sleep(0.5)
        self.stop()
        raise RuntimeError(f"anvil did not come up on {self.url}; see {log_path}")

    def call(self, method: str, params: list):
        """anvil occasionally answers -32603 under a long snapshot/revert run."""
        last: Exception | None = None
        for attempt in range(4):
            try:
                return rpc(self.url, method, params)
            except RuntimeError as exc:
                if "Internal error" not in str(exc):
                    raise
                last = exc
                time.sleep(0.25 * (attempt + 1))
        raise RuntimeError(f"{method} kept failing: {last}")

    def stop(self) -> None:
        self._proc.terminate()
        try:
            self._proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self._proc.kill()
        self._log.close()

    # -- state helpers ------------------------------------------------------ #

    def set_balance_of(self, token: str, holder: str, amount: int) -> None:
        slot = mapping_slot(holder, BALANCE_SLOT[token.lower()])
        self.call("anvil_setStorageAt", [token, slot, "0x" + word(amount)])

    def freeze_at(self, timestamp: int | None = None) -> None:
        """Hold the clock still so lanes cannot expire mid-run."""
        self.call("anvil_setBlockTimestampInterval", [0])
        if timestamp is not None:
            self.call("evm_setNextBlockTimestamp", [timestamp])
            self.call("evm_mine", [])

    def snapshot(self) -> str:
        return self.call("evm_snapshot", [])

    def revert(self, snap: str) -> None:
        self.call("evm_revert", [snap])
        self.freeze_at()  # an interval set before the snapshot does not survive it

    def send(self, to: str, data: str, *, gas: int = GAS_CAP) -> dict:
        tx = {"from": TAKER, "to": to, "data": data, "gas": hex(gas)}
        tx_hash = self.call("eth_sendTransaction", [tx])
        # Automine returns the hash before the block is sealed, so poll briefly.
        for _ in range(100):
            receipt = self.call("eth_getTransactionReceipt", [tx_hash])
            if receipt is not None:
                return receipt
            time.sleep(0.05)
        raise RuntimeError(f"no receipt for {tx_hash} after 5s")

    def eth_call(self, to: str, data: str, *, state: dict | None = None) -> str | None:
        params: list = [{"from": TAKER, "to": to, "data": data, "gas": hex(GAS_CAP)}, "latest"]
        if state:
            params.append(state)
        try:
            return self.call("eth_call", params)
        except RuntimeError:
            return None


# --------------------------------------------------------------------------- #
# Deployment
# --------------------------------------------------------------------------- #

ACCESS_MANAGER = (
    "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts"
    "/access/manager/AccessManager.sol:AccessManager"
)
ERC1967_PROXY = (
    "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts"
    "/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy"
)


def forge_create(anvil: Anvil, contract: str, args: list[str]) -> str:
    cmd = [
        "forge", "create", contract,
        "--rpc-url", anvil.url,
        "--private-key", TAKER_KEY,
        "--broadcast",
        "--json",
    ]
    if args:
        cmd += ["--constructor-args", *args]
    out = run(cmd)
    # forge prints build chatter before a pretty-printed (multi-line) JSON object.
    lines = out.splitlines()
    start = next(i for i, ln in enumerate(lines) if ln.startswith("{"))
    return json.loads("\n".join(lines[start:]))["deployedTo"]


def deploy_router(anvil: Anvil, sel: dict[str, str]) -> str:
    """Real implementation behind a real ERC1967 proxy, under a real AccessManager.

    The deployer is anvil's first account and the manager's initial admin;
    `AccessManager` defaults an unconfigured function to `ADMIN_ROLE`, so it can
    drive `addVenue` / `removeVenue` directly -- which is how the run varies the
    whitelist without touching router code.
    """
    manager = forge_create(anvil, ACCESS_MANAGER, [TAKER])
    impl = forge_create(anvil, "src/PropAMMRouter.sol:PropAMMRouter", [])
    init = encode(sel["initialize"], UNISWAP_ROUTER_02, QUOTER_V2, manager)
    proxy = forge_create(anvil, ERC1967_PROXY, [impl, init])
    return proxy


# --------------------------------------------------------------------------- #
# Measurement
# --------------------------------------------------------------------------- #


@dataclass
class Measurement:
    shape: str
    direction: str
    amount_in: int
    venues: str
    venue_count: int
    live_count: int
    gas_used: int | None
    status: str
    amount_out: int | None
    prop_legs: int | None
    total_legs: int | None


def parse_legs(receipt: dict, router: str, fallback: str) -> tuple[int, int, int]:
    """(propAMM legs, total legs, summed amountOut) from a receipt's Swapped logs.

    `marketMaker` is the last of four non-indexed words. A leg counts as propAMM
    only when it is not the Uniswap fallback -- the coalesced remainder emits a
    `Swapped` too, and conflating the two is a documented trap.
    """
    prop = total = amount_out = 0
    for log in receipt.get("logs", []):
        if log["address"].lower() != router.lower():
            continue
        if not log["topics"] or log["topics"][0].lower() != SWAPPED_TOPIC:
            continue
        words = decode_words(log["data"])
        if len(words) < 4:
            continue
        total += 1
        amount_out += words[1]
        if as_address(words[3]).lower() != fallback.lower():
            prop += 1
    return prop, total, amount_out


class Rig:
    def __init__(self, anvil: Anvil, router: str, sel: dict[str, str], snapshot: Snapshot) -> None:
        self.anvil = anvil
        self.router = router
        self.sel = sel
        self.snapshot = snapshot
        self.fallback = as_address(decode_words(anvil.eth_call(router, sel["fallbackSwapRouter"]))[0])
        self.base: str | None = None

    # -- state management --------------------------------------------------- #

    def fund(self, amounts: dict[str, int]) -> None:
        for token, amount in amounts.items():
            self.anvil.set_balance_of(token, TAKER, amount)
            self.anvil.send(token, encode(self.sel["approve"], self.router, MAX_UINT256))

    def mark_base(self) -> None:
        self.base = self.anvil.snapshot()

    def reset(self) -> None:
        """Rewind to the pristine post-setup state and re-arm the snapshot.

        This is what keeps measurements independent: same block, same clock,
        same venue inventory for every shape, no matter what ran before.
        """
        assert self.base is not None
        self.anvil.revert(self.base)
        self.base = self.anvil.snapshot()

    def set_whitelist(self, venues: list[str]) -> None:
        for venue in venues:
            self.anvil.send(self.router, encode(self.sel["addVenue"], venue))

    # -- reads --------------------------------------------------------------- #

    def quote_venue(self, venue: str, token_in: str, token_out: str, amount: int) -> int | None:
        """Quote a venue without disturbing fork state.

        Quoting is state-mutating by design (Kipseli and QuoterV2 both price by
        simulating a real swap and reverting with the answer), and the Kipseli
        branch is silently skipped unless the router holds `tokenIn`. An
        `eth_call` state override funds it for the simulation only.
        """
        state = {self.router: {"stateDiff": {mapping_slot(self.router, BALANCE_SLOT[token_in.lower()]): "0x" + word(1 << 120)}}}
        data = encode(self.sel["quoteVenueV1"], venue, token_in, token_out, amount)
        out = self.anvil.eth_call(self.router, data, state=state)
        if out is None or len(out) < 66:
            return None
        value = decode_words(out)[0]
        return value or None

    # -- the measured transactions ------------------------------------------ #

    def measure(
        self,
        shape: str,
        venues: list[str],
        token_in: str,
        token_out: str,
        amount: int,
        live: list[str] | None = None,
    ) -> Measurement:
        self.reset()
        self.set_whitelist(venues)

        direction = f"{SYMBOL[token_in.lower()]}->{SYMBOL[token_out.lower()]}"
        names = ",".join(venue_name(v) for v in venues) or "-"
        live_count = sum(1 for v in venues if v in (live or []))
        deadline = self.snapshot.timestamp + 600

        if shape.startswith("viaVenue:"):
            target = shape.split(":", 1)[1]
            venue = self.fallback if target == "uniswap" else WHITELIST_VENUES[target]
            data = encode(
                self.sel["swapViaVenueV1"], venue, token_in, token_out, amount, 0, TAKER, deadline
            )
        elif shape == "swapV1":
            data = encode(self.sel["swapV1"], token_in, token_out, amount, 0, TAKER, deadline)
        elif shape == "swapSplitV1":
            data = encode(self.sel["swapSplitV1"], token_in, token_out, amount, 0, TAKER, deadline)
        else:
            raise ValueError(f"unknown shape {shape}")

        receipt = self.anvil.send(self.router, data)
        ok = int(receipt["status"], 16) == 1
        gas_used = int(receipt["gasUsed"], 16)
        if not ok:
            return Measurement(shape, direction, amount, names, len(venues), live_count, None, "reverted", None, None, None)
        prop, total, amount_out = parse_legs(receipt, self.router, self.fallback)
        return Measurement(
            shape, direction, amount, names, len(venues), live_count, gas_used, "ok", amount_out, prop, total
        )


# --------------------------------------------------------------------------- #
# Driver
# --------------------------------------------------------------------------- #


def human(amount: int, token: str) -> str:
    return f"{amount / 10 ** DECIMALS[token.lower()]:,.4f} {SYMBOL[token.lower()]}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source", choices=("ws", "rpc", "auto"), default="auto",
                        help="where to read Titan overrides (default: stream, RPC on failure)")
    parser.add_argument("--stream-seconds", type=float, default=12.0)
    parser.add_argument("--port", type=int, default=8599)
    parser.add_argument("--max-venues", type=int, default=4,
                        help="largest venue count to measure a split over")
    parser.add_argument("--out", default=None, help="CSV path (default: scripts/gas/split_gas_<runId>.csv)")
    args = parser.parse_args()

    if not os.environ.get("RPC_URL"):
        print("RPC_URL is not set (a mainnet endpoint; anvil forks from it)", file=sys.stderr)
        return 2

    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_path = args.out or os.path.join(REPO_ROOT, "scripts", "gas", f"split_gas_{run_id}.csv")

    print("1. Titan overrides")
    snapshot = fetch_snapshot(args.source, seconds=args.stream_seconds, verbose=True)
    accounts, slots = snapshot.counts()
    print(f"   block {snapshot.block_number} (fork at {snapshot.fork_block}), slot {snapshot.slot}")
    print(f"   {len(snapshot.per_pamm)} pAMMs, {accounts} accounts, {slots} slots")
    print(f"   router venues in snapshot: {', '.join(snapshot.router_venues) or 'NONE'}")

    print("2. building (via_ir, so this is the slow part)")
    run(["forge", "build"])
    sel = selectors()

    print(f"3. anvil fork at {snapshot.fork_block}")
    # The anvil log is a debugging aid, not an artifact: keep it out of the repo.
    log_path = os.path.join(tempfile.gettempdir(), f"split_gas_anvil_{run_id}.log")
    anvil = Anvil(snapshot.fork_block, args.port, log_path)
    rows: list[Measurement] = []
    try:
        applied_accounts, applied_slots = apply_to_anvil(anvil.url, snapshot)
        anvil.freeze_at(snapshot.timestamp)
        head = int(anvil.call("eth_blockNumber", []), 16)
        print(f"   applied {applied_slots} slots / {applied_accounts} accounts; head {head} @ {snapshot.timestamp}")

        print("4. deploying router (real bytecode, real proxy, no mocks)")
        router = deploy_router(anvil, sel)
        print(f"   router {router}")

        rig = Rig(anvil, router, sel, snapshot)
        print(f"   fallback {rig.fallback}")

        funding = {USDC: 20_000_000 * 10**6, WETH: 20_000 * 10**18}
        rig.fund(funding)
        rig.mark_base()

        # Ladders are matched notionals across the two directions (~1k to ~1M USD),
        # so a size row means the same trade either way round.
        ladders = [
            (USDC, WETH, [1_000, 5_000, 10_000, 25_000, 50_000, 60_000, 75_000, 100_000, 1_000_000], 10**6),
            (WETH, USDC, [400, 2_000, 4_000, 10_000, 15_000, 20_000, 40_000, 400_000], 10**15),
        ]

        print("5. venue availability, swept across the ladder")
        print("   Lanes are SIZE-SPECIFIC: a venue quoting 10k may revert at 1k and at 100k,")
        print("   so a single probe size understates how many venues are really reachable.")
        rig.reset()
        rig.set_whitelist(list(WHITELIST_VENUES.values()))

        live_by_size: dict[tuple[str, int], list[str]] = {}
        for token_in, token_out, steps, unit in ladders:
            direction = f"{SYMBOL[token_in.lower()]}->{SYMBOL[token_out.lower()]}"
            print(f"\n   {direction}")
            header = "   " + " " * 12 + "".join(f"{step:>12,}" for step in steps)
            print(header)
            for name, address in WHITELIST_VENUES.items():
                cells = []
                for step in steps:
                    amount = step * unit
                    quoted = rig.quote_venue(address, token_in, token_out, amount)
                    if quoted:
                        live_by_size.setdefault((direction, amount), []).append(address)
                        cells.append(f"{quoted / 10 ** DECIMALS[token_out.lower()]:>12,.2f}")
                    else:
                        cells.append(f"{'-':>12}")
                print(f"   {name:<12}" + "".join(cells))
            for step in steps:
                amount = step * unit
                names = [venue_name(v) for v in live_by_size.get((direction, amount), [])]
                print(f"   RESULT|live_venues|{direction}|{amount}|{len(names)}|{','.join(names) or '-'}")

        all_live = sorted({v for vs in live_by_size.values() for v in vs})
        print(f"\n   RESULT|live_quotable_venues_any_size|{len(all_live)}")
        print(f"   RESULT|live_venue_names|{','.join(venue_name(v) for v in all_live)}")
        if not all_live:
            print("\nNo venue is quotable even with Titan's overrides applied -- nothing to measure.")
            return 1

        dead = [a for a in WHITELIST_VENUES.values() if a not in all_live]

        print("\n6. measuring (every row is a real transaction receipt)")
        print("   `live` counts how many of the n whitelisted venues could quote THIS size:")
        print("   a whitelisted-but-stale venue still costs a probe, which is the point of n.")
        for token_in, token_out, steps, unit in ladders:
            direction = f"{SYMBOL[token_in.lower()]}->{SYMBOL[token_out.lower()]}"
            for step in steps:
                amount = step * unit
                live = live_by_size.get((direction, amount), [])
                shapes: list[tuple[str, list[str]]] = [("viaVenue:uniswap", [])]
                if live:
                    shapes.append((f"viaVenue:{venue_name(live[0])}", [live[0]]))
                # Live venues first, padded from the stale ones, so n=2/3/4 always
                # exists and the per-venue marginal is measured at constant size.
                ordered = live + [v for v in (all_live + dead) if v not in live]
                shapes.append(("swapV1", ordered[: max(2, len(live))]))
                for count in range(2, min(args.max_venues, len(ordered)) + 1):
                    shapes.append(("swapSplitV1", ordered[:count]))

                for shape, venues in shapes:
                    try:
                        row = rig.measure(shape, venues, token_in, token_out, amount, live)
                    except RuntimeError as exc:
                        print(f"   !! {shape} n={len(venues)} at {amount}: {exc}")
                        continue
                    n_live = row.live_count
                    rows.append(row)
                    tag = f"{row.shape}(n={row.venue_count},live={n_live})"
                    gas = f"{row.gas_used:>9,}" if row.gas_used else " reverted"
                    legs = f"{row.prop_legs}/{row.total_legs}" if row.total_legs is not None else "-"
                    out = human(row.amount_out, token_out) if row.amount_out else "-"
                    print(f"   {direction} {human(amount, token_in):>20}  {tag:<36} {gas}  legs {legs:<5} out {out}")
                    if row.gas_used:
                        print(f"   RESULT|gas|{direction}|{amount}|{row.shape}|{row.venue_count}|{n_live}|{row.gas_used}|{row.prop_legs}|{row.total_legs}|{row.amount_out}")
    finally:
        anvil.stop()
        write_csv(out_path, run_id, snapshot, rows)
    return 0


def write_csv(out_path: str, run_id: str, snapshot: Snapshot, rows: list) -> None:
    with open(out_path, "w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow([
            "run_id", "titan_block", "titan_slot", "pinned_timestamp", "direction",
            "amount_in", "shape", "venue_count", "live_venue_count", "venues", "gas_used", "status",
            "amount_out", "propamm_legs", "total_legs",
        ])
        for row in rows:
            writer.writerow([
                run_id, snapshot.block_number, snapshot.slot, snapshot.timestamp, row.direction,
                row.amount_in, row.shape, row.venue_count, row.live_count, row.venues, row.gas_used, row.status,
                row.amount_out, row.prop_legs, row.total_legs,
            ])
    print(f"\nWrote {len(rows)} measurements to {out_path}")


if __name__ == "__main__":
    raise SystemExit(main())
