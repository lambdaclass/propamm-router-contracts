# PropAMMRouter

`PropAMMRouter` is an on-chain, single-hop router that quotes and executes
swaps across pAMM venues, with Uniswap V3 as the fallback. It is the concrete
implementation of the [on-chain routing](/propamms/takers#on-chain-routing)
pattern: venue selection happens inside the swap transaction itself, against
the exact state the trade settles in.

## Why route on-chain

A pAMM's price is whatever the maker's latest included quote update says it
is — and that state can change between the moment a route is constructed and
the moment the transaction is included. A taker that pre-selects a venue
off-chain commits to a price it cannot guarantee will still exist: if a
maker update lands earlier in the same block, the pre-priced route is either
no longer the best one or no longer fillable at all.

Inclusion is not even guaranteed to happen in a pAMM-aware block. The
transaction can end up in a block produced by a builder without pAMM
support, or by no MEV builder at all (a locally built block, for instance).
In such a block no fresh maker quote lands ahead of the swap, so the pAMMs
quote stale state or cannot fill — and a route hard-wired to a pAMM venue
would simply revert.

There is also a plumbing problem. Each pAMM is its own contract with its own
interface, quoting mechanism, and failure modes. Without a router, every
integrator writes one adapter per venue and re-quotes them all off-chain on
every trade — and still ends up exposed to the two problems above.

The router addresses all of this: one contract, one call, with the venue
decision deferred to execution time — and a swap that lands in a block
without pAMM support still fills through the fallback.

## What it does

On a swap, the router:

1. **Requotes every venue on-chain**, in the same transaction: each
   whitelisted pAMM plus the Uniswap V3 fallback.
2. **Routes through the best-quoting venue.**
3. **Falls back to Uniswap V3 transparently** if the chosen pAMM reverts or
   under-delivers, so a swap never fails just because a maker's liquidity
   moved between quoting and execution.
4. **Verifies the outcome itself**: delivered output is measured as the
   recipient's balance delta — venue return values are not trusted — and the
   swap reverts unless that delta meets the caller's `amountOutMin` before
   the caller's `deadline`.

For a taker, this buys four things:

- **Execution-time pricing.** The venue is chosen against the state the
  trade actually executes in. If a maker update lands earlier in the same
  block, the swap prices against it automatically — no stale commitment.
- **Best-of-all-venues with one integration.** A single call covers every
  whitelisted pAMM and the CFMM fallback; new venues are picked up as they
  are listed, with no integrator-side changes.
- **Fail-safe fills.** The fallback acts as an execution-time safety net,
  turning "the maker moved" from a revert into a slightly different fill.
- **Trust-minimized accounting.** Slippage and deadline guarantees are
  enforced by the router from observed balance changes, not by the venues.

### Choosing venues

The default swap considers the whole whitelist, but callers can narrow it:

- **Pin a single venue** — execute through exactly that venue, with the
  Uniswap V3 fallback still applying if it cannot fill.
- **Restrict to a subset** — the on-chain requote runs across only the
  listed venues and the best one fills.

Every swap entrypoint also has a **frontend-fee variant** that skims a
basis-point fee from the output token to a caller-specified recipient, for
integrators monetizing order flow. `amountOutMin` remains the net minimum
the user receives after the fee.

## Quoting

The quote functions mirror the swap ones: best across all venues, a single
venue, or a subset. Two things to know:

- **Quotes are simulations, not views.** Some venues can only be priced by
  simulating a real swap and reverting with the result, so the quote
  functions are nonpayable and must be called through `eth_call`, where the
  simulated state is rolled back automatically.
- **Accurate quotes need maker state.** pAMM liquidity is driven by
  off-chain quote streams; a plain `eth_call` sees only the last update
  committed on-chain. To quote what would actually execute, the call must
  carry the maker [state overrides](/propamms/takers#pamm-state-streams) as
  its state override set.

The SDKs handle both automatically — quotes go through `eth_call` with fresh
overrides applied, sourced from a stream
([`OverridesWsSource`](/typescript/overrides/ws-source)) or an on-demand
snapshot ([`OverridesRpcSource`](/typescript/overrides/rpc-source)).

## Safety and operations

The venue whitelist, the fallback configuration, and every other
administrative surface sit behind an access manager with role-specific
timelocks, so any change is publicly queued on-chain before it takes
effect. Swaps can be paused instantly as a circuit breaker — quoting remains
callable while paused. The Uniswap V3 fallback prices each pair at a
contract-resolved fee tier (a per-pair override or a global default), so
callers never supply one.

## Using it

The TypeScript and Rust SDKs wrap the full surface — quoting with fresh
overrides, swap construction, venue selection, and result decoding:

- [TypeScript: getting started](/typescript/getting-started)
- [Rust: getting started](/rust/getting-started)

Integrators that prefer to call the contract directly can encode against the
`IPropAMMRouter` interface; the SDK [quote](/typescript/router/quote) and
[swap](/typescript/router/swap) pages document the semantics shared by both
paths.
