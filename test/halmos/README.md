# Symbolic checks (Halmos)

Properties of the split / multi-leg path (`swapSplitV1`) proven over the real
router bytecode with [Halmos](https://github.com/a16z/halmos), for **every**
input and every behaviour of the venues, within stated bounds.

## Running

```sh
uv tool install halmos==0.3.3              # once; needs Python >= 3.11

FOUNDRY_PROFILE=halmos halmos              # everything, incl. the slow checks (hours)
FOUNDRY_PROFILE=halmos halmos --function 'check_(noRegretCertificate_one|custody_oneFillable)'   # what CI runs
FOUNDRY_PROFILE=halmos halmos --function check_custody_oneVenue   # ~1 h, local only
FOUNDRY_PROFILE=halmos halmos --contract SplitPlannerHalmos   # the planner, ~5 min
FOUNDRY_PROFILE=halmos halmos --function 'check_execute_[123]\('   # execution, ~2 min (4: ~12 min, 5: ~2 h)

python3 test/halmos/no_regret_lemma.py     # the arithmetic half; needs z3-solver
```

The `halmos` Foundry profile exists for one reason: Forge's default
`dynamic_test_linking` compiles `new Contract()` in tests into the
`vm.deployCode` cheatcode, which Halmos does not implement. `via_ir` stays on —
the router does not compile without it.

`check_*` functions are ignored by `forge test`, so these never slow down the
regular suite.

## No-regret: a split never does worse than all-Uniswap

**Property.** For every behaviour of the whitelisted venues, `swapSplitV1`
either reverts (the user keeps their funds) or delivers

    amountOut >= U(amountIn)

where `U(x)` is what the Uniswap fallback pays for `x`. Splitting can only
help.

**Assumed** — only about Uniswap, never about the venues:

| | Assumption | Where it lives |
|---|---|---|
| (a) | The quoter reports what the swap pays; nothing moves the pool mid-transaction | `mocks/SymUniswap.sol` — one table serves both |
| (b) | Average rate never improves with size: `x <= y => U(x)/x >= U(y)/y` (true of any concave curve through 0) | `no_regret_lemma.py`, `avg_rate_non_increasing` |
| (c) | Every Uniswap output the run sees fits in `uint128` | `SplitNoRegret.t.sol`, `vm.assume` |

(a) is the one an adversarial venue can break: its leg runs before the
coalesced Uniswap leg, so it could trade against the same pool first.
`amountOutMin` still protects the user, but the bound then holds only against
the pool as it stood when the Uniswap leg ran.

**How it is proven.** In two halves, because the arithmetic joining them is a
chain of products that bit-vector solvers cannot close (Yices times out at
300 s on the direct query even with one venue):

1. `SplitNoRegret.t.sol` (Halmos, router bytecode): every run that does not
   revert satisfies a **certificate** — every executed venue leg passed
   `_waterfall`'s gate against a Uniswap reference no larger than the order and
   delivered its pro-rata minimum; at most one leg is partial; and
   `amountOut = Σ venue deliveries + U(remainder)`. No assumption about
   Uniswap's prices goes into this half.
2. `no_regret_lemma.py` (Z3, unbounded integers): certificate + (b) ⇒
   `amountOut >= U(amountIn)`, for 0 to `MAX_LEGS` legs.

The certificate is stated in the same terms on both sides; keep them in sync.

**Bounds.** The Halmos half is **verified with one whitelisted venue**, on
both of the router's pricing paths, with arbitrary amounts up to `uint128`
and arbitrary venue quotes and deliveries:

| Check | Pricing path | Result (local) |
|---|---|---|
| `check_noRegretCertificate_oneVenue` | blind two-point probe, incl. `_probeDownToFillable` (`mocks/SymVenue.sol`) | PASS, ~3,000 paths, ~4 min |
| `check_noRegretCertificate_oneFillableVenue` | `IPropAMMFillable.quoteFillable` (`mocks/SymFillableVenue.sol`) | PASS, ~190 paths, ~17 s |
| `check_noRegretCertificate_twoVenues` | blind probe, two venues | does **not** finish (2-hour limit, no result); not in CI |

The lemma holds for any number of legs up to `MAX_LEGS`.

**Mutation-tested.** The checks fail when the code is broken in the ways they
are meant to catch:

| Mutation | Caught by |
|---|---|
| `_waterfall` gate removed (every candidate placed) | Halmos certificate (C1), on both pricing paths |
| Refined reference quoted at twice the remainder (`s > amountIn`) | Halmos certificate (C1) |
| Full-leg `proRataMin` one wei short | Halmos certificate (C1) |
| Lemma without `s <= amountIn` | Z3 lemma A |
| Lemma allowing more than one partial leg | Z3 lemma C |

## Custody: nobody's tokens go missing

**Property** (`SplitCustody.t.sol`). Venues here are hostile
(`mocks/SymNastyVenue.sol`). On every quote and swap they try to pull either
token out of the router, push arbitrary amounts of either token into it, keep
or refund any part of a leg's input, and quote or deliver anything. The router
also starts out holding arbitrary dust of both tokens. Every `swapSplitV1`
that does not revert then ends with:

| | |
|---|---|
| K1 | the user paid exactly `amountIn` (from a balance larger than it) |
| K2 | the recipient received exactly the returned `amountOut`, and `amountOut >= amountOutMin` |
| K3 | Σ executed venue-leg inputs + the Uniswap input `== amountIn` |
| K4 | no venue pulled anything out of the router |
| K5 | the router's balance of each token changed by exactly what venues pushed into it: it kept none of the user's tokens and lost none of its dust |
| K6 | the router has no allowance left to any venue or to Uniswap |

A call that reverts moves nothing (EVM atomicity), so it needs no check.
Nothing is assumed about prices; `SymUniswap` pulls exactly its `amountIn`,
like the real `SwapRouter02`.

**Bounds.** One whitelisted venue. Amounts are capped (dust and user balance
at `uint128`, venue gifts at `uint64`) only so that no mint can overflow a
total supply, which would merely revert. Not covered: the ETH sentinel paths
(WETH wrap/unwrap) and `swapSplitWithFeeV1`.

| Check | Pricing path | Result (local) |
|---|---|---|
| `check_custody_oneFillableVenue` | `IPropAMMFillable.quoteFillable` | PASS, ~6,000 paths, ~6 min (in CI) |
| `check_custody_oneVenue` | blind two-point probe | PASS, ~48,000 paths, ~1 h (local only) |

**Mutation-tested** (against the fillable check):

| Mutation | Caught |
|---|---|
| Router approves each venue for 1 wei before its swap | yes |
| Router keeps 1 wei of the Uniswap leg's input | yes |
| Final `delivered >= amountOutMin` check removed | yes |
| Uniswap approved for `amountIn + 1` and the approval never reset | yes |
| Uniswap approved for `amountIn + 1`, reset kept | no — the reset clears it, so this is not a bug |

The R1 quote-phase balance check (`_planSplit`) is not exercised: a venue here
can only take router funds through an allowance, and K4/K6 show none exists.
R1 guards against a quote that lowers the router's balance by some other
route, which this mock does not model.

## Planner: the leg plan for many venues

The router-level checks above run with one venue, because the whole router
with two does not finish. The step where several venues interact is the
planning: sort the candidates, then waterfall them into legs. That step is
checked on its own (`SplitPlanner.t.sol`), on the router's real code
(`mocks/PlannerHarness.sol` only exposes `_waterfall` and
`SplitPlanner.sortByRateDesc`), with up to six arbitrary candidates.

Candidates are what `_gatherCandidates` emits: distinct venues,
`0 < fill <= amountIn`, `0 < out <= uint128.max`. Uniswap reference outputs
are `<= uint128.max`, assumption (c) above.

**`_waterfall`**, for any candidates in any order and any `amountIn`:

| | |
|---|---|
| W1 | the legs spend exactly `amountIn` |
| W2 | at most `MAX_LEGS` venue legs, then at most one Uniswap leg, last, with a positive input and `minOut == 0` |
| W3 | venue leg i is candidate i (no candidate is skipped to place a later one), its input is in `(0, fill]`, and `minOut == proRataMin(out, fill, input)` |
| W4 | only the last venue leg can be partial, and a partial leg leaves no Uniswap leg |
| W5 | every venue leg beat a Uniswap reference quote taken at a size `s` in `[1, amountIn]`: `out * s > U(s) * fill` |

W5 is certificate fact C1 of the no-regret proof, now for many legs.

**`sortByRateDesc`** returns a permutation of its input (nothing lost,
duplicated or altered), ordered by rate `out / fill`, highest first, with ties
going to the larger fill. The test states this order itself instead of
calling `SplitPlanner.betterThan`; reusing the comparator would accept a
broken one.

**`proRataMin`** is exact for a full leg (Halmos). It also rounds down, is
less than one wei below the exact share, and is monotone in the leg size:
lemma D in `no_regret_lemma.py`. Those three time out in the bit-vector
solvers but close at once over the integers. The integer proof is exact
here, because `out * leg < 2^256` wherever the router calls it, so EVM `DIV`
is floor division.

| Check | Candidates | Result (local) |
|---|---|---|
| `check_waterfall_shape_{1,2,3,6}` (W1–W4) | 1, 2, 3, 6 | PASS; 6 candidates: ~2,600 paths, ~1 min |
| `check_waterfall_gate_{1,2}` (W5) | 1, 2 | PASS; 2 candidates: ~320 paths, ~80 s |
| `check_sort_{2,3,4}` | 2, 3, 4 | PASS; 4 candidates: ~5,600 paths, ~80 s |
| `check_proRataMin_fullLegIsQuote` | n/a | PASS |

Six candidates is one more than `MAX_LEGS`, so the leg cap is reached. The
W5 check stops at two candidates: with three, one query on products of
symbolic prices runs past 10 minutes. Two already reach every state the gate
can be in (the initial reference, a contested candidate that triggers the one
refinement, a candidate placed after it). Whether leg i passed depends only on
candidate i and the reference current at that moment. `gate_2` sets its own
10-minute solver timeout with `@custom:halmos`; the default 60 s is too short
for it.

**Mutation-tested:**

| Mutation | Caught by |
|---|---|
| `_waterfall` price gate removed | `gate_2` |
| Re-check after refining the reference removed | `gate_2` |
| Leg not clamped to the remaining input | `shape_2` |
| Leg cap `legCount <= MAX_LEGS` (one too many) | `shape_6` |
| A candidate that covers the rest takes only half of it and the loop goes on | `shape_2` |
| `minOut` is the full quote even for a partial leg | `shape_2` |
| Sort comparator reversed | `sort_3` |
| Sort tie-break reversed | `sort_3` |
| Sort loses an element (the key moved to the front is not written back) | `sort_3` |

W3 compares `minOut` with the library's `proRataMin`, so a bug inside
`proRataMin` itself would get past W3. Only the full-leg check runs on that
code. Lemma D restates `out * leg / fill` by hand, and it stays valid only
while that formula matches the library.

## Execution: no-regret for many venues

`SplitNoRegret` proves the no-regret certificate end to end with one venue
only. The planner checks above show that the PLAN has the right shape for
many venues. `SplitExecution.t.sol` closes the step between them: it
**executes** such a plan, through the real `_executeLegs`, against several
venues that each deliver an arbitrary amount, so any subset of legs can fail
and fall back.

Input is any plan of the shape `_waterfall` is proven to emit, with one venue
leg per venue:
- each leg is in `(0, fill]` with the pro-rata `minOut`;
- only the last leg is partial;
- any remainder is one Uniswap leg, and then the last venue leg is full.

Every run that does not revert satisfies the certificate's execution facts:

| | |
|---|---|
| C1 | every executed venue leg is exactly its planned leg (same input, `> 0`) and delivered at least `floor(out * l / fill)` |
| C2 | at most one executed leg is partial |
| C3 | the failed legs and the Uniswap leg run as ONE Uniswap swap on exactly `amountIn - Σ executed inputs`, and `amountOut == Σ deliveries + U(rem)` (or no Uniswap swap and `amountOut == Σ deliveries` when nothing remains) |

The gate half of C1 (a Uniswap witness `out * s > U(s) * fill`) is a property
of the plan, W5 above. An executed leg is exactly its planned leg, so its
witness carries over. The checks leave the Uniswap samples out on purpose:
every "is this size an earlier sample?" lookup forked the run, and the
lemma needs nothing linking the witness to `U(rem)` beyond assumption (b).

**Together:** the planner checks (the plan has this shape), this check (its
execution yields the certificate) and the lemma (the certificate implies
`amountOut >= U(amountIn)`) give no-regret for several venues. One step is
still covered end to end with a single venue only: the glue in `_planSplit`
that turns venue quotes into candidates (`_gatherCandidates`).

| Check | Venues | Result (local) |
|---|---|---|
| `check_execute_{1,2,3}` | 1, 2, 3 | PASS; 3 venues: ~1,800 paths, ~95 s (in CI) |
| `check_execute_4` | 4 | PASS, ~12,000 paths, ~12 min (local only) |
| `check_execute_5` | 5 = `MAX_LEGS` | PASS, ~80,000 paths, ~2 h (local only, see below) |

The 5-venue run explored every path. Under the default 60 s per query, 21
queries timed out. Saved and re-run alone, all 21 were `unsat` (the slowest
took ~4 min), so the check carries its own 10-minute query timeout
(`@custom:halmos`).

**Mutation-tested** (against `check_execute_2`):

| Mutation | Caught |
|---|---|
| A failed leg's input is not sent to Uniswap | yes |
| Per-leg `minOut` check removed from `_dispatchVenue` | yes |
| Uniswap's output not added to `amountOut` | yes |
| Uniswap swaps only half of the remainder | yes |
