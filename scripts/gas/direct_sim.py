#!/usr/bin/env python3
"""Refund-clean cross-check of the router gas premium via state-override simulation.

For a real `swapViaVenueV1`/`swapViaVenueWithFeeV1` transaction we fired at the
router, we:

  1. read the on-chain receipt gas (ground-truth router cost),
  2. re-simulate the SAME router call with `eth_estimateGas` + state overrides at
     the historical block (validates the harness reproduces the real number),
  3. simulate a DIRECT integrator -- a tiny injected contract that does
     `tokenIn.transfer(venue, amountIn); venue.swap(...)` -- at the same block.

`eth_estimateGas` returns net gas (EIP-3529 refunds applied), so

    premium = router_total - direct_sim

is the refund-clean router tax, cross-checking the trace-decomposition estimate.

Simulating at the historical block means the venue is already live (the real
swap succeeded there), so no price priming is needed.

Needs `cast` (slots/keccak) + an archive RPC with state overrides (ETH_RPC_URL).
Stdlib only otherwise.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

ROUTER = "0x4DdF368080CD7946db5b459aD591c350158175e1"
HELPER = "0x000000000000000000000000000000000000c0de"  # injected DirectSwap
CALLER = "0x000000000000000000000000000000000000f00d"  # synthetic EOA payer

# token -> (balances slot, allowances slot). From the repo fork-test comments.
TOKEN_SLOTS = {
    "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": (9, 10),   # USDC
    "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2": (3, 4),    # WETH9
}

SWAP_VIA_VENUE = {
    "0x82fc5493": "swapViaVenueV1(address,address,address,uint256,uint256,address,uint256)",
    "0xca775698": "swapViaVenueWithFeeV1(address,address,address,uint256,uint256,address,uint256,(uint16,address))",
}

BIG_ETH = "0x3635c9adc5dea00000"  # 1000 ETH
FUND = 1000 * 10**6  # 1000 token units of funding (>= any amountIn here)


def cast(*args: object) -> str:
    return subprocess.run(
        ["cast", *map(str, args)], capture_output=True, text=True, check=True
    ).stdout.strip()


def rpc(method: str, *params: str) -> tuple[str | None, str]:
    """Return (result, error). result is None on RPC error."""
    p = subprocess.run(
        ["cast", "rpc", method, *params, "--rpc-url", os.environ["ETH_RPC_URL"]],
        capture_output=True,
        text=True,
    )
    if p.returncode != 0:
        return None, p.stderr.strip() or p.stdout.strip()
    return p.stdout.strip().strip('"'), ""


def slot_balance(token: str, holder: str) -> str:
    return cast("index", "address", holder, TOKEN_SLOTS[token.lower()][0])


def slot_allowance(token: str, owner: str, spender: str) -> str:
    inner = cast("index", "address", owner, TOKEN_SLOTS[token.lower()][1])
    return cast("index", "address", spender, inner)


def word(n: int) -> str:
    return cast("to-uint256", n)


def compile_helper() -> str:
    """Compile scripts/gas/DirectSwap.sol -> DirectSwap runtime bytecode."""
    here = os.path.dirname(os.path.abspath(__file__))
    out = subprocess.run(
        ["solc", "--bin-runtime", "--optimize", os.path.join(here, "DirectSwap.sol")],
        capture_output=True, text=True, check=True,
    ).stdout
    lines = out.splitlines()
    for i, ln in enumerate(lines):
        if "DirectSwap.sol:DirectSwap" in ln:
            for j in range(i, len(lines)):
                if "Binary of the runtime part" in lines[j]:
                    return "0x" + lines[j + 1].strip()
    raise RuntimeError("could not extract DirectSwap runtime bytecode from solc output")


def estimate(call: dict, block_hex: str, overrides: dict) -> tuple[int | None, str]:
    res, err = rpc("eth_estimateGas", json.dumps(call), block_hex, json.dumps(overrides))
    if res is None:
        return None, err
    return int(res, 16), ""


def main() -> int:
    ap = argparse.ArgumentParser(description="State-override gas sim cross-check.")
    ap.add_argument("txhash", help="A swapViaVenueV1/WithFee router tx to cross-check")
    ap.add_argument("--helper-bytecode", help="DirectSwap runtime bytecode (0x...); auto-compiled if omitted")
    ap.add_argument(
        "--offsets",
        default="0,1,2,3",
        help="Block offsets from N to try until the venue is fresh (default 0,1,2,3)",
    )
    args = ap.parse_args()

    rpc_url = os.environ.get("ETH_RPC_URL")
    if not rpc_url:
        print("ERROR: set ETH_RPC_URL", file=sys.stderr)
        return 2

    helper_code = args.helper_bytecode or compile_helper()

    # --- pull the real tx + ground-truth gas ---
    txin = cast("tx", args.txhash, "input", "--rpc-url", rpc_url)
    blk = int(cast("tx", args.txhash, "blockNumber", "--rpc-url", rpc_url))
    real_gas = int(cast("receipt", args.txhash, "gasUsed", "--rpc-url", rpc_url))
    sel = txin[:10]
    if sel not in SWAP_VIA_VENUE:
        print(f"tx selector {sel} is not a swapViaVenue* call; cannot reconstruct params.")
        return 1

    venue, token_in, token_out, amount_in, min_out, recipient, deadline = (
        x.strip() for x in cast("decode-calldata", SWAP_VIA_VENUE[sel], txin).splitlines()[:7]
    )
    amount_in = int(amount_in.split()[0])
    min_out = int(min_out.split()[0])
    deadline = int(deadline.split()[0])
    if token_in.lower() not in TOKEN_SLOTS:
        print(f"tokenIn {token_in} has no known storage slot mapping.")
        return 1

    print(f"tx {args.txhash}")
    print(f"  venue={venue}  {token_in}->{token_out}  amountIn={amount_in}  minOut={min_out}")
    print(f"  real receipt gasUsed = {real_gas:,}  (block {blk})\n")

    run_data = cast(
        "calldata", "run(address,address,address,uint256,uint256,address,uint256)",
        token_in, venue, token_out, amount_in, min_out, recipient, deadline,
    )
    router_overrides = {
        CALLER: {"balance": BIG_ETH},
        token_in: {"stateDiff": {
            slot_balance(token_in, CALLER): word(FUND),
            slot_allowance(token_in, CALLER, ROUTER): word(FUND),
        }},
    }
    # Inject the direct integrator AT the router address so the venue sees the
    # same caller (router) -- isolates "what if the router did only transfer+swap".
    direct_overrides = {
        CALLER: {"balance": BIG_ETH},
        ROUTER: {"code": helper_code},
        token_in: {"stateDiff": {slot_balance(token_in, ROUTER): word(FUND)}},
    }

    # The venue's price is only fresh once its update tx (in block N) is applied,
    # so sweep block offsets from N until both sims execute the real venue.
    for off in (int(x) for x in args.offsets.split(",")):
        block_hex = hex(blk + off)
        router_sim, rerr = estimate({"from": CALLER, "to": ROUTER, "data": txin}, block_hex, router_overrides)
        direct_sim, derr = estimate({"from": CALLER, "to": ROUTER, "data": run_data}, block_hex, direct_overrides)
        ok = router_sim and direct_sim
        # A router_sim near the real total means it took the venue (not fallback).
        on_venue = router_sim and abs(router_sim - real_gas) < 0.4 * real_gas
        print(f"  block N+{off} ({blk+off}): router_sim={router_sim or rerr[:40]}  direct_sim={direct_sim or derr[:40]}")
        if ok and on_venue:
            break
    else:
        print("\nCould not get a fresh-venue simulation in the given offsets.")
        return 1

    print("\nRESULTS  (both sims are cold-state at the same block, so cold-access")
    print("          penalties cancel in the difference)")
    delta = router_sim - real_gas
    print(f"  router_sim:  {router_sim:,}  (real receipt {real_gas:,}, {delta:+,} from cold state)")
    print(f"  direct_sim:  {direct_sim:,}  (transfer + venue.swap only)")
    prem = router_sim - direct_sim
    print(f"\n  REFUND-CLEAN ROUTER PREMIUM = router_sim - direct_sim")
    print(f"     {router_sim:,} - {direct_sim:,} = {prem:,} gas  ({prem/direct_sim*100:.1f}% over direct)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
