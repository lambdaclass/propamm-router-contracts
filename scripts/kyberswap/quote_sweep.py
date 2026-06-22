#!/usr/bin/env python3
"""Sweep KyberSwap aggregator quotes for WETH/USDC and USDC/WETH across sizes.

For each trade direction and size we hit the KyberSwap aggregator `/routes`
endpoint repeatedly and record what route the aggregator picks. The goal is to
see *to what we get routed* and how stable that routing is across identical
back-to-back requests.

Uses only the Python standard library (urllib/csv/json) so there is nothing to
`pip install`.

Docs: https://docs.kyberswap.com/developer-guide/aggregator-api

Example:
    python3 scripts/kyberswap/quote_sweep.py --repeats 20
    python3 scripts/kyberswap/quote_sweep.py --sizes-weth 1,10,100 --repeats 5
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
import time
import urllib.error
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from decimal import Decimal, getcontext
from urllib.parse import urlencode

getcontext().prec = 50  # plenty for 18-decimal base-unit math

# --- Constants -------------------------------------------------------------

API_BASE = "https://aggregator-api.kyberswap.com"

# Mainnet token addresses (mirror sdk/typescript/src/common/tokens.ts).
WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"

DECIMALS = {WETH.lower(): 18, USDC.lower(): 6}

# Known mainnet addresses for readable route summaries. Lowercased keys.
SYMBOLS = {
    "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2": "WETH",
    "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee": "ETH",
    "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": "USDC",
    "0xdac17f958d2ee523a2206206994597c13d831ec7": "USDT",
    "0x6b175474e89094c44da98b954eedeac495271d0f": "DAI",
    "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599": "WBTC",
    "0x853d955acef822db058eb8505911ed77f175b99e": "FRAX",
    "0x5f98805a4e8be255a32880fdec7f6728c6568ba0": "LUSD",
    "0x4c9edd5852cd905f086c759e8383e09bff1e68b3": "USDe",
    "0x83f20f44975d03b1b09e64809b757c47f942beea": "sDAI",
    "0xdc035d45d973e3ec169d2276ddab16f1e407384f": "USDS",
}

DEFAULT_SIZES_WETH = [0.01, 0.1, 1, 10, 100, 1000]
DEFAULT_SIZES_USDC = [10, 100, 1000, 10000, 100000, 1000000, 10000000]

CSV_FIELDS = [
    "run_id",
    "request_ts",
    "direction",
    "token_in",
    "token_out",
    "amount_in_human",
    "amount_in_raw",
    "sample_idx",
    "http_status",
    "latency_ms",
    "amount_out_human",
    "amount_out_raw",
    "amount_in_usd",
    "amount_out_usd",
    "effective_price",
    "price_impact_pct",
    "gas_estimate",
    "gas_usd",
    "num_splits",
    "max_hops",
    "route_dexes",
    "route_summary",
    "router_address",
    "error",
]


# --- Helpers ---------------------------------------------------------------


def sym(addr: str) -> str:
    """Human-readable token symbol, falling back to a shortened address."""
    if not addr:
        return "?"
    low = addr.lower()
    if low in SYMBOLS:
        return SYMBOLS[low]
    return addr[:6] + "…" + addr[-4:]


def to_base_units(amount_human: float, decimals: int) -> int:
    """Convert a human amount to integer base units without float drift."""
    return int((Decimal(str(amount_human)) * (Decimal(10) ** decimals)).to_integral_value())


def from_base_units(amount_raw: str | int, decimals: int) -> Decimal:
    return Decimal(str(amount_raw)) / (Decimal(10) ** decimals)


def summarize_route(route: list, decimals_in: int, amount_in_raw: int) -> tuple[int, int, str, str]:
    """Return (num_splits, max_hops, route_dexes, route_summary)."""
    if not route:
        return 0, 0, "", ""
    num_splits = len(route)
    max_hops = max((len(split) for split in route), default=0)

    dexes: list[str] = []
    split_strs: list[str] = []
    for split in route:
        if not split:
            continue
        # Portion of the input this split consumes (first hop's swapAmount).
        share = ""
        try:
            first_amt = int(split[0].get("swapAmount", 0))
            if amount_in_raw > 0:
                pct = (Decimal(first_amt) / Decimal(amount_in_raw)) * 100
                share = f"{pct:.1f}%:"
        except (ValueError, TypeError):
            pass

        parts = [sym(split[0].get("tokenIn", ""))]
        for hop in split:
            ex = hop.get("exchange", "?")
            if ex not in dexes:
                dexes.append(ex)
            parts.append(f"[{ex}]")
            parts.append(sym(hop.get("tokenOut", "")))
        split_strs.append(share + "→".join(parts))

    return num_splits, max_hops, "|".join(dexes), " || ".join(split_strs)


def build_url(chain: str, token_in: str, token_out: str, amount_in_raw: int) -> str:
    params = {
        "tokenIn": token_in,
        "tokenOut": token_out,
        "amountIn": str(amount_in_raw),
        "gasInclude": "true",
    }
    return f"{API_BASE}/{chain}/api/v1/routes?{urlencode(params)}"


def fetch_route(url: str, client_id: str, timeout: float) -> tuple[int, dict | None, str, float]:
    """Return (http_status, json_data, error, latency_ms)."""
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "x-client-id": client_id,
            "User-Agent": "kyber-quote-sweep/1.0",
        },
    )
    start = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8")
            latency = (time.monotonic() - start) * 1000
            return resp.status, json.loads(body), "", latency
    except urllib.error.HTTPError as e:
        latency = (time.monotonic() - start) * 1000
        try:
            body = e.read().decode("utf-8")
        except Exception:
            body = ""
        return e.code, None, body[:300], latency
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
        latency = (time.monotonic() - start) * 1000
        return 0, None, f"{type(e).__name__}: {e}", latency


def quote_once(
    chain: str,
    direction: str,
    token_in: str,
    token_out: str,
    amount_human: float,
    sample_idx: int,
    run_id: str,
    client_id: str,
    timeout: float,
) -> dict:
    """Perform one quote request and return a CSV-ready row dict."""
    dec_in = DECIMALS[token_in.lower()]
    dec_out = DECIMALS[token_out.lower()]
    amount_in_raw = to_base_units(amount_human, dec_in)
    url = build_url(chain, token_in, token_out, amount_in_raw)

    row = {f: "" for f in CSV_FIELDS}
    row.update(
        run_id=run_id,
        request_ts=datetime.now(timezone.utc).isoformat(),
        direction=direction,
        token_in=sym(token_in),
        token_out=sym(token_out),
        amount_in_human=amount_human,
        amount_in_raw=amount_in_raw,
        sample_idx=sample_idx,
    )

    status, payload, err, latency = fetch_route(url, client_id, timeout)
    # One retry with backoff on rate limit.
    if status == 429:
        time.sleep(2.0)
        status, payload, err, latency = fetch_route(url, client_id, timeout)

    row["http_status"] = status
    row["latency_ms"] = round(latency, 1)

    if payload is None:
        row["error"] = err or f"http {status}"
        return row

    if payload.get("code", 0) != 0:
        row["error"] = f"code {payload.get('code')}: {payload.get('message', '')}"
        return row

    data = payload.get("data", {}) or {}
    summary = data.get("routeSummary", {}) or {}
    row["router_address"] = data.get("routerAddress", "")

    amount_out_raw = summary.get("amountOut", "")
    row["amount_out_raw"] = amount_out_raw
    if amount_out_raw:
        out_human = from_base_units(amount_out_raw, dec_out)
        row["amount_out_human"] = f"{out_human:f}"
        if amount_human:
            row["effective_price"] = f"{(out_human / Decimal(str(amount_human))):f}"

    in_usd = summary.get("amountInUsd", "")
    out_usd = summary.get("amountOutUsd", "")
    row["amount_in_usd"] = in_usd
    row["amount_out_usd"] = out_usd
    try:
        if in_usd and out_usd and Decimal(in_usd) > 0:
            impact = (Decimal(in_usd) - Decimal(out_usd)) / Decimal(in_usd) * 100
            row["price_impact_pct"] = f"{impact:.4f}"
    except Exception:
        pass

    row["gas_estimate"] = summary.get("gas", "")
    row["gas_usd"] = summary.get("gasUsd", "")

    num_splits, max_hops, dexes, route_str = summarize_route(
        summary.get("route", []), dec_in, amount_in_raw
    )
    row["num_splits"] = num_splits
    row["max_hops"] = max_hops
    row["route_dexes"] = dexes
    row["route_summary"] = route_str
    return row


# --- Main ------------------------------------------------------------------


def parse_sizes(raw: str | None, default: list[float]) -> list[float]:
    if not raw:
        return default
    return [float(x.strip()) for x in raw.split(",") if x.strip()]


def main() -> int:
    ap = argparse.ArgumentParser(description="Sweep KyberSwap quotes into a CSV.")
    ap.add_argument("--chain", default="ethereum", help="KyberSwap chain slug (default: ethereum)")
    ap.add_argument("--repeats", type=int, default=20, help="Quotes per (direction, size) (default: 20)")
    ap.add_argument(
        "--workers",
        type=int,
        default=1,
        help="Concurrent in-flight requests (default: 1 = sequential). Higher values are faster but more likely to hit 429 rate limits.",
    )
    ap.add_argument(
        "--delay",
        type=float,
        default=0.25,
        help="Seconds each worker sleeps after a request (default: 0.25). Set 0 for max speed; throttles per worker in both modes.",
    )
    ap.add_argument("--timeout", type=float, default=15.0, help="Per-request timeout seconds (default: 15)")
    ap.add_argument("--client-id", default="router-contracts-research", help="x-client-id header value")
    ap.add_argument("--sizes-weth", help="Comma-separated WETH input sizes (WETH->USDC)")
    ap.add_argument("--sizes-usdc", help="Comma-separated USDC input sizes (USDC->WETH)")
    ap.add_argument(
        "--directions",
        default="both",
        choices=["both", "weth-usdc", "usdc-weth"],
        help="Which direction(s) to quote (default: both)",
    )
    ap.add_argument("--out", help="Output CSV path (default: scripts/kyberswap/kyber_quotes_<runId>.csv)")
    args = ap.parse_args()

    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_path = args.out or f"scripts/kyberswap/kyber_quotes_{run_id}.csv"

    sizes_weth = parse_sizes(args.sizes_weth, DEFAULT_SIZES_WETH)
    sizes_usdc = parse_sizes(args.sizes_usdc, DEFAULT_SIZES_USDC)

    jobs: list[tuple[str, str, str, float]] = []  # (direction, token_in, token_out, amount)
    if args.directions in ("both", "weth-usdc"):
        for s in sizes_weth:
            jobs.append(("WETH->USDC", WETH, USDC, s))
    if args.directions in ("both", "usdc-weth"):
        for s in sizes_usdc:
            jobs.append(("USDC->WETH", USDC, WETH, s))

    total = len(jobs) * args.repeats
    mode = f"{args.workers} workers" if args.workers > 1 else "sequential"
    print(
        f"Run {run_id}: {len(jobs)} (direction,size) combos x {args.repeats} repeats = "
        f"{total} requests ({mode}, delay={args.delay}s/req)"
    )
    print(f"Output -> {out_path}\n")

    # Flatten into individual quote tasks (one row per sample).
    tasks = [
        (direction, tin, tout, amount, i)
        for (direction, tin, tout, amount) in jobs
        for i in range(1, args.repeats + 1)
    ]

    def run_task(task: tuple) -> dict:
        getcontext().prec = 50  # Decimal context is thread-local; re-set per worker.
        direction, tin, tout, amount, i = task
        row = quote_once(
            args.chain, direction, tin, tout, amount, i, run_id, args.client_id, args.timeout
        )
        if args.delay > 0:
            time.sleep(args.delay)
        return row

    rows: list[dict] = []
    done = 0
    with open(out_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        writer.writeheader()

        def record(row: dict) -> None:
            """Write + log a completed row. Main-thread only -> no lock needed."""
            nonlocal done
            writer.writerow(row)
            f.flush()
            rows.append(row)
            done += 1
            status = row["error"] or f"out={row['amount_out_human'] or '-'} splits={row['num_splits']}"
            print(
                f"[{done}/{total}] {row['direction']} "
                f"{str(row['amount_in_human']):<12} #{str(row['sample_idx']):<3} {status}"
            )

        if args.workers <= 1:
            for task in tasks:
                record(run_task(task))
        else:
            with ThreadPoolExecutor(max_workers=args.workers) as ex:
                for fut in as_completed([ex.submit(run_task, t) for t in tasks]):
                    record(fut.result())

    print_summary(rows)
    print(f"\nWrote {len(rows)} rows to {out_path}")
    return 0


def print_summary(rows: list[dict]) -> None:
    """Per (direction, size): distinct routes observed and their frequency."""
    print("\n" + "=" * 80)
    print("ROUTING SUMMARY (distinct route_dexes per direction/size)")
    print("=" * 80)

    groups: dict[tuple[str, str], Counter] = {}
    errors: dict[tuple[str, str], int] = {}
    for r in rows:
        key = (r["direction"], str(r["amount_in_human"]))
        if r["error"]:
            errors[key] = errors.get(key, 0) + 1
            continue
        groups.setdefault(key, Counter())[r["route_dexes"] or "(none)"] += 1

    seen = []
    for r in rows:
        key = (r["direction"], str(r["amount_in_human"]))
        if key not in seen:
            seen.append(key)

    for key in seen:
        direction, size = key
        print(f"\n{direction}  size={size}")
        counter = groups.get(key)
        if counter:
            for route, n in counter.most_common():
                print(f"    {n:>3}x  {route}")
        err = errors.get(key, 0)
        if err:
            print(f"    {err:>3}x  ERROR")


if __name__ == "__main__":
    sys.exit(main())
