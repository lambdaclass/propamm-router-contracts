# Makers

A pAMM maker operates the pool and oracle contracts on-chain and keeps them
priced by streaming signed quote-update transactions to a block builder. The
transport details (endpoints, message schema, authentication) vary by
builder; the behavioral properties below are what define the pAMM model from
the maker's side.

## Sequencing guarantees

The builder provides two defenses against being picked off on latency.

### Taker ordering

When a taker trade against the pool is included in a block, the latest
applicable quote update is guaranteed to be placed before it in the same
block. The taker always executes against the freshest quote the maker
managed to deliver, never against an already-replaced one.

### Freshness protection

A per-maker freshness buffer `b` can be applied to takers routing against
the pool. A taker is only eligible to trade against a quote update if the
taker was received by the builder at least `b` before that quote update was
received:

```
taker_recv + b < quote_update_recv
```

For example, with `b = 50ms`, a quote update received at time `T` can only be
sequenced against takers received before `T - 50ms`.

This reduces exposure to toxic takers attempting to snipe stale quotes, and
also protects the maker if quote streaming fails mid-slot: takers arriving
after the last quote landed are simply not matched against it.

## Quote lifecycle

Quote updates follow a replacement model rather than an append-only one:

- Each quote stream carries a **replacement identifier** and a **monotonic
  sequence number**. A new update under the same identifier with a higher
  sequence number replaces the previous one; the builder only ever considers
  the latest.
- Updates target a **specific block**, so a quote never outlives the state it
  was priced against.
- **Cancellation** is a replacement with an empty payload: send the same
  identifier with a higher sequence number and no transaction, and the quote
  is pulled.

Because replacement and cancellation are first-class, makers can re-quote
aggressively without accumulating stale orders, much like quoting on a
central limit order book.

## Conditional inclusion

Quote updates can land every block, or only when a taker in the block
actually trades against the pool. In conditional mode, the builder evaluates
every candidate taker against every live quote and includes the latest quote
update immediately before any taker that matches — quotes with no takers
never go on-chain. The maker can keep the pool continuously priced without
paying for blocks in which nothing fills.

## Economics

How quote inclusion is priced is builder-specific. The prevailing model is
that quote updates do not bid priority fees per update; instead, the maker
pays a volume-based fee on filled trades, typically configured per pair.
This aligns the cost of quoting with realized flow rather than with update
frequency.

## Toward permissionless access

The sequencing guarantees described here are currently negotiated between
makers and individual builders. There are ongoing efforts to standardize and
open them permissionlessly — see, for example, the
[priority update registry](https://github.com/flashbots/priority-update-registry)
proposal — so that any maker can obtain the same priority rules around its
pool without a bespoke integration.
