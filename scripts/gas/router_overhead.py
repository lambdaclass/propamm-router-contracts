#!/usr/bin/env python3
"""Router gas-overhead comparison: PropAMMRouter vs. direct PropAMM, for the last
N days of mainnet activity. Emits two CSVs (swaps + quotes).

What it answers
---------------
"How much extra gas does routing through our PropAMMRouter cost, versus going
straight to the proprietary AMM, for both *swaps* and *quotes*?"

Two CSVs, because the two operations are measured by fundamentally different
means:

  swaps_<runId>.csv   -- REAL transactions. We enumerate every swap the router
                         fired in the window (the router's own `Swapped` event,
                         whose `marketMaker` field is the venue that actually
                         filled, fallback included), read the receipt gas, and
                         `debug_traceTransaction`-decompose it into:
                           * inner_exec_gas   -- the venue frame's own gas
                           * pull_in / delivery transfers
                           * router_overhead_gas -- everything else
                         and report the premium vs. a realistic direct call.

  quotes_<runId>.csv  -- SIMULATED. Quotes are gasless off-chain `eth_call`s in
                         production, so there are no historical quote txs to read.
                         For each discovered swap we take its (venue, pair, amount)
                         and, AT THAT SWAP'S BLOCK (where the venue is live -- a
                         plain quote at `latest` would falsely revert or silently
                         fall back to Uniswap; see the propamm-swap-presim memory),
                         `debug_traceCall` both:
                           * quoteVenueV1(venue, ...) on the router
                           * the venue's native quote() / quoteAmounts() directly
                         The premium is router_quote_gas - direct_quote_gas.

Cold/warm note: the venue's quote, called *standalone*, pays EIP-2929 cold
access costs that the same call nested inside the router does not (the router
pre-warms slots). So the headline `direct_quote_gas` is the STANDALONE call
(what a real direct integrator pays); the warm nested frame is recorded
separately as `router_inner_venue_quote_gas` for diagnostics. The same warm
discount affects `inner_exec_gas` in swaps.csv -- it slightly *under*-counts a
true standalone direct swap; `total_gas` is the firm anchor.

Stdlib only -- nothing to `pip install`. Needs an archive RPC with
`debug_traceTransaction` + `debug_traceCall` (callTracer); ETH_RPC_URL.
Falls back to `eth_estimateGas` for quotes if `debug_traceCall` is unavailable.

Example:
    ETH_RPC_URL=... python3 scripts/gas/router_overhead.py                 # last 3 days
    python3 scripts/gas/router_overhead.py --start-block 25300000          # from block -> latest
    python3 scripts/gas/router_overhead.py --start-block 25300000 --to-block 25320000
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
import urllib.request
from collections import defaultdict
from datetime import datetime, timezone
from decimal import Decimal

# --- Constants -------------------------------------------------------------

ROUTER = "0x4DdF368080CD7946db5b459aD591c350158175e1"  # PropAMMRouter (demo env)

# Router's OWN Swapped(address,address,address,uint256,uint256,address,address).
# `marketMaker` (last data word) is the venue that actually filled -- fallback
# included -- so this is a better discovery key than the venue event.
ROUTER_SWAPPED_TOPIC = "0xfc01a2d4af46d04923f77211f1c96af350517eee1a9fc8fd3e7e1a8b78bab17f"

# Router entrypoints (tx selector -> name), for the `function` column.
ROUTER_FNS = {
    "0x1037acb3": "swapV1",
    "0xd4a41dda": "swapWithFeeV1",
    "0x82fc5493": "swapViaVenueV1",
    "0xca775698": "swapViaVenueWithFeeV1",
    "0xf7890e1d": "swapViaSelectedVenuesV1",
    "0xcc38d822": "swapViaSelectedVenuesWithFeeV1",
}

# Quote/transfer selectors (4-byte).
SEL_QUOTE_VENUE = "0x221ee81f"   # quoteVenueV1(address,address,address,uint256)
SEL_QUOTE = "0xb6466384"         # quote(address,address,uint256) (IPropAMM/Bebop)
SEL_QUOTE_AMOUNTS = "0x300aa47f"  # quoteAmounts(address,address,int256) (Fermi builtin)
SEL_TRANSFER = "0xa9059cbb"      # transfer(address,uint256)
SEL_TRANSFER_FROM = "0x23b872dd"  # transferFrom(address,address,uint256)

INTRINSIC_GAS = 21000  # base tx cost a direct caller would also pay

FROM_ADDR = "0x000000000000000000000000000000000000f00d"  # synthetic caller for sims

# Known venue / fallback addresses (lowercased). The router treats the two
# "builtin" consts specially (bespoke quoters); every other whitelisted venue
# speaks the common IPropAMM.quote interface.
FERMI_BUILTIN = "0xb1076fe3ab5e28005c7c323bac5ac06a680d452e"
BEBOP_BUILTIN = "0x160141a205f5ddcf096ba3f48b7ed21eb52c62ea"
UNISWAP_FALLBACK = "0x68b3465833fb72a70ecdf485e0e4c7bd8665fc45"  # UniV3 SwapRouter02

# The router accepts a sentinel for native ETH and converts it to WETH internally
# (see PropAMMRouter quote/swap paths). A direct integrator would wrap first, so we
# normalize the sentinel to WETH for the *direct* venue quote to keep it apples-to-apples.
ETH_SENTINEL = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
WETH_ADDR = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"

VENUE_NAMES = {
    "0x5979458912f80b96d30d4220af8e2e4925a33320": "Fermi (new)",
    FERMI_BUILTIN: "Fermi (builtin)",
    "0x71e790dd841c8a9061487cb3e78c288e75ce0b3d": "Kipseli",
    "0xccdda3258aa079ce45e6aa6f35829a6612eb7c45": "Kipseli (alt)",
    "0xdb13ad0fcd134e9c48f2fdaea8f6751a0f5349ca": "Bebop (new)",
    BEBOP_BUILTIN: "Bebop (builtin)",
    UNISWAP_FALLBACK: "Uniswap V3 (fallback)",
}

# The three PropAMMs the user wants compared (lowercased) -> name.
NAMED_VENUES = {
    "0x5979458912f80b96d30d4220af8e2e4925a33320": "Fermi",
    "0x71e790dd841c8a9061487cb3e78c288e75ce0b3d": "Kipseli",
    "0xdb13ad0fcd134e9c48f2fdaea8f6751a0f5349ca": "Bebop",
}

SYMBOLS = {
    "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2": ("WETH", 18),
    "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": ("USDC", 6),
    "0xdac17f958d2ee523a2206206994597c13d831ec7": ("USDT", 6),
    "0x6b175474e89094c44da98b954eedeac495271d0f": ("DAI", 18),
    "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599": ("WBTC", 8),
}

SWAP_FIELDS = [
    "run_id", "txhash", "block", "timestamp", "age_days", "function",
    "tx_to", "direct_router_call",
    "executed_venue", "venue_name", "token_in", "token_out",
    "amount_in_human", "amount_out_human", "status",
    "total_gas", "inner_exec_gas", "pull_in_transfer_gas", "delivery_transfer_gas",
    "router_overhead_gas", "premium_vs_raw_gas", "premium_vs_raw_pct",
    "direct_baseline_gas", "premium_vs_direct_gas", "premium_vs_direct_pct",
    "effective_gas_price_gwei", "total_cost_eth", "premium_vs_direct_cost_eth", "note",
]

QUOTE_FIELDS = [
    "run_id", "source_txhash", "block", "timestamp", "age_days",
    "executed_venue", "venue_name", "token_in", "token_out", "amount_in_human",
    "router_quote_gas", "direct_quote_gas", "router_inner_venue_quote_gas",
    "premium_quote_gas", "premium_quote_pct",
    "router_quote_out", "direct_quote_out", "quotes_match", "method", "note",
]


# --- JSON-RPC --------------------------------------------------------------


def rpc(url: str, method: str, params: list, timeout: float = 90.0) -> object:
    """Single JSON-RPC call. Raises RuntimeError on an RPC-level error."""
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    req = urllib.request.Request(
        url, data=body.encode(), headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        payload = json.loads(resp.read().decode())
    if "error" in payload:
        raise RuntimeError(f"{method} -> {payload['error']}")
    return payload["result"]


def rpc_try(url: str, method: str, params: list, timeout: float = 90.0):
    """Like rpc() but returns (result, error_str) instead of raising."""
    try:
        return rpc(url, method, params, timeout), ""
    except Exception as e:  # noqa: BLE001
        return None, str(e)


def hx(v) -> int:
    return int(v, 16) if v else 0


# --- ABI encode/decode helpers (hand-rolled; no cast dependency) -----------


def enc_addr(a: str) -> str:
    return a.lower().replace("0x", "").rjust(64, "0")


def enc_uint(n: int) -> str:
    if n < 0:  # two's complement for int256 (Fermi quoteAmounts; we only use >=0)
        n += 1 << 256
    return format(n, "064x")


def topic_addr(topic: str) -> str:
    return "0x" + topic[-40:]


def word(data_hex: str, i: int) -> str:
    """i-th 32-byte word of a 0x-stripped data string."""
    return data_hex[i * 64:(i + 1) * 64]


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


def pct(num: int, den: int) -> str:
    return f"{(Decimal(num) / Decimal(den) * 100):.1f}" if den else ""


# --- Window discovery ------------------------------------------------------


def block_at_timestamp(url: str, target_ts: int, latest: int) -> int:
    """Binary-search the lowest block whose timestamp >= target_ts."""
    lo, hi = 1, latest
    while lo < hi:
        mid = (lo + hi) // 2
        blk = rpc(url, "eth_getBlockByNumber", [hex(mid), False])
        if hx(blk["timestamp"]) < target_ts:
            lo = mid + 1
        else:
            hi = mid
    return lo


def find_router_swaps(url: str, router: str, from_block: int, to_block: int, window: int) -> list:
    """Enumerate router swaps via the router's own Swapped event."""
    found: dict[str, dict] = {}
    start = from_block
    while start <= to_block:
        end = min(start + window - 1, to_block)
        logs = rpc(url, "eth_getLogs", [{
            "fromBlock": hex(start), "toBlock": hex(end),
            "address": router, "topics": [ROUTER_SWAPPED_TOPIC],
        }])
        for lg in logs:
            tx = lg["transactionHash"]
            if tx in found:
                continue
            data = lg["data"][2:]
            found[tx] = {
                "txhash": tx,
                "block": hx(lg["blockNumber"]),
                "token_in": topic_addr(lg["topics"][2]),
                "token_out": topic_addr(lg["topics"][3]),
                "amount_in": int(word(data, 0), 16) if len(data) >= 64 else 0,
                "amount_out": int(word(data, 1), 16) if len(data) >= 128 else 0,
                "market_maker": topic_addr(word(data, 3)) if len(data) >= 256 else "",
            }
        print(f"  scanned {start}-{end}: {len(logs)} logs, {len(found)} swaps so far")
        start = end + 1
    # Stable order: by block then txhash.
    return sorted(found.values(), key=lambda r: (r["block"], r["txhash"]))


# --- Swap trace decomposition ----------------------------------------------


def decompose_swap(trace: dict, market_maker: str) -> dict:
    """Split a callTracer tree into the venue frame, the router's transfers, and
    the remainder. `inner_exec_gas` = the heaviest state-changing (non-quote) CALL
    to `market_maker`.

    The best-venue / selected-venue entrypoints re-quote the executed venue during
    selection (`_pickBestVenue` -> the venue's quote/quoteAmounts), producing a
    SECOND `to == market_maker` frame. We must not let that quote frame win
    `inner_exec_gas`, so we exclude (a) STATICCALL frames (the builtins' quoters are
    `view`) and (b) the quote selectors (a generic IPropAMM.quote is non-`view`, so
    it is a CALL). A swap is always a state-changing CALL with a non-quote selector."""
    out = {"inner_exec_gas": 0, "pull_in_transfer_gas": 0,
           "delivery_transfer_gas": 0, "other_transfer_gas": 0, "venue_frames": 0}
    mm = market_maker.lower()

    def walk(node: dict, in_venue: bool) -> None:
        inp = (node.get("input") or "")[:10]
        gas = hx(node.get("gasUsed"))
        to = (node.get("to") or "").lower()
        typ = node.get("type", "")

        child_in_venue = in_venue
        is_venue_swap = (
            not in_venue and to == mm and typ in ("CALL", "CALLCODE")
            and inp not in (SEL_QUOTE, SEL_QUOTE_AMOUNTS)
        )
        if is_venue_swap:
            # The venue's own swap execution. Keep the heaviest one.
            out["venue_frames"] += 1
            if gas > out["inner_exec_gas"]:
                out["inner_exec_gas"] = gas
            child_in_venue = True
        elif not in_venue and typ == "CALL" and inp in (SEL_TRANSFER, SEL_TRANSFER_FROM):
            # Router-level token movements (outside the venue subtree).
            if inp == SEL_TRANSFER_FROM:
                out["pull_in_transfer_gas"] += gas
            else:
                args = node.get("input", "")
                recipient = ("0x" + args[34:74]).lower() if len(args) >= 74 else ""
                if recipient == mm:
                    out["delivery_transfer_gas"] += gas
                else:
                    out["other_transfer_gas"] += gas

        for c in node.get("calls", []) or []:
            walk(c, child_in_venue)

    walk(trace, False)
    return out


def analyze_swap(url: str, sw: dict, run_id: str, now_ts: int, router: str) -> dict:
    row = {f: "" for f in SWAP_FIELDS}
    ti, to = sw["token_in"], sw["token_out"]
    mm = sw["market_maker"]
    row.update(
        run_id=run_id, txhash=sw["txhash"], block=sw["block"],
        executed_venue=mm, venue_name=venue_name(mm),
        token_in=sym(ti), token_out=sym(to),
        amount_in_human=human(sw["amount_in"], ti),
        amount_out_human=human(sw["amount_out"], to),
    )

    receipt = rpc(url, "eth_getTransactionReceipt", [sw["txhash"]])
    tx = rpc(url, "eth_getTransactionByHash", [sw["txhash"]])
    blk = rpc(url, "eth_getBlockByNumber", [hex(sw["block"]), False])
    trace = rpc(url, "debug_traceTransaction", [sw["txhash"], {"tracer": "callTracer"}])

    ts = hx(blk["timestamp"])
    row["timestamp"] = ts
    row["age_days"] = f"{(now_ts - ts) / 86400:.2f}"
    total = hx(receipt.get("gasUsed"))
    gas_price = hx(receipt.get("effectiveGasPrice"))
    row["status"] = "ok" if receipt.get("status") == "0x1" else "reverted"
    row["function"] = ROUTER_FNS.get((tx.get("input") or "")[:10], (tx.get("input") or "")[:10])
    tx_to = (tx.get("to") or "")
    row["tx_to"] = tx_to
    # The swap is discovered via the router's Swapped event, which also fires when
    # the router is called by another contract. Only when the tx's top-level `to`
    # IS the router does `total_gas` measure the router swap itself; otherwise it is
    # the whole outer (wrapper/keeper) tx and the swap premiums are not meaningful.
    direct = tx_to.lower() == router.lower()
    row["direct_router_call"] = "yes" if direct else "no"
    row["total_gas"] = total
    row["effective_gas_price_gwei"] = f"{Decimal(gas_price) / Decimal(10**9):f}" if gas_price else ""

    d = decompose_swap(trace, mm)
    inner = d["inner_exec_gas"]
    pull_in = d["pull_in_transfer_gas"]
    delivery = d["delivery_transfer_gas"]
    plumbing = pull_in + delivery + d["other_transfer_gas"]

    row["inner_exec_gas"] = inner
    row["pull_in_transfer_gas"] = pull_in
    row["delivery_transfer_gas"] = delivery

    notes = []
    # Swap premiums are only meaningful when total_gas IS the router swap, i.e. the
    # tx called the router directly. For wrapper/keeper txs total_gas is the whole
    # outer tx, so we keep inner_exec (a valid frame) but omit the premium columns.
    if not direct:
        notes.append(f"wrapper tx (to={tx_to[:10]}… ≠ router); total_gas is outer tx, swap premiums omitted")
    elif inner:
        overhead = total - inner - plumbing
        row["router_overhead_gas"] = overhead
        prem_raw = total - inner
        row["premium_vs_raw_gas"] = prem_raw
        row["premium_vs_raw_pct"] = pct(prem_raw, inner)
        baseline = inner + delivery + INTRINSIC_GAS
        prem_dir = total - baseline
        row["direct_baseline_gas"] = baseline
        row["premium_vs_direct_gas"] = prem_dir
        row["premium_vs_direct_pct"] = pct(prem_dir, baseline)
        if gas_price:
            row["premium_vs_direct_cost_eth"] = f"{Decimal(prem_dir) * Decimal(gas_price) / Decimal(10**18):f}"
        if d["venue_frames"] > 1:
            notes.append(f"{d['venue_frames']} venue swap frames; inner_exec=heaviest")
        if delivery == 0:
            # Allowance/pull venues (e.g. builtin Fermi: forceApprove +
            # fermiSwapWithAllowances) do no push-transfer to the venue, so the
            # approval gas lands in router_overhead and the direct baseline omits it.
            notes.append("no push-transfer to venue (allowance/pull model); baseline excludes approval gas")
        if overhead < 0:
            # callTracer subcomponents are GROSS; receipt total is NET of EIP-3529
            # refunds, so the residual bucket can go slightly negative on refund-heavy
            # venues. total_gas / inner_exec_gas are the firm anchors.
            notes.append("router_overhead<0: gross subcomponents exceed net total (EIP-3529 refund artifact)")
    else:
        notes.append(f"no venue frame (to={mm[:10]}…) found in trace")
    row["note"] = "; ".join(notes)

    if gas_price:
        row["total_cost_eth"] = f"{Decimal(total) * Decimal(gas_price) / Decimal(10**18):f}"
    return row


# --- Quote simulation ------------------------------------------------------


def native_quote(venue: str, ti: str, to: str, amount: int):
    """Calldata + output-word index + a label for the venue's own quote fn.

    Returns (calldata, out_word_index) or (None, None) if the venue has no clean
    standalone direct quote (the Uniswap fallback -- handled separately)."""
    v = venue.lower()
    if v == FERMI_BUILTIN:
        # quoteAmounts(address,address,int256) -> (amountIn, amountOut); want word 1.
        return SEL_QUOTE_AMOUNTS + enc_addr(ti) + enc_addr(to) + enc_uint(amount), 1
    if v == UNISWAP_FALLBACK:
        return None, None
    # Bebop builtin + every generic whitelisted IPropAMM venue.
    return SEL_QUOTE + enc_addr(ti) + enc_addr(to) + enc_uint(amount), 0


def trace_call(url: str, to: str, data: str, block: int):
    """debug_traceCall (callTracer). Returns (gasUsed, output_hex, trace, error).

    A reverting EVM call is NOT a JSON-RPC error: callTracer returns a normal
    result whose top frame carries an `error` field ("execution reverted"). We
    surface that as the error so callers don't score a reverted call as a quote."""
    res, err = rpc_try(url, "debug_traceCall", [
        {"from": FROM_ADDR, "to": to, "data": data}, hex(block), {"tracer": "callTracer"},
    ])
    if res is None:
        return None, "", None, err
    top_err = res.get("error")
    if top_err:
        return hx(res.get("gasUsed")), (res.get("output") or ""), res, str(top_err)
    return hx(res.get("gasUsed")), (res.get("output") or ""), res, ""


def estimate_gas(url: str, to: str, data: str, block: int):
    res, err = rpc_try(url, "eth_estimateGas", [
        {"from": FROM_ADDR, "to": to, "data": data}, hex(block)])
    if res is None:
        return None, err
    return hx(res), ""


def inner_frame_gas(trace: dict, target: str) -> int:
    """Heaviest gasUsed among frames whose `to == target` in a callTracer tree."""
    best = 0
    t = target.lower()

    def walk(n: dict) -> None:
        nonlocal best
        if (n.get("to") or "").lower() == t:
            best = max(best, hx(n.get("gasUsed")))
        for c in n.get("calls", []) or []:
            walk(c)

    walk(trace)
    return best


def deepest_subcall_gas(trace: dict) -> int:
    """Heaviest gasUsed among all *sub*-frames (used for the Uniswap fallback,
    whose quote runs on a quoter contract != marketMaker)."""
    best = 0

    def walk(n: dict, depth: int) -> None:
        nonlocal best
        if depth > 0:
            best = max(best, hx(n.get("gasUsed")))
        for c in n.get("calls", []) or []:
            walk(c, depth + 1)

    walk(trace, 0)
    return best


def analyze_quote(url: str, sw: dict, run_id: str, now_ts: int, use_estimate: bool) -> dict:
    row = {f: "" for f in QUOTE_FIELDS}
    ti, to = sw["token_in"], sw["token_out"]
    mm = sw["market_maker"]
    amount = sw["amount_in"]
    block = sw["block"]
    blk = rpc(url, "eth_getBlockByNumber", [hex(block), False])
    ts = hx(blk["timestamp"])
    row.update(
        run_id=run_id, source_txhash=sw["txhash"], block=block, timestamp=ts,
        age_days=f"{(now_ts - ts) / 86400:.2f}",
        executed_venue=mm, venue_name=venue_name(mm),
        token_in=sym(ti), token_out=sym(to), amount_in_human=human(amount, ti),
        method="eth_estimateGas" if use_estimate else "debug_traceCall",
    )

    notes = []
    # The router converts the ETH sentinel to WETH internally; a direct integrator
    # would wrap first, so normalize it for the direct call only (the router call
    # keeps the original tokens, matching real router usage).
    ti_d = WETH_ADDR if ti.lower() == ETH_SENTINEL else ti
    to_d = WETH_ADDR if to.lower() == ETH_SENTINEL else to
    if (ti_d, to_d) != (ti, to):
        notes.append("ETH sentinel normalized to WETH for direct quote")

    router_data = SEL_QUOTE_VENUE + enc_addr(mm) + enc_addr(ti) + enc_addr(to) + enc_uint(amount)
    direct_data, out_idx = native_quote(mm, ti_d, to_d, amount)

    if use_estimate:
        rg, rerr = estimate_gas(url, ROUTER, router_data, block)
        row["router_quote_gas"] = rg if rg is not None else ""
        if rerr:
            notes.append(f"router est: {rerr[:60]}")
        if direct_data is not None:
            dg, derr = estimate_gas(url, mm, direct_data, block)
            row["direct_quote_gas"] = dg if dg is not None else ""
            if derr:
                notes.append(f"direct est: {derr[:60]}")
        else:
            notes.append("uniswap fallback: no standalone direct estimate")
    else:
        rg, rout, rtrace, rerr = trace_call(url, ROUTER, router_data, block)
        if rerr:
            # A reverted router quote is not a measurement; record nothing.
            notes.append(f"router quote failed: {rerr[:60]}")
            rtrace = None
        else:
            row["router_quote_gas"] = rg
            if rout and len(rout) >= 66:
                row["router_quote_out"] = int(rout[2:66], 16)
            if rtrace is not None:
                row["router_inner_venue_quote_gas"] = inner_frame_gas(rtrace, mm) or ""

        if direct_data is not None:
            dg, dout, _, derr = trace_call(url, mm, direct_data, block)
            if derr:
                # Venue quote reverted standalone (e.g. inactive at this block, or
                # not the assumed interface). Leave direct blank -> no premium, so
                # the row is excluded from summary averages.
                notes.append(f"direct quote failed: {derr[:60]}")
            else:
                row["direct_quote_gas"] = dg
                d = (dout or "")[2:]
                if len(d) >= (out_idx + 1) * 64:
                    row["direct_quote_out"] = int(word(d, out_idx), 16)
        elif rtrace is not None:
            # Uniswap fallback: no standalone propAMM quote. Approximate the direct
            # cost with the heaviest quoter subcall; leave direct_quote_out blank so
            # quotes_match stays unknown (it is not a true same-output comparison).
            row["direct_quote_gas"] = deepest_subcall_gas(rtrace) or ""
            notes.append("uniswap fallback: direct = quoter subcall (approx); no output match")

    rg_v = row["router_quote_gas"]
    dg_v = row["direct_quote_gas"]
    if isinstance(rg_v, int) and isinstance(dg_v, int) and dg_v:
        prem = rg_v - dg_v
        row["premium_quote_gas"] = prem
        row["premium_quote_pct"] = pct(prem, dg_v)
    if isinstance(row["router_quote_out"], int) and isinstance(row["direct_quote_out"], int):
        row["quotes_match"] = "yes" if row["router_quote_out"] == row["direct_quote_out"] else "NO"
    row["note"] = "; ".join(notes)
    return row


# --- Main ------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description="Router vs direct PropAMM gas overhead (swaps + quotes).")
    ap.add_argument("--rpc", default=os.environ.get("ETH_RPC_URL", ""), help="RPC URL (default $ETH_RPC_URL)")
    ap.add_argument("--router", default=ROUTER, help=f"Router address (default {ROUTER})")
    ap.add_argument("--start-block", "--from-block", dest="from_block", type=int, default=0,
                    help="Start block: analyze from here to --to-block (latest). Overrides --days.")
    ap.add_argument("--to-block", type=int, default=0, help="End block (default 0 = latest)")
    ap.add_argument("--days", type=float, default=3.0,
                    help="Lookback window in days; used only when --start-block is not given (default 3)")
    ap.add_argument("--window", type=int, default=3000, help="getLogs chunk size (default 3000)")
    ap.add_argument("--max-txs", type=int, default=200, help="Max swaps to analyze (default 200)")
    ap.add_argument("--delay", type=float, default=0.1, help="Seconds between traced txs (default 0.1)")
    ap.add_argument("--out-swaps", help="swaps CSV path (default scripts/gas/swaps_<runId>.csv)")
    ap.add_argument("--out-quotes", help="quotes CSV path (default scripts/gas/quotes_<runId>.csv)")
    args = ap.parse_args()

    if not args.rpc:
        print("ERROR: no RPC URL. Set ETH_RPC_URL or pass --rpc.", file=sys.stderr)
        return 2
    url = args.rpc

    chain_id = hx(rpc(url, "eth_chainId", []))
    if chain_id != 1:
        print(f"WARNING: chainId={chain_id}, expected 1 (mainnet).", file=sys.stderr)

    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_swaps = args.out_swaps or f"scripts/gas/swaps_{run_id}.csv"
    out_quotes = args.out_quotes or f"scripts/gas/quotes_{run_id}.csv"

    latest = hx(rpc(url, "eth_blockNumber", []))
    to_block = args.to_block or latest
    if to_block > latest:
        print(f"WARNING: --to-block {to_block} > latest {latest}; clamping to latest.", file=sys.stderr)
        to_block = latest
    now_ts = hx(rpc(url, "eth_getBlockByNumber", [hex(to_block), False])["timestamp"])
    if args.from_block:
        if args.from_block > to_block:
            print(f"ERROR: --start-block {args.from_block} > end block {to_block}.", file=sys.stderr)
            return 2
        from_block = args.from_block
        window_desc = f"--start-block {from_block}"
    else:
        target = now_ts - int(args.days * 86400)
        from_block = block_at_timestamp(url, target, latest)
        window_desc = f"--days {args.days}"
    from_ts = hx(rpc(url, "eth_getBlockByNumber", [hex(from_block), False])["timestamp"])
    span_days = (now_ts - from_ts) / 86400

    # Probe debug_traceCall once; fall back to eth_estimateGas if unsupported.
    _, _, _, probe_err = trace_call(url, ROUTER, "0x", to_block)
    use_estimate = bool(probe_err) and "method" in probe_err.lower()
    method = "eth_estimateGas (debug_traceCall unavailable)" if use_estimate else "debug_traceCall"

    print(f"Router {args.router}  chainId {chain_id}")
    print(f"Window: blocks {from_block}-{to_block} "
          f"({to_block - from_block + 1:,} blocks, ~{span_days:.2f} days) [{window_desc}]")
    print(f"Quote sim method: {method}\n")

    swaps = find_router_swaps(url, args.router, from_block, to_block, args.window)
    swaps = swaps[: args.max_txs]
    print(f"\nAnalyzing {len(swaps)} router swaps")
    print(f"  swaps  -> {out_swaps}")
    print(f"  quotes -> {out_quotes}\n")

    swap_rows, quote_rows = [], []
    seen_named = set()
    fs = open(out_swaps, "w", newline="")
    fq = open(out_quotes, "w", newline="")
    try:
        sw_writer = csv.DictWriter(fs, fieldnames=SWAP_FIELDS)
        qt_writer = csv.DictWriter(fq, fieldnames=QUOTE_FIELDS)
        sw_writer.writeheader()
        qt_writer.writeheader()

        for i, sw in enumerate(swaps, 1):
            mm = sw["market_maker"].lower()
            if mm in NAMED_VENUES:
                seen_named.add(mm)
            try:
                srow = analyze_swap(url, sw, run_id, now_ts, args.router)
            except Exception as e:  # noqa: BLE001
                srow = {f: "" for f in SWAP_FIELDS}
                srow.update(run_id=run_id, txhash=sw["txhash"], block=sw["block"],
                            executed_venue=sw["market_maker"], note=f"ERROR: {e}")
            try:
                qrow = analyze_quote(url, sw, run_id, now_ts, use_estimate)
            except Exception as e:  # noqa: BLE001
                qrow = {f: "" for f in QUOTE_FIELDS}
                qrow.update(run_id=run_id, source_txhash=sw["txhash"], block=sw["block"],
                            executed_venue=sw["market_maker"], note=f"ERROR: {e}")
            sw_writer.writerow(srow); fs.flush(); swap_rows.append(srow)
            qt_writer.writerow(qrow); fq.flush(); quote_rows.append(qrow)
            tag = "" if srow.get("direct_router_call") == "yes" else " [wrapper]"
            print(
                f"[{i}/{len(swaps)}] {srow.get('venue_name',''):<20}{tag:<10} "
                f"{srow.get('token_in','')}->{srow.get('token_out','')}  "
                f"swap total={srow.get('total_gas','-')} inner={srow.get('inner_exec_gas','-')} "
                f"prem_dir={srow.get('premium_vs_direct_gas','-')} | "
                f"quote R={qrow.get('router_quote_gas','-')} D={qrow.get('direct_quote_gas','-')} "
                f"prem={qrow.get('premium_quote_gas','-')} ({qrow.get('premium_quote_pct','-')}%)"
            )
            if args.delay:
                time.sleep(args.delay)

        # Document any named venue the router never routed to in the window.
        for addr, name in NAMED_VENUES.items():
            if addr not in seen_named:
                note = f"checked: no router routing to {name} ({addr}) in window"
                srow = {f: "" for f in SWAP_FIELDS}
                srow.update(run_id=run_id, executed_venue=addr, venue_name=name, note=note)
                qrow = {f: "" for f in QUOTE_FIELDS}
                qrow.update(run_id=run_id, executed_venue=addr, venue_name=name, note=note)
                sw_writer.writerow(srow); qt_writer.writerow(qrow)
                swap_rows.append(srow); quote_rows.append(qrow)
                print(f"[idle] {name:<20} {note}")
    finally:
        fs.close(); fq.close()

    print_summary(swap_rows, quote_rows)
    print(f"\nWrote {len([r for r in swap_rows if r.get('total_gas')])} swap rows -> {out_swaps}")
    print(f"Wrote {len([r for r in quote_rows if r.get('router_quote_gas') != ''])} quote rows -> {out_quotes}")
    return 0


def avg(xs: list) -> float:
    return sum(xs) / len(xs) if xs else 0.0


def _fpct(rows: list, key: str) -> float:
    vals = [float(r[key]) for r in rows if r.get(key) not in ("", None)]
    return avg(vals)


def print_summary(swap_rows: list, quote_rows: list) -> None:
    # Swap stats use ONLY direct router calls; wrapper/keeper txs (tx.to != router)
    # are counted separately because their total_gas is the whole outer tx.
    sw = [r for r in swap_rows
          if r.get("direct_router_call") == "yes" and isinstance(r.get("premium_vs_direct_gas"), int)]
    wrappers = [r for r in swap_rows if r.get("direct_router_call") == "no"]
    qt = [r for r in quote_rows if isinstance(r.get("premium_quote_gas"), int)]
    print("\n" + "=" * 104)
    print("GAS OVERHEAD SUMMARY  (router vs. direct PropAMM)  — swap stats are DIRECT router calls only")
    print("=" * 104)

    by_venue = defaultdict(lambda: {"sw": [], "qt": []})
    for r in sw:
        by_venue[r["venue_name"]]["sw"].append(r)
    for r in qt:
        by_venue[r["venue_name"]]["qt"].append(r)

    hdr = (f"{'venue':<22}{'n_sw':>5}{'avg total':>11}{'avg inner':>11}"
           f"{'swap prem':>11}{'swap %':>9}{'n_q':>5}{'q router':>10}{'q direct':>10}"
           f"{'q prem':>9}{'q %':>8}")
    print("\n" + hdr)
    print("-" * len(hdr))
    for venue in sorted(by_venue):
        s, q = by_venue[venue]["sw"], by_venue[venue]["qt"]
        print(
            f"{venue:<22}{len(s):>5}"
            f"{(avg([r['total_gas'] for r in s]) if s else 0):>11,.0f}"
            f"{(avg([r['inner_exec_gas'] for r in s]) if s else 0):>11,.0f}"
            f"{(avg([r['premium_vs_direct_gas'] for r in s]) if s else 0):>11,.0f}"
            f"{(_fpct(s,'premium_vs_direct_pct')):>8.1f}%"
            f"{len(q):>5}"
            f"{(avg([r['router_quote_gas'] for r in q]) if q else 0):>10,.0f}"
            f"{(avg([r['direct_quote_gas'] for r in q]) if q else 0):>10,.0f}"
            f"{(avg([r['premium_quote_gas'] for r in q]) if q else 0):>9,.0f}"
            f"{(_fpct(q,'premium_quote_pct')):>7.1f}%"
        )
    print("-" * len(hdr))

    if wrappers:
        wc = defaultdict(int)
        for r in wrappers:
            wc[r["venue_name"]] += 1
        summary = ", ".join(f"{v}×{n}" for v, n in sorted(wc.items()))
        print(f"\nExcluded {len(wrappers)} wrapper tx(s) from swap stats (tx.to ≠ router; "
              f"total_gas is the outer tx): {summary}")
    print(
        "\nReading: swap stats are DIRECT router calls only. 'avg inner' = the venue\n"
        "frame's own gas inside the router tx (warm-discounted; a true standalone direct\n"
        "swap pays slightly more). 'swap prem'/'swap %' = total - (inner + one transfer +\n"
        "21k intrinsic), the overhead vs a realistic direct call. 'q prem'/'q %' =\n"
        "router_quote_gas - direct_quote_gas (both standalone sims at the swap's block).\n"
        "total_gas is the firm anchor for swaps."
    )


if __name__ == "__main__":
    sys.exit(main())
