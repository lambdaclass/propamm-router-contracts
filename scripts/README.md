# Scripts

This directory holds three kinds of scripts:

- **Foundry deploy/ops scripts** (`*.s.sol`): `Deploy.s.sol`, `Execute.s.sol`,
  `Upgrade.s.sol`. See the root `README.md` and `.env.example` for how to run
  those with `forge script`.
- **On-chain swap drivers** (`execute_swaps.sh`, `execute_direct_swaps.sh`): fire
  real `$1` swaps through the PropAMM router (or directly at each venue) to
  generate the transactions the gas tools below later analyze.
- **Off-chain analysis tooling** (`kyberswap/`, `gas/`): the routing and
  gas-comparison experiments documented below.

The analysis tooling below is plain Python 3 using only the **standard library** —
there is nothing to `pip install`. The swap drivers are Bash; they and the gas
tools shell out to Foundry's `cast` (and `solc` for one helper).

> Run all commands **from the repository root** — the scripts write their default
> CSVs to `scripts/kyberswap/` and `scripts/gas/` using relative paths.

---

## Prerequisites

| Tool / var | Needed by | Notes |
|---|---|---|
| Python 3.10+ | all | stdlib only |
| Network access to `aggregator-api.kyberswap.com` | `quote_sweep.py` | live quotes |
| `cast` (Foundry) | `router_gas_compare.py`, `direct_sim.py`, `execute_swaps.sh` | storage slots + RPC; the driver also broadcasts txs |
| `jq`, `bc` | `execute_swaps.sh` | receipt decoding + fee-math check (script still runs without, just prints raw JSON) |
| `solc` 0.8.29 | `direct_sim.py` | compiles the helper (auto, or pass bytecode) |
| `ETH_RPC_URL` | the gas tools | **archive** node with `debug_traceTransaction` + state overrides (e.g. `ethereum-rpc.publicnode.com`) |
| `ETH_RPC_URL` + `PK` | `execute_swaps.sh` | any mainnet RPC that accepts `eth_sendRawTransaction`; `PK` is a **funded** sender — these are real txs that cost gas |

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

## 2. Fire router swaps — `execute_swaps.sh`

Broadcasts `N` real swaps through the PropAMM router
(`swapViaVenue*` / `swapViaSelectedVenues*`), selling 1 USDC → WETH per swap by
default. This is what *produces* the on-chain transactions the gas tools below read
back. Before each swap it quotes the targeted venue on-chain (`quoteVenueV1`) and
sets `AMOUNT_OUT_MIN` to the quote minus `SLIPPAGE_BPS` (default 0.50%); after each
tx it decodes the `Swapped` event's `marketMaker` to report **which venue actually
filled** (vs. silently falling back to Uniswap V3), the output received, the
frontend-fee check, and which builder built the landing block.

`MODE` picks the routing function — and changes what the `[venues]` arg means:

| `MODE` | function | `[venues]` is… |
|---|---|---|
| `withfee` *(default)* | `swapViaVenueWithFeeV1` | round-robin: one venue per swap |
| `nofee` | `swapViaVenueV1` | round-robin: one venue per swap |
| `selected` | `swapViaSelectedVenuesV1` | the **candidate set** the router re-quotes on-chain and best-fills |
| `selectedwithfee` | `swapViaSelectedVenuesWithFeeV1` | the **candidate set** (best-of), plus a fee skim |

`[venues]` is an optional comma-separated, case-insensitive list — valid names are
`BEBOP`, `FERMI`, `KIPSELI`, `TEMPEST`, `TAURUSFI`, `METRIC`, `EL_ZORRO` (order
preserved, dups dropped). `_` and `-` are ignored when matching, so the SDK's
`elzorro` key works as-is. Omit the arg to use all seven. Uniswap V3 is the
safety net in every mode.

```bash
# Best-of {KIPSELI, FERMI} with the frontend fee — the router re-quotes BOTH venues
# on-chain each swap and fills whichever prices best (Uniswap V3 as fallback). 4 swaps:
MODE=selectedwithfee ETH_RPC_URL=… PK=0x… ./scripts/execute_swaps.sh 4 kipseli,fermi

# Same best-of-set, no fee (recipient gets the full output):
MODE=selected ETH_RPC_URL=… PK=0x… ./scripts/execute_swaps.sh 4 kipseli,fermi

# Single-venue mode with the same arg → round-robins KIPSELI → FERMI → KIPSELI → …,
# one venue per swap (NOT best-of). 4 swaps, default withfee + 0.50% fee:
ETH_RPC_URL=… PK=0x… ./scripts/execute_swaps.sh 4 kipseli,fermi

# All swaps forced through a single venue (one name = no rotation):
ETH_RPC_URL=… PK=0x… ./scripts/execute_swaps.sh 10 fermi
```

Key env: `ETH_RPC_URL`, `PK` (required); `MODE` (above); `FEE_BPS` (default 50),
`FEE_RECIPIENT`; `SLIPPAGE_BPS` (default 50); `AMOUNT_IN` / `TOKEN_IN` / `TOKEN_OUT`
(default 1 USDC → WETH; re-size `AMOUNT_IN` in base units whenever you change
`TOKEN_IN`); `PRIORITY_GWEI` / `MAX_FEE_GWEI` / `BASEFEE_MAX_GWEI` (gas pricing and
a cheap-gas gate); `RECEIPT_TRIES` / `RECEIPT_WAIT_SECS` (receipt-poll budget).

**Output:** no CSV — it's a driver, not an analyzer. Per tx it prints the tx hash
and a verdict line (filled venue, output, fee OK/MISMATCH, builder), then a
per-venue "filled as targeted" tally at the end.

> ⚠️ **Real mainnet txs.** Each run spends gas from `PK` and the ERC20 approve is
> only skipped when the existing allowance already covers the batch. Start with a
> small `N`.

> ⚠️ **Quoted ≠ filled.** A venue can quote on-chain yet fail to fill (e.g. FERMI
> RFQ); in the single-venue modes that pushes the min above the Uniswap fallback's
> real fill and the tx reverts. The `selected*` modes re-quote the whole set, so
> they tolerate this better. Watch the `marketMaker` in the verdict to see what
> truly filled.

---

## 3. Router gas decomposition — `gas/router_gas_compare.py`

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

## 4. Refund-clean gas cross-check (simulation) — `gas/direct_sim.py`

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

## 5. Router overhead over the last N days, swaps + quotes — `gas/router_overhead.py`

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

---

## 6. Onchain-split gas + economics, re-runnable — `gas/split_economics.py`

Drives the split analysis end to end and writes one CSV per run, so re-running it
and diffing the CSVs shows what moved. It exists because the numbers behind "is
the onchain split worth it" have two very different shelf lives, and mixing them
into one verdict gives the verdict the worse error bar:

- **`durable`** — gas per mechanism. Set by bytecode, fine to measure once, and
  the right thing to assert against in CI.
- **`perishable`** — venue depth, basis-point advantage, and how many legs the
  split actually admits. Set by market makers. Fermi's usable depth moved ~3.6x
  in 17 hours and again from 2M to 3M USDC the next day, so a single reading of
  any of these is not evidence.

Every metric is tagged with its durability in the CSV. An unrecognised metric is
tagged `unknown` rather than assumed stable.

```bash
# full run: anvil fork at head + a 10-block depth sweep (the sweep is the slow part)
ETH_RPC_URL=… python3 scripts/gas/split_economics.py

# fast real-venue pass, skip the sweep
ETH_RPC_URL=… python3 scripts/gas/split_economics.py --no-sweep

# reproduce an old run, or widen/narrow the sweep
ETH_RPC_URL=… python3 scripts/gas/split_economics.py --block 25892401 --samples 20 --step 360
```

`--port` moves anvil off 8545 if something is already there. anvil is started and
stopped by the script; it is killed even if a stage fails.

**Output:** `scripts/gas/split_economics_<runId>.csv` (`run_id,metric,value,
durability,label`) plus a grouped summary. The underlying measurements live in
`test/RealGasFork.t.sol` (real venues on a fork) and `test/DepthSamplerFork.t.sol`
(multi-block sweep); both emit `RESULT|<key>|<value>` lines that this script
harvests, so the parsing does not depend on log prose.

`RealGasFork` is gated on `RPC_URL` like the other fork suites. The depth sweep
is gated on `ARCHIVE_RPC_URL` instead, deliberately: it re-forks `SAMPLES * STEP`
blocks into the past, so a pruned endpoint serves the head fork and then dies
mid-sweep on `historical state is not available` — and at ~5,400s it should
never start by accident. CI sets a plain `RPC_URL` (a public, non-archive node)
and runs an unfiltered `forge test`, so the separate variable is what keeps the
sweep out of it.

Everything here measures **real venues**. A mock-venue gas benchmark used to sit
alongside it and was removed: mocks understated real costs 3.2–8.1×, distorted the
quote term far more than the swap term, and had already produced two wrong
published figures. Mock contracts are still used by the correctness tests, where
determinism is the point and gas is not.

> **One caveat the numbers cannot settle.** The sweep reports how often a venue is
> *naturally* quotable — quotable at a block's own timestamp, with no time-warping
> and no lane patching. That has been 0–1 blocks in 10. But lanes are published
> just-in-time with fills, so if a market maker publishes on demand for a taker,
> a real integrated swap always sees a fresh lane and this statistic understates
> production badly. Whether the propAMM edge is capturable ~10% of the time or
> ~always depends on that, and no fork measurement can answer it.
