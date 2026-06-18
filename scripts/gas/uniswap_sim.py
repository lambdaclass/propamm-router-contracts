#!/usr/bin/env python3
"""Simulate a Uniswap V3 swap (USDC->WETH) for a gas baseline, same method as
`direct_sim.py`: state overrides + eth_estimateGas (net of refunds) at a fixed
block, plus a callTracer pass to isolate the inner pool `swap()` cost.

This is the peer baseline for the PropAMM router numbers: SwapRouter02 is itself
a router that pulls funds and routes, so its total is comparable to our router's
total, and the inner pool swap is comparable to the PropAMM `swap()`.

    ETH_RPC_URL=... python3 scripts/gas/uniswap_sim.py
    python3 scripts/gas/uniswap_sim.py --amount 1000000000 --fee 3000 --block 25275211
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

SWAP_ROUTER_02 = "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45"
USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
CALLER = "0x000000000000000000000000000000000000f00d"
BIG_ETH = "0x3635c9adc5dea00000"  # 1000 ETH
FUND = 1_000_000 * 10**6  # 1,000,000 USDC of funding

USDC_BAL_SLOT, USDC_ALLOWANCE_SLOT = 9, 10
POOL_SWAP_SEL = "0x128acb08"  # IUniswapV3Pool.swap(address,bool,int256,uint160,bytes)


def cast(*args: object) -> str:
    return subprocess.run(
        ["cast", *map(str, args)], capture_output=True, text=True, check=True
    ).stdout.strip()


def rpc(method: str, *params: str) -> tuple[object, str]:
    p = subprocess.run(
        ["cast", "rpc", method, *params, "--rpc-url", os.environ["ETH_RPC_URL"]],
        capture_output=True, text=True,
    )
    if p.returncode != 0:
        return None, (p.stderr or p.stdout).strip()
    out = p.stdout.strip()
    try:
        return json.loads(out), ""
    except json.JSONDecodeError:
        return out.strip('"'), ""


def find_pool_swap_gas(node: dict) -> int:
    """Deepest/first IUniswapV3Pool.swap() frame gasUsed."""
    if (node.get("input") or "")[:10] == POOL_SWAP_SEL and node.get("type") in ("CALL", "CALLCODE"):
        return int(node.get("gasUsed", "0x0"), 16)
    for c in node.get("calls", []) or []:
        g = find_pool_swap_gas(c)
        if g:
            return g
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Uniswap V3 swap gas baseline (sim).")
    ap.add_argument("--amount", type=int, default=1_000_000, help="amountIn in token units (default 1 USDC)")
    ap.add_argument("--fee", type=int, default=500, help="pool fee tier (default 500 = 0.05%%)")
    ap.add_argument("--block", type=int, default=0, help="block to simulate at (default: latest-5)")
    args = ap.parse_args()

    if not os.environ.get("ETH_RPC_URL"):
        print("ERROR: set ETH_RPC_URL", file=sys.stderr)
        return 2

    blk = args.block or (int(cast("block-number", "--rpc-url", os.environ["ETH_RPC_URL"])) - 5)
    block_hex = hex(blk)

    bal_slot = cast("index", "address", CALLER, USDC_BAL_SLOT)
    allow_inner = cast("index", "address", CALLER, USDC_ALLOWANCE_SLOT)
    allow_slot = cast("index", "address", SWAP_ROUTER_02, allow_inner)
    fund = cast("to-uint256", FUND)

    # exactInputSingle((tokenIn,tokenOut,fee,recipient,amountIn,amountOutMin,sqrtPriceLimitX96))
    data = cast(
        "calldata",
        "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))",
        f"({USDC},{WETH},{args.fee},{CALLER},{args.amount},0,0)",
    )
    call = {"from": CALLER, "to": SWAP_ROUTER_02, "data": data}
    overrides = {
        CALLER: {"balance": BIG_ETH},
        USDC: {"stateDiff": {bal_slot: fund, allow_slot: fund}},
    }

    print(f"Uniswap V3 exactInputSingle  USDC->WETH  amountIn={args.amount}  fee={args.fee}  block={blk}\n")

    gas_hex, err = rpc("eth_estimateGas", json.dumps(call), block_hex, json.dumps(overrides))
    if gas_hex is None:
        print(f"  estimateGas FAILED: {err}")
        return 1
    total = int(gas_hex, 16)

    trace, terr = rpc("debug_traceCall", json.dumps(call), block_hex,
                      json.dumps({"tracer": "callTracer", "stateOverrides": overrides}))
    pool_gas = find_pool_swap_gas(trace) if isinstance(trace, dict) else 0

    print(f"  SwapRouter02 total (net, cold): {total:,}")
    if pool_gas:
        print(f"  inner pool.swap():              {pool_gas:,}")
        print(f"  router02 overhead:              {total - pool_gas:,}")
    elif terr:
        print(f"  (trace unavailable: {terr[:60]})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
