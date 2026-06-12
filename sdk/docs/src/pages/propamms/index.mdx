# What is a PropAMM?

A proprietary AMM (propAMM, or pAMM) is an on-chain pool whose prices are
continuously updated by a market maker. Instead of deriving prices from a
passive inventory curve, the maker streams signed quote updates to a block
builder, so the pool tracks fair value in real time.

The pool itself remains a passive contract: anyone can swap against it
directly, without an off-chain layer in between. Once a maker's quote update
is included, taker interactions settle on-chain like any other AMM
interaction and compose into normal swap paths, solver transactions,
arbitrage bundles, and aggregator routes. This is the key difference from
RFQ-style institutional liquidity: pAMM liquidity sits directly inside an
on-chain venue rather than behind a separate off-chain layer.

## The problem: stale prices

A large share of DEX volume trades at prices that are stale relative to
centralized markets. On Ethereum, on-chain prices can only update once per
12-second slot, so whenever the market moves faster than the chain, a
divergence opens between the pool price and what makers consider fair value.
That divergence is value leakage: empirical analyses of mainnet swap flow
consistently find the majority of router volume executing below the
contemporaneous CEX mid, with negative markouts of several basis points on
average for larger swaps. The leakage hits everyone routing through stale
intermediary liquidity — routers, solvers, end users, and atomic searchers
alike.

A pAMM competes for that flow with tighter pricing. Because the maker's
latest quote is applied before taker flow executes, the maker can quote close
to the live market without being systematically picked off. For makers, this
collapses the adverse-selection window that makes on-chain quoting costly on
slower chains. For takers, it raises execution quality on exactly the routes
that leak the most value.

The model is already proven on faster, lower-cost chains, where pAMMs make up
the majority of major-pair spot volume. A naive port to Ethereum does not
work, though: with 12-second slots and meaningful gas costs, the last
on-chain update is already stale by the time the next taker arrives.

## How pAMMs work on Ethereum

What makes pAMMs viable on Ethereum is a sequencing guarantee enforced at the
block-builder layer — sometimes called application-controlled execution
(ACE). Without it, makers and takers face a timing dilemma: a quote posted
too early is stale by the time taker flow lands (takers profit from the
mispricing), while takers forced to commit to a route before the final block
state is known end up trading against stale prices (makers profit instead).

A builder that supports pAMM sequencing resolves this:

- Makers stream low-latency quote updates to the builder.
- Stale quote updates are replaced, so only the latest applicable quote is
  considered.
- When a taker trades against a pAMM, the latest quote update is guaranteed
  to be ordered before it in the block.
- Makers can configure freshness protection, so takers are only eligible for
  inclusion against sufficiently recent quote state.
- Takers can submit multiple candidate routes through pAMM and
  constant-function market maker (CFMM) liquidity.
- The builder evaluates candidates against live state at build time and
  re-evaluates on every quote update, right up until inclusion.

The maker gets an explicit, builder-enforced priority rule around its own
pool — covering both rank within the block and the timing relationship
between quote and taker receipts — instead of relying on public propagation
and protocol-level ordering behavior. The taker gets a place where pAMM and
CFMM pricing are compared against the latest available state. And because all
of this happens within ordinary block building, Ethereum's guarantees around
economic security, decentralization, liveness, and censorship resistance are
preserved.

## Participants

There are two sides to a pAMM, each with its own integration surface:

- **[Makers](/propamms/makers)** operate the pool and stream signed quote
  updates to the builder. Quotes can land every block, or only when there is
  taker flow against the pool.
- **[Takers](/propamms/takers)** — searchers, solvers, aggregators, and
  routers — trade against pAMM liquidity: by submitting candidate bundles,
  by consuming maker state streams to simulate routes locally, or by routing
  through an on-chain router that selects the best venue at execution time.

The SDKs documented on this site implement the taker side: they quote and
execute swaps against pAMM venues, applying fresh maker state automatically
so quotes reflect live liquidity instead of stale on-chain state.
