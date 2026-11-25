"""The arithmetic half of the split's no-regret proof, over unbounded integers.

`SplitNoRegret.t.sol` (Halmos) proves that every split run satisfies a
CERTIFICATE about its legs. This script proves that the certificate, plus the
assumption on the Uniswap fallback, implies

    amountOut >= U(amountIn)

It is split from the Halmos check because the implication needs nonlinear
reasoning (chains of products) that bit-vector solvers cannot finish, while
Z3's nonlinear integer arithmetic can. Integers are sound here: the Halmos side
runs under the router's own bounds (amounts and quotes <= uint128), so no
product in the certificate wraps in uint256.

Run:  python3 test/halmos/no_regret_lemma.py   (needs `z3-solver`; Halmos ships it)

Names:
  a      amountIn                    ua    U(a), Uniswap's output for the whole order
  rem    input that went to Uniswap  urem  U(rem), what it paid (0 when rem == 0)
  per successful venue leg i:
  fill, out  the candidate quote that ranked it (fill -> out)
  s, q       the Uniswap reference in force when it was placed: q = U(s)
  l          its input            d   what it delivered

The lemma is proven in three pieces so each solver query stays small:

  A  full leg    (l == fill):  gate + avg-rate(s, a)  =>  d*a > ua*l
  B  partial leg (l <  fill):  gate + avg-rate(s, a)  =>  (d+1)*a > ua*l
  C  combine k legs, at most one partial, plus avg-rate(rem, a)  =>  Σd + urem >= ua
"""

import sys

from z3 import And, If, Implies, Int, Ints, Not, Solver, Sum, sat, unsat

MAX_LEGS = 5


def leg_vars(i):
    return Ints(f"fill{i} out{i} s{i} q{i} l{i} d{i}")


def avg_rate_non_increasing(x, ux, y, uy):
    """THE assumption on Uniswap, between sizes x and y: the average rate
    U(x)/x never improves with size. Assumed HERE only: the Halmos half makes
    no assumption about Uniswap's prices beyond (a) and (c)."""
    return And(Implies(x <= y, ux * y >= uy * x), Implies(y <= x, uy * x >= ux * y))


def gate(a, fill, out, s, q):
    """What the CODE guarantees about a placed leg (the certificate)."""
    return And(
        fill > 0,
        out >= 0,
        s > 0,
        q >= 0,
        s <= a,  # every reference size is <= amountIn
        out * s > q * fill,  # the gate: rate(venue) > U(s)/s
    )


def gate_and_assumption(a, ua, fill, out, s, q):
    return And(gate(a, fill, out, s, q), avg_rate_non_increasing(s, q, a, ua))


def prove(name, hypotheses, goal):
    solver = Solver()
    solver.add(hypotheses)
    solver.add(Not(goal))
    result = solver.check()
    ok = result == unsat
    print(f"{'PASS' if ok else 'FAIL'}  {name}  ({result})")
    if result == sat:
        print("  counterexample:", solver.model())
    return ok


def lemma_a():
    a, ua = Ints("a ua")
    fill, out, s, q, l, d = leg_vars(0)
    hyp = And(
        a > 0,
        ua >= 0,
        gate_and_assumption(a, ua, fill, out, s, q),
        l == fill,
        d >= out,  # proRataMin(out, fill, fill) == out
    )
    return prove("A  full leg beats U(a)/a", hyp, d * a > ua * l)


def lemma_b():
    a, ua = Ints("a ua")
    fill, out, s, q, l, d = leg_vars(0)
    hyp = And(
        a > 0,
        ua >= 0,
        gate_and_assumption(a, ua, fill, out, s, q),
        l > 0,
        l < fill,
        d >= 0,
        (d + 1) * fill > out * l,  # d >= floor(out*l/fill)
    )
    return prove("B  partial leg loses < 1 wei", hyp, (d + 1) * a > ua * l)


def lemma_c(k):
    """Combination for k successful legs, using A and B as hypotheses."""
    a, ua, rem, urem = Ints("a ua rem urem")
    ls = [Int(f"l{i}") for i in range(k)]
    ds = [Int(f"d{i}") for i in range(k)]
    partial = [Int(f"p{i}") for i in range(k)]  # 1 if leg i is the partial one

    hyp = [a > 0, ua >= 0, rem >= 0, urem >= 0]
    hyp.append(rem == a - Sum(ls) if k else rem == a)
    for i in range(k):
        hyp += [ls[i] > 0, ds[i] >= 0, Or01(partial[i])]
        # Lemma A or B, whichever applies.
        hyp.append(If(partial[i] == 1, (ds[i] + 1) * a > ua * ls[i], ds[i] * a > ua * ls[i]))
    if k:
        hyp.append(Sum(partial) <= 1)
    # Uniswap's share: avg-rate(rem, a) when it runs; nothing when rem == 0.
    hyp.append(If(rem == 0, urem == 0, avg_rate_non_increasing(rem, urem, a, ua)))

    total = (Sum(ds) if k else 0) + urem
    return prove(f"C  {k} leg(s): amountOut >= U(a)", And(hyp), total >= ua)


def Or01(x):
    return And(x >= 0, x <= 1)


def main():
    ok = all([lemma_a(), lemma_b()])  # run both, so every result prints
    for k in range(MAX_LEGS + 1):
        ok = lemma_c(k) and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
