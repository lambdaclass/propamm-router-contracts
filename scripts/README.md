# Scripts

This directory holds two kinds of scripts:

- **Foundry deploy/ops scripts** (`*.s.sol`): `Deploy.s.sol`, `Execute.s.sol`,
  `Upgrade.s.sol`, `setupRouterVariables.s.sol`. See the root `README.md` and
  `.env.example` for how to run those with `forge script`.
- **Off-chain analysis tooling** (`kyberswap/`, `gas/`): the routing and
  gas-comparison experiments documented below.

Everything below is plain Python 3 using only the **standard library** — there is
nothing to `pip install`. The gas tools additionally shell out to Foundry's
`cast` (and `solc` for one helper).

> Run all commands **from the repository root** — the scripts write their default
> CSVs to `scripts/kyberswap/` and `scripts/gas/` using relative paths.

---

## Prerequisites

| Tool / var | Needed by | Notes |
|---|---|---|
| Python 3.10+ | all | stdlib only |
| Network access to `aggregator-api.kyberswap.com` | `quote_sweep.py` | live quotes |
| `cast` (Foundry) | `router_gas_compare.py`, `direct_sim.py` | storage slots + RPC |
| `solc` 0.8.29 | `direct_sim.py` | compiles the helper (auto, or pass bytecode) |
| `ETH_RPC_URL` | the gas tools | **archive** node with `debug_traceTransaction` + state overrides (e.g. `ethereum-rpc.publicnode.com`) |

Quick capability check for the RPC:

```bash
cast chain-id --rpc-url "$ETH_RPC_URL"          # expect 1 (mainnet)
# state-override + trace support (both must work for the gas tools):
cast rpc eth_call '{"to":"0x0000000000000000000000000000000000009999","data":"0x"}' \
  latest '{"0x0000000000000000000000000000000000009999":{"code":"0x602a60005260206000f3"}}' \
  --rpc-url "$ETH_RPC_URL"                        # expect 0x...2a
```

---

## 1. KyberSwap routing sweep — `kyberswap/quote_sweep.py`

Quotes WETH/USDC and USDC/WETH at many sizes, repeatedly, against the KyberSwap
aggregator `/routes` endpoint, and records **which pools/DEXes** each trade is
routed through. Repeating identical quotes shows how stable the routing is.

```bash
# default sweep: 13 size/direction combos x 20 repeats = 260 requests
python3 scripts/kyberswap/quote_sweep.py

# faster, concurrent
python3 scripts/kyberswap/quote_sweep.py --repeats 20 --workers 8 --delay 0

# custom sizes, one direction only
python3 scripts/kyberswap/quote_sweep.py --directions weth-usdc --sizes-weth 0.5,1,2,5 --repeats 50
```

Key flags: `--repeats N`, `--workers N` (concurrent in-flight requests; higher =
more likely to hit 429), `--delay S` (per-worker throttle), `--sizes-weth`,
`--sizes-usdc` (comma-separated), `--directions {both,weth-usdc,usdc-weth}`,
`--client-id`, `--chain`, `--out`.

**Output:** `scripts/kyberswap/kyber_quotes_<runId>.csv` (one row per request:
amounts, USD, gas, price impact, `num_splits`, `route_dexes`, full `route_summary`)
plus a printed per-size summary of the distinct routes observed and their counts.

> ⚠️ **Not reproducible by design.** Quotes reflect live liquidity and change every
> block; re-running yields different routes/outputs. That variability is the thing
> being measured.

---

## 2. Router gas decomposition — `gas/router_gas_compare.py`

Finds the swaps we fired through the PropAMM router
(`0x4DdF368080CD7946db5b459aD591c350158175e1`) by reading the venue `Swapped`
logs where `sender == router`, then replays each with
`debug_traceTransaction`/`callTracer` and splits the gas into the venue's own
`swap()` vs. router overhead.

```bash
ETH_RPC_URL=… python3 scripts/gas/router_gas_compare.py                 # default: up to 60 txs
python3 scripts/gas/router_gas_compare.py --max-txs 200                  # wider scan
python3 scripts/gas/router_gas_compare.py --from-block 25230000 --to-block 25240000   # pinned window
```

Key flags: `--from-block` (default 25000000), `--to-block` (0 = latest),
`--max-txs`, `--window` (getLogs chunk size), `--router`, `--rpc`, `--out`.

**Output:** `scripts/gas/router_gas_<runId>.csv` + a per-venue summary. Notable
columns: `total_gas`, `inner_swap_gas` (the PropAMM execution), `premium_vs_raw_swap_gas`
(gross overhead), `premium_vs_direct_gas` (vs a realistic direct call).

> ⚠️ **Refund caveat.** `callTracer` subcall gas is *gross* while the tx total is
> *net* of EIP-3529 refunds, so the per-component split carries some gas-level
> uncertainty (it under-counts venues that refund heavily). `total_gas` and
> `inner_swap_gas` are the firm anchors. For a refund-clean premium, use the
> simulation cross-check below.

---

## 3. Refund-clean gas cross-check (simulation) — `gas/direct_sim.py`

The rigorous "router vs. direct" number. For one real `swapViaVenueV1` /
`swapViaVenueWithFeeV1` transaction it:

1. reads the on-chain receipt gas (ground truth),
2. re-simulates the **same router call** with `eth_estimateGas` + state overrides
   at the historical block (validates the harness),
3. simulates a minimal **direct integrator** — `tokenIn.transfer(venue, amountIn);
   venue.swap(...)` — injected at the router address so the venue sees the same caller.

Because `eth_estimateGas` returns gas **net of refunds**, the premium
`router_sim − direct_sim` is refund-clean. Both sims run cold at the same block,
so cold-access penalties cancel in the difference.

```bash
ETH_RPC_URL=… python3 scripts/gas/direct_sim.py \
  0x0b299be5b4496033d473c1b9025b1c8a9077712ef7356c5d0794fa718c3fa027
```

Flags: positional `txhash` (must be a `swapViaVenue*` call so params are in the
calldata); `--helper-bytecode 0x…` (skip auto-compile); `--offsets 0,1,2,3` (block
offsets from N to try until the venue's price is fresh — the price-update tx lands
in block N, so N−1 is stale).

**Output:** prints `router_sim`, `direct_sim`, and the refund-clean premium in gas
and %. The helper contract is `gas/DirectSwap.sol` (compiled to runtime bytecode
and injected via state override).

### Reproducibility
- **Deterministic** at a fixed block: verified byte-identical across repeated runs.
- Requires an **archive** RPC (publicnode serves state ≳5M blocks deep). A pruned
  node fails rather than returning a wrong answer.
- For byte-exact results, **pin `solc` 0.8.29 `--optimize`** (a different compiler
  shifts the injected helper's dispatcher cost by a few gas).

---

## 4. Router overhead over the last N days, swaps + quotes — `gas/router_overhead.py`

The all-in-one "how much overhead does the router add" tool, scoped to a rolling
time window (default **3 days**) and covering **both** operations. It discovers
every swap the router fired — via the router's **own** `Swapped` event, whose
`marketMaker` field is the venue that actually filled (the Uniswap fallback
included), so nothing is hardcoded about which venue was used — and writes two
CSVs:

- **`swaps_<runId>.csv` — real transactions.** Receipt `total_gas`, plus a
  `debug_traceTransaction` decomposition into `inner_exec_gas` (the venue frame's
  own gas, located **by address** — robust across Fermi's bespoke entrypoint, the
  generic `IPropAMM.swap`, and the Uniswap router, where a fixed-selector match
  would miss it), the two router transfers (`pull_in`, `delivery`), and the
  residual `router_overhead_gas`. Reports the premium vs. a realistic direct call
  (`inner + one transfer + 21k intrinsic`).
- **`quotes_<runId>.csv` — simulated.** Quotes are gasless off-chain `eth_call`s,
  so there are no historical quote txs to read. For each discovered swap's
  `(venue, pair, amount)`, it `debug_traceCall`s both `quoteVenueV1(venue, …)` on
  the router and the venue's native `quote()` / `quoteAmounts()` directly, **at
  that swap's block** (where the venue is live — a quote at `latest` with no
  builder state-overrides falsely reverts or silently falls back to Uniswap).
  Premium = `router_quote_gas − direct_quote_gas`.

```bash
ETH_RPC_URL=… python3 scripts/gas/router_overhead.py                  # last 3 days (default)
python3 scripts/gas/router_overhead.py --start-block 25300000         # from a block -> latest
python3 scripts/gas/router_overhead.py --start-block 25300000 --to-block 25320000   # pinned range
python3 scripts/gas/router_overhead.py --days 7 --max-txs 100         # wider time window
```

Key flags: `--start-block` (alias `--from-block`) — analyze from this block to
`--to-block` (default latest), overriding `--days`; `--days` (default 3) is the
time-based fallback used only when `--start-block` is omitted; `--max-txs`,
`--window` (getLogs chunk), `--delay`, `--out-swaps`, `--out-quotes`, `--rpc`,
`--router`. Quotes fall back to `eth_estimateGas` if `debug_traceCall` is
unavailable (recorded in the `method` column).

> ⚠️ **Cold/warm.** The venue frame *inside* the router tx is warm (the router
> pre-warms storage slots/addresses via EIP-2929), so `inner_exec_gas` slightly
> *under*-counts a true standalone direct swap. For quotes the headline
> `direct_quote_gas` is the **standalone** call (what a real direct integrator
> pays); the warm nested frame is reported separately as
> `router_inner_venue_quote_gas`. `total_gas` is the firm anchor for swaps.

> ⚠️ **Gross vs. net.** Like `router_gas_compare.py`, callTracer subcomponents are
> gross while the receipt total is net of EIP-3529 refunds, so
> `router_overhead_gas` can be slightly negative on refund-heavy venues (flagged
> in the `note` column). `quotes_match` confirms the router and direct paths
> priced the *same* output — a sanity check that the comparison is apples-to-apples.

> ℹ️ **Idle venues.** Any of the three named PropAMMs the router did not route to
> within the window is emitted as an explicit "checked: no router routing … in
> window" row in both CSVs, so the absence is documented rather than silent.
