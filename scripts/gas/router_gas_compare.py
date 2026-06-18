#!/usr/bin/env python3
"""Compare gas: swapping through our PropAMMRouter vs. the raw PropAMM execution.

Strategy (trace decomposition): we never need separate "direct" transactions.
For each real swap we fired through the router we replay it with
`debug_traceTransaction` (callTracer) and split the total gas into:

  * inner_swap_gas      -- the venue's own `swap()` call (the irreducible
                           PropAMM execution; what you'd pay calling it directly)
  * pull_in_transfer    -- `transferFrom(user -> router)` (router pulls funds in)
  * delivery_transfer   -- `transfer(router -> venue)` (push-payment to the venue)
  * router_fixed_gas    -- everything else: intrinsic, balance-delta snapshots,
                           proxy delegatecall, reentrancy/pause guards, selection.

From that we report two "router premium" figures:

  premium_vs_raw_swap = total - inner_swap                 (gross overhead)
  premium_vs_direct   = total - (inner_swap + delivery + 21000 intrinsic)
                        (fair: a direct caller still pays one transfer + intrinsic)

How swaps are found: the PropAMM emits `Swapped(sender indexed, ...)` and, when
called by the router, `sender == router`. So we query those logs (RPC-only, no
explorer needed) to enumerate the transactions we fired.

Stdlib only -- nothing to `pip install`. Needs an archive/trace-capable RPC
(ETH_RPC_URL); publicnode supports debug_traceTransaction + callTracer.

Example:
    ETH_RPC_URL=... python3 scripts/gas/router_gas_compare.py
    python3 scripts/gas/router_gas_compare.py --from-block 25200000 --max-txs 40
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
import urllib.error
import urllib.request
from collections import defaultdict
from datetime import datetime, timezone
from decimal import Decimal

# --- Constants -------------------------------------------------------------

ROUTER = "0x4DdF368080CD7946db5b459aD591c350158175e1"  # demo-env PropAMMRouter

# Swapped(address,address,address,uint256,uint256,address) -- the venue event.
SWAPPED_TOPIC = "0x1eeaa4acf3c225a4033105c2647625dbb298dec93b14e16253c4231e26c02b1d"

SEL_SWAP = "0x9908fc8b"          # IPropAMM.swap(address,address,uint256,uint256,address,uint256)
SEL_TRANSFER = "0xa9059cbb"      # transfer(address,uint256)
SEL_TRANSFER_FROM = "0x23b872dd"  # transferFrom(address,address,uint256)

INTRINSIC_GAS = 21000  # base tx cost a direct caller would also pay

ROUTER_FNS = {
    "0x1037acb3": "swapV1",
    "0xd4a41dda": "swapWithFeeV1",
    "0x82fc5493": "swapViaVenueV1",
    "0xca775698": "swapViaVenueWithFeeV1",
    "0xf7890e1d": "swapViaSelectedVenuesV1",
    "0xcc38d822": "swapViaSelectedVenuesWithFeeV1",
}

VENUE_NAMES = {
    "0x5979458912f80b96d30d4220af8e2e4925a33320": "Fermi (new)",
    "0xb1076fe3ab5e28005c7c323bac5ac06a680d452e": "Fermi (builtin)",
    "0x71e790dd841c8a9061487cb3e78c288e75ce0b3d": "Kipseli (new)",
    "0xccdda3258aa079ce45e6aa6f35829a6612eb7c45": "Kipseli (alt)",
}

SYMBOLS = {
    "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2": ("WETH", 18),
    "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": ("USDC", 6),
    "0xdac17f958d2ee523a2206206994597c13d831ec7": ("USDT", 6),
    "0x6b175474e89094c44da98b954eedeac495271d0f": ("DAI", 18),
}

CSV_FIELDS = [
    "run_id",
    "txhash",
    "block",
    "function",
    "executed_venue",
    "venue_name",
    "token_in",
    "token_out",
    "amount_in_human",
    "amount_out_human",
    "status",
    "total_gas",
    "inner_swap_gas",
    "pull_in_transfer_gas",
    "delivery_transfer_gas",
    "router_fixed_gas",
    "premium_vs_raw_swap_gas",
    "premium_vs_raw_swap_pct",
    "direct_baseline_gas",
    "premium_vs_direct_gas",
    "premium_vs_direct_pct",
    "effective_gas_price_gwei",
    "total_cost_eth",
    "premium_vs_direct_cost_eth",
    "note",
]


# --- JSON-RPC --------------------------------------------------------------


def rpc(url: str, method: str, params: list, timeout: float = 60.0) -> object:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    req = urllib.request.Request(
        url, data=body.encode(), headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        payload = json.loads(resp.read().decode())
    if "error" in payload:
        raise RuntimeError(f"{method} -> {payload['error']}")
    return payload["result"]


def hx(v: str | None) -> int:
    return int(v, 16) if v else 0


def topic_addr(topic: str) -> str:
    """Last 20 bytes of a 32-byte topic, as a 0x address (lowercased)."""
    return "0x" + topic[-40:]


def sym(addr: str) -> str:
    s = SYMBOLS.get(addr.lower())
    return s[0] if s else addr[:6] + "…" + addr[-4:]


def decimals(addr: str) -> int:
    s = SYMBOLS.get(addr.lower())
    return s[1] if s else 18


def venue_name(addr: str) -> str:
    return VENUE_NAMES.get(addr.lower(), addr[:6] + "…" + addr[-4:])


def human(raw: int, addr: str) -> str:
    return f"{Decimal(raw) / (Decimal(10) ** decimals(addr)):f}"


# --- Log discovery ---------------------------------------------------------


def find_router_swaps(url: str, router: str, from_block: int, to_block: int, window: int) -> dict:
    """Return {txhash: log-info} for swaps where the venue's `sender` == router."""
    router_topic = "0x" + "0" * 24 + router.lower().removeprefix("0x")
    found: dict[str, dict] = {}
    start = from_block
    while start <= to_block:
        end = min(start + window - 1, to_block)
        logs = rpc(
            url,
            "eth_getLogs",
            [{
                "fromBlock": hex(start),
                "toBlock": hex(end),
                "topics": [SWAPPED_TOPIC, router_topic],
            }],
        )
        for lg in logs:
            tx = lg["transactionHash"]
            data = lg["data"][2:]
            found.setdefault(tx, {
                "block": hx(lg["blockNumber"]),
                "venue": lg["address"],
                "token_in": topic_addr(lg["topics"][2]),
                "token_out": topic_addr(lg["topics"][3]),
                "amount_in": int(data[0:64], 16) if len(data) >= 64 else 0,
                "amount_out": int(data[64:128], 16) if len(data) >= 128 else 0,
            })
        print(f"  scanned blocks {start}-{end}: {len(logs)} logs, {len(found)} txs so far")
        start = end + 1
    return found


# --- Trace decomposition ---------------------------------------------------


def decompose(trace: dict) -> dict:
    """Walk a callTracer tree, splitting gas into swap / transfers / the rest."""
    out = {
        "inner_swap_gas": 0,
        "executed_venue": "",
        "pull_in_transfer_gas": 0,
        "delivery_transfer_gas": 0,
        "other_transfer_gas": 0,
        "note": "",
    }

    def walk(node: dict, in_swap: bool) -> None:
        inp = (node.get("input") or "")[:10]
        gas = hx(node.get("gasUsed"))
        typ = node.get("type", "")
        to = (node.get("to") or "").lower()

        child_in_swap = in_swap
        # The venue's swap() call: the irreducible PropAMM execution.
        if not in_swap and inp == SEL_SWAP and typ in ("CALL", "CALLCODE"):
            if out["inner_swap_gas"] == 0:
                out["inner_swap_gas"] = gas
                out["executed_venue"] = to
            child_in_swap = True
        # Router-level token movements (outside the swap subtree).
        elif not in_swap and typ == "CALL" and inp in (SEL_TRANSFER, SEL_TRANSFER_FROM):
            if inp == SEL_TRANSFER_FROM:
                out["pull_in_transfer_gas"] += gas
            else:
                # transfer(): the push-payment to the venue (recipient == venue
                # if known); otherwise count as other plumbing.
                args = node.get("input", "")
                recipient = "0x" + args[34:74] if len(args) >= 74 else ""
                if recipient.lower() == out["executed_venue"] or out["executed_venue"] == "":
                    out["delivery_transfer_gas"] += gas
                else:
                    out["other_transfer_gas"] += gas

        for c in node.get("calls", []) or []:
            walk(c, child_in_swap)

    walk(trace, False)
    if out["inner_swap_gas"] == 0:
        out["note"] = "no PropAMM swap() frame found"
    return out


def analyze_tx(url: str, txhash: str, log: dict, run_id: str) -> dict:
    row = {f: "" for f in CSV_FIELDS}
    row.update(
        run_id=run_id,
        txhash=txhash,
        block=log["block"],
        token_in=sym(log["token_in"]),
        token_out=sym(log["token_out"]),
        amount_in_human=human(log["amount_in"], log["token_in"]),
        amount_out_human=human(log["amount_out"], log["token_out"]),
        venue_name=venue_name(log["venue"]),
        executed_venue=log["venue"],
    )

    receipt = rpc(url, "eth_getTransactionReceipt", [txhash])
    tx = rpc(url, "eth_getTransactionByHash", [txhash])
    trace = rpc(url, "debug_traceTransaction", [txhash, {"tracer": "callTracer"}])

    total = hx(receipt.get("gasUsed"))
    gas_price = hx(receipt.get("effectiveGasPrice"))
    row["status"] = "ok" if receipt.get("status") == "0x1" else "reverted"
    row["function"] = ROUTER_FNS.get((tx.get("input") or "")[:10], (tx.get("input") or "")[:10])
    row["total_gas"] = total
    row["effective_gas_price_gwei"] = f"{Decimal(gas_price) / Decimal(10**9):f}"

    d = decompose(trace)
    inner = d["inner_swap_gas"]
    pull_in = d["pull_in_transfer_gas"]
    delivery = d["delivery_transfer_gas"]
    plumbing = pull_in + delivery + d["other_transfer_gas"]

    row["inner_swap_gas"] = inner
    row["pull_in_transfer_gas"] = pull_in
    row["delivery_transfer_gas"] = delivery
    row["router_fixed_gas"] = total - inner - plumbing
    row["note"] = d["note"]
    # Prefer the trace-resolved venue when present (handles alt venues).
    if d["executed_venue"]:
        row["executed_venue"] = d["executed_venue"]
        row["venue_name"] = venue_name(d["executed_venue"])

    if inner:
        prem_raw = total - inner
        row["premium_vs_raw_swap_gas"] = prem_raw
        row["premium_vs_raw_swap_pct"] = f"{(Decimal(prem_raw) / Decimal(inner) * 100):.1f}"

        baseline = inner + delivery + INTRINSIC_GAS
        prem_dir = total - baseline
        row["direct_baseline_gas"] = baseline
        row["premium_vs_direct_gas"] = prem_dir
        row["premium_vs_direct_pct"] = f"{(Decimal(prem_dir) / Decimal(baseline) * 100):.1f}"
        if gas_price:
            row["premium_vs_direct_cost_eth"] = f"{Decimal(prem_dir) * Decimal(gas_price) / Decimal(10**18):f}"

    if gas_price:
        row["total_cost_eth"] = f"{Decimal(total) * Decimal(gas_price) / Decimal(10**18):f}"
    return row


# --- Main ------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description="Router vs direct PropAMM gas comparison.")
    ap.add_argument("--rpc", default=os.environ.get("ETH_RPC_URL", ""), help="RPC URL (default: $ETH_RPC_URL)")
    ap.add_argument("--router", default=ROUTER, help=f"Router address (default: {ROUTER})")
    ap.add_argument("--from-block", type=int, default=25000000, help="Start block for log scan (default: 25000000)")
    ap.add_argument("--to-block", type=int, default=0, help="End block (default: 0 = latest)")
    ap.add_argument("--window", type=int, default=100000, help="getLogs block window size (default: 100000)")
    ap.add_argument("--max-txs", type=int, default=60, help="Max transactions to analyze (default: 60)")
    ap.add_argument("--delay", type=float, default=0.1, help="Seconds between traced txs (default: 0.1)")
    ap.add_argument("--out", help="Output CSV (default: scripts/gas/router_gas_<runId>.csv)")
    args = ap.parse_args()

    if not args.rpc:
        print("ERROR: no RPC URL. Set ETH_RPC_URL or pass --rpc.", file=sys.stderr)
        return 2

    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_path = args.out or f"scripts/gas/router_gas_{run_id}.csv"
    to_block = args.to_block or hx(rpc(args.rpc, "eth_blockNumber", []))

    print(f"Router {args.router}")
    print(f"Scanning Swapped logs (sender=router) over blocks {args.from_block}-{to_block}...")
    swaps = find_router_swaps(args.rpc, args.router, args.from_block, to_block, args.window)
    txs = list(swaps.items())[: args.max_txs]
    print(f"\nAnalyzing {len(txs)} of {len(swaps)} discovered swaps -> {out_path}\n")

    rows = []
    with open(out_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        writer.writeheader()
        for i, (txhash, log) in enumerate(txs, 1):
            try:
                row = analyze_tx(args.rpc, txhash, log, run_id)
            except Exception as e:  # noqa: BLE001 - keep going, record the failure
                row = {f: "" for f in CSV_FIELDS}
                row.update(run_id=run_id, txhash=txhash, block=log["block"], note=f"ERROR: {e}")
            writer.writerow(row)
            f.flush()
            rows.append(row)
            print(
                f"[{i}/{len(txs)}] {row.get('venue_name',''):<16} "
                f"{row.get('token_in','')}->{row.get('token_out','')}  "
                f"total={row.get('total_gas','-')} inner={row.get('inner_swap_gas','-')} "
                f"premium_vs_direct={row.get('premium_vs_direct_gas','-')} "
                f"({row.get('premium_vs_direct_pct','-')}%) {row.get('note','')}"
            )
            if args.delay:
                time.sleep(args.delay)

    print_summary(rows)
    print(f"\nWrote {len(rows)} rows to {out_path}")
    return 0


def avg(xs: list[int]) -> float:
    return sum(xs) / len(xs) if xs else 0.0


def print_summary(rows: list[dict]) -> None:
    ok = [r for r in rows if isinstance(r.get("inner_swap_gas"), int) and r["inner_swap_gas"]]
    print("\n" + "=" * 84)
    print("GAS COMPARISON SUMMARY  (router total vs. PropAMM-direct baseline)")
    print("=" * 84)
    if not ok:
        print("No successfully decomposed swaps.")
        return

    by_venue: dict[str, list[dict]] = defaultdict(list)
    for r in ok:
        by_venue[r["venue_name"]].append(r)

    def line(label: str, rs: list[dict]) -> str:
        return (
            f"{label:<16}{len(rs):>4}"
            f"{avg([r['total_gas'] for r in rs]):>12,.0f}"
            f"{avg([r['inner_swap_gas'] for r in rs]):>12,.0f}"
            f"{avg([r['premium_vs_raw_swap_gas'] for r in rs]):>13,.0f}"
            f"{avg([r['premium_vs_direct_gas'] for r in rs]):>13,.0f}"
            f"{avg([float(r['premium_vs_direct_pct']) for r in rs]):>9.1f}%"
        )

    hdr = (
        f"{'venue':<16}{'n':>4}{'avg total':>12}{'avg inner':>12}"
        f"{'prem(raw)':>13}{'prem(direct)':>13}{'prem %':>10}"
    )
    print("\n" + hdr)
    print("-" * len(hdr))
    for venue, rs in sorted(by_venue.items()):
        print(line(venue, rs))
    print("-" * len(hdr))
    print(line("ALL", ok))
    print(
        "\nReading: 'avg inner' = gas the PropAMM swap() itself burns (the direct\n"
        "execution). 'prem(raw)' = total - inner (gross overhead). 'prem(direct)' =\n"
        "overhead vs a realistic direct call (inner + one token transfer + 21k\n"
        "intrinsic). NOTE: callTracer subcall gas is gross while the tx total is net\n"
        "of EIP-3529 refunds, so the exact split carries ~10k gas of uncertainty;\n"
        "total_gas and inner_swap_gas are the firm anchors."
    )


if __name__ == "__main__":
    sys.exit(main())
