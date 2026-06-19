# Takers

Takers are searchers, solvers, aggregators, and routers that trade against
pAMM liquidity. Because a pAMM's real price lives in the maker's quote stream
rather than in committed on-chain state, taking against one well means
solving a freshness problem: the state you simulate against must be as close
as possible to the state your trade will execute against. There are three
complementary integration patterns.

## Multi-candidate bundle submission

Rather than committing to a single route before the final block state is
known, a taker can submit several candidate bundles for the same trade, each
routing differently:

- Construct the normal path through CFMM liquidity.
- Construct additional variants where one or more hops route through pAMMs.
- Submit all variants through the builder's regular bundle path.

The builder evaluates every candidate against live state at build time —
including the freshest streamed quote from every pAMM — and includes
whichever gives the best outcome, re-evaluating on every quote update until
inclusion. The taker never has to predict which venue will be best at
execution time; the builder resolves it with information the taker cannot
have when constructing the bundle.

## pAMM state streams

Makers can opt in to publishing their live quote state as **Ethereum state
override objects** — the same structure as the `eth_call` state override
set. This gives takers fresher routing inputs for local simulation before
submitting anything.

A state stream message keys overrides by account address. Each account
override may include `balance`, `nonce`, `code`, `state`, and `stateDiff`,
where `stateDiff` maps storage slots to overridden values:

```json
{
  "blockNumber": 25051224,
  "0x<pamm-address>": {
    "stateOverride": {
      "0x<oracle-address>": {
        "stateDiff": {
          "0x<storage-slot>": "0x<value>"
        }
      }
    }
  }
}
```

The `stateOverride` object can be passed directly as the third parameter to
`eth_call` or `eth_simulateV1`, so a quote simulated locally reflects the
maker's latest streamed price instead of the last price committed on-chain.
When a taker has access to multiple maker feeds, the entries merge into a
single flat object keyed by account address.

Streams are typically offered in two forms: a push feed (e.g. WebSocket) for
takers that want every update, and a request/response snapshot (e.g. a
JSON-RPC method) for takers that only need the latest flattened view on
demand. Some maker streams are public; others are permissioned to whitelisted
consumers such as aggregators.

This is the mechanism the SDKs on this site use under the hood: quotes are
issued via `eth_call` with fresh overrides applied automatically, sourced
from a stream ([`OverridesWsSource`](/typescript/overrides/ws-source)) or an
on-demand snapshot ([`OverridesRpcSource`](/typescript/overrides/rpc-source)).

## On-chain routing

The third pattern moves route selection into the execution transaction
itself. Instead of submitting a single pre-selected path, the transaction
carries multiple candidate venues per hop — some through standard CFMM
liquidity, some through pAMMs — and an on-chain router evaluates the
candidate set against the exact execution state, selecting the best valid
combination.

This is especially attractive for pAMM routing because quote state can change
between path construction and inclusion. If a maker update lands earlier in
the same block, the router sees the updated state when the taker transaction
executes — no stale commitment, no failed assumption about which venue would
win.

The [`PropAMMRouter`](/propamms/router) contract documented on this site
implements this pattern for single-hop swaps: it requotes every venue
on-chain at execution time, routes through the best one, and falls back to a
CFMM if the chosen venue cannot fill.
