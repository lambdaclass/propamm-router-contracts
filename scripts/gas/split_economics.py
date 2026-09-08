#!/usr/bin/env python3
"""Re-run the onchain-split gas and economics analysis, and emit a CSV.

Two kinds of number come out of this, and they age very differently:

  * DURABLE    - gas per mechanism. Set by bytecode, fine to measure once, and
                 the right thing to assert against in CI.
  * PERISHABLE - venue depth and basis-point advantage. Set by market makers.
                 Fermi's usable depth moved ~3.6x in 17 hours, so a single
                 reading is not evidence; these need re-running and trending.

What it runs
  An anvil fork at head (or --block) for the real-venue gas, plus a
  multi-block sweep for depth/edge straight against the RPC.

Output: scripts/gas/split_economics_<runId>.csv, one row per metric, plus a
printed summary. Re-run it and diff the CSVs to see what moved.

Env: ETH_RPC_URL (or RPC_URL) - an archive node. Required.
Stdlib only, per this directory's convention.
"""
import argparse
import csv
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = Path(__file__).resolve().parent
RESULT_RE = re.compile(r"RESULT\|([A-Za-z0-9_]+)\|(\d+)")

# metric -> (durability, human label)
META = {
    "samples": ("meta", "blocks sampled"),
    "span_blocks": ("meta", "sweep span, blocks"),
    "head_block": ("meta", "head block"),
    "fermi_lane_recoverable": ("perishable", "blocks where Fermi's lane was recoverable"),
    "natural_fresh_ge1": ("perishable", "blocks with >=1 venue naturally quotable"),
    "natural_fresh_ge2": ("perishable", "blocks with >=2 venues naturally quotable"),
    "fermi_depth_median_usdc6": ("perishable", "median Fermi depth (USDC, 6dp)"),
    "fermi_edge_1m_bp_median": ("perishable", "median Fermi edge at 1M (bp)"),
    "gas_viaVenue_fermi": ("durable", "swapViaVenueV1 -> Fermi"),
    "gas_viaVenue_uniswap": ("durable", "swapViaVenueV1 -> Uniswap V3"),
    "gas_swapV1": ("durable", "swapV1 (quotes whole whitelist)"),
}


def sh(cmd, env=None, timeout=None, quiet=False):
    if not quiet:
        shown = " ".join(cmd[:6]) + (" ..." if len(cmd) > 6 else "")
        print("  $ " + shown, flush=True)
    merged = dict(os.environ)
    merged.update(env or {})
    return subprocess.run(cmd, cwd=ROOT, env=merged, capture_output=True, text=True, timeout=timeout)


def classify(metric):
    """Durability + label for a metric, by exact match then by prefix.

    Prefix rules matter: anything venue-derived is PERISHABLE even though it
    comes out of the same run as the gas numbers. Per-venue depth moves in
    hours, and how many legs the split actually admits depends on live prices,
    so filing either under "durable" would be actively misleading.
    """
    if metric in META:
        return META[metric]
    if metric.startswith("depth_usdc6_venue"):
        return ("perishable", "usable depth, venue #%s (USDC, 6dp)" % metric[len("depth_usdc6_venue"):])
    if metric.startswith("split_events_n"):
        n = metric[len("split_events_n"):]
        return ("perishable", "Swapped events the split produced, %s venues" % n)
    if metric.startswith("gas_"):
        return ("durable", metric[4:].replace("_", " "))
    # Deliberately NOT "durable": a new metric nobody has classified should
    # show up as unclassified rather than be silently asserted to be stable.
    return ("unknown", metric)


def harvest(text):
    return {k: int(v) for k, v in RESULT_RE.findall(text)}


def require(tool):
    if not shutil.which(tool):
        sys.exit("error: `%s` not found on PATH" % tool)


def start_anvil(rpc, block, port):
    require("anvil")
    cmd = ["anvil", "--fork-url", rpc, "--port", str(port), "--silent"]
    if block:
        cmd += ["--fork-block-number", str(block)]
    where = ("@ block %d" % block) if block else "@ head"
    print("  starting anvil on :%d %s" % (port, where), flush=True)
    proc = subprocess.Popen(cmd, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    local = "http://127.0.0.1:%d" % port
    for _ in range(30):
        time.sleep(1)
        r = sh(["cast", "block-number", "--rpc-url", local], quiet=True)
        if r.returncode == 0 and r.stdout.strip().isdigit():
            print("  anvil up at block %s" % r.stdout.strip(), flush=True)
            return proc, local
        if proc.poll() is not None:
            sys.exit("error: anvil exited during startup (bad RPC URL?)")
    stop_anvil(proc)
    sys.exit("error: anvil did not become ready in 30s")


def stop_anvil(proc):
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--block", type=int, help="pin the anvil fork to this block (default: head)")
    ap.add_argument("--samples", type=int, default=10, help="blocks in the depth sweep (default 10)")
    ap.add_argument("--step", type=int, default=720, help="blocks between samples (default 720, ~2.4h)")
    ap.add_argument("--port", type=int, default=8545, help="anvil port (default 8545)")
    ap.add_argument("--no-sweep", action="store_true", help="skip the slow multi-block depth sweep")
    ap.add_argument("--out", help="output CSV (default: scripts/gas/split_economics_<runId>.csv)")
    args = ap.parse_args()

    require("forge")
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = Path(args.out) if args.out else OUT_DIR / ("split_economics_%s.csv" % run_id)
    results = {}

    rpc = os.environ.get("ETH_RPC_URL") or os.environ.get("RPC_URL")
    if not rpc:
        sys.exit("error: set ETH_RPC_URL (or RPC_URL) to an archive node")

    print("\n[1/2] real-venue gas on an anvil fork")
    proc, local = start_anvil(rpc, args.block, args.port)
    try:
        for name in ("test_allMethodsSameOrder", "test_capacityRecheck"):
            rr = sh(["forge", "test", "--match-test", name, "-vv"],
                    env={"RPC_URL": local}, timeout=1800)
            got = harvest(rr.stdout)
            if not got:
                why = "failed" if rr.returncode else "no venue quotable?"
                print("  warning: %s produced no RESULT lines (%s)" % (name, why))
            results.update(got)
            print("  %s: %d metrics" % (name, len(got)))
    finally:
        stop_anvil(proc)
        print("  anvil stopped")

    if args.no_sweep:
        print("\n[2/2] skipped (--no-sweep)")
    else:
        print("\n[2/2] depth/edge sweep: %d blocks, step %d (direct RPC, slow)"
              % (args.samples, args.step))
        rr = sh(["forge", "test", "--match-path", "test/DepthSamplerFork.t.sol", "-vv"],
                env={"RPC_URL": rpc, "SAMPLES": str(args.samples), "STEP": str(args.step)},
                timeout=5400)
        got = harvest(rr.stdout)
        if not got:
            why = "failed" if rr.returncode else "unexpected"
            print("  warning: sweep produced no RESULT lines (%s)" % why)
        results.update(got)
        print("  ok - %d metrics" % len(got))

    rows = []
    for k, v in results.items():
        dur, label = classify(k)
        rows.append({"run_id": run_id, "metric": k, "value": v, "durability": dur, "label": label})

    with open(out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["run_id", "metric", "value", "durability", "label"])
        w.writeheader()
        w.writerows(rows)

    bar = "=" * 72
    try:
        shown_out = out.resolve().relative_to(ROOT)
    except ValueError:
        shown_out = out  # --out may point outside the repo; show it as given
    print("\n%s\nrun %s -> %s\n%s" % (bar, run_id, shown_out, bar))
    for dur in ("meta", "durable", "perishable", "unknown"):
        group = [x for x in rows if x["durability"] == dur]
        if not group:
            continue
        note = " (re-run these; they age in hours)" if dur == "perishable" else ""
        print("\n%s%s" % (dur.upper(), note))
        for x in sorted(group, key=lambda y: y["metric"]):
            print("  %16s  %-26s %s" % ("{:,}".format(x["value"]), x["metric"], x["label"]))
    print()
    if not rows:
        sys.exit("error: no metrics collected")


if __name__ == "__main__":
    main()
