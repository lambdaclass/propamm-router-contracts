# Symbolic checks (Halmos)

Properties of the split / multi-leg path (`swapSplitV1`) proven over the real
router bytecode with [Halmos](https://github.com/a16z/halmos), for **every**
input and every behaviour of the venues, within stated bounds.

## Running

```sh
uv tool install halmos==0.3.3              # once; needs Python >= 3.11

FOUNDRY_PROFILE=halmos halmos              # all checks, incl. the slow two-venue one
FOUNDRY_PROFILE=halmos halmos --function check_noRegretCertificate_oneVenue

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

**Bounds.** The Halmos half is **verified with one whitelisted venue**
(3,123 paths, about 4 minutes locally), with arbitrary amounts up to
`uint128` and arbitrary venue quotes and deliveries. The two-venue check
(`check_noRegretCertificate_twoVenues`) exists but does **not** finish: it ran
out a 2-hour limit with no result, so CI skips it. The lemma holds for any
number of legs up to `MAX_LEGS`.

**Mutation-tested.** The checks fail when the code is broken in the ways they
are meant to catch:

| Mutation | Caught by |
|---|---|
| `_waterfall` gate removed (every candidate placed) | Halmos certificate (C1) |
| Refined reference quoted at twice the remainder (`s > amountIn`) | Halmos certificate (C1) |
| Full-leg `proRataMin` one wei short | Halmos certificate (C1) |
| Lemma without `s <= amountIn` | Z3 lemma A |
| Lemma allowing more than one partial leg | Z3 lemma C |
