# PropAMM Rust SDK

SDK for interacting with the `PropAMMRouter` contract over JSON-RPC, built
entirely on [rex](https://github.com/lambdaclass/rex) /
[ethrex](https://github.com/lambdaclass/ethrex): `EthClient` transport,
signing, `eth_call` overrides, and ABI encoding/decoding via ethrex's
calldata codec (signature strings; selectors are regression-tested against
`forge inspect PropAMMRouter methodIdentifiers`). Mirrors the TypeScript SDK
(`../typescript`): same surface, snake_case names, no on-chain `V1` suffix.

rex's `StateOverrideSet` and `BlockOverrideSet` are re-exported, and all
`eth_call`s go through rex's `call_with_overrides`. rex flattens revert data
into its error string; the client recovers the payload from the
`" (data: 0x…)"` suffix so reverts still decode into named contract errors —
if rex ever exposes the data structurally, that parsing can go away.

## Setup

```sh
cargo build
cargo test       # incl. ABI selector regression tests
cargo clippy
cargo fmt --check
```

## Getting started

Quote and swap 1 ETH for USDC through the best venue:

```rust
use propamm::common::helpers::{apply_slippage, deadline_in, parse_ether};
use propamm::common::tokens::{ETH_SENTINEL, USDC};
use propamm::router::SwapParams;
use propamm::{ContractClient, PropAmmRouter};

let client = ContractClient::connect_with_signer("https://...", "0x...")?;
let me = client.signer_address().unwrap();
let router = PropAmmRouter::new(client, "0x...".parse()?); // deployed router proxy

let amount_in = parse_ether("1")?;
let quote = router.quote(ETH_SENTINEL, USDC, amount_in).await?;

let result = router
    .swap_and_wait(&SwapParams {
        token_in: ETH_SENTINEL,
        token_out: USDC,
        amount_in,
        amount_out_min: apply_slippage(quote.amount_out, 50)?, // quote - 0.5%
        recipient: me,
        deadline: deadline_in(300), // now + 5 min
    })
    .await?;
println!("received {} USDC via {}", result.amount_out, result.executed_venue);
```

A runnable version lives in [`examples/getting_started.rs`](examples/getting_started.rs):

```sh
cargo run --example getting_started
```

It defaults to a local anvil mainnet fork with anvil's funded account and the
mainnet router deployment; override with `RPC_URL` / `PRIVATE_KEY` /
`ROUTER_ADDRESS` / `SLIPPAGE_BPS`.

## State overrides

The pAMM venues price off-chain liquidity that on-chain state does not
reflect, so a plain `eth_call` quote sees stale prices. Titan publishes fresh
state overrides, and quotes apply them automatically: the simulation carries
the overrides plus their block number/timestamp so venues price their pushed
state instead of the chain's.

Two sources implement the `OverridesSource` trait; both need no authentication:

- `OverridesWsSource` — streams `wss://rpc.titanbuilder.xyz/ws/pamm_quote_stream`,
  caching per-pAMM entries across frames and reconnecting with backoff. This
  is the **default**: a router built with `PropAmmRouter::new` creates one
  (connecting lazily on the first quote). The connection auto-closes after an
  idle window without quotes (`idle_timeout`, default 30s) and reconnects
  transparently, so no teardown is needed.
- `OverridesRpcSource` — calls `titan_getPammStateOverrides` over HTTP on
  each quote. No connection to manage.

```rust
use std::sync::Arc;
use propamm::overrides::{OverridesRpcSource, OverridesWsSource};
use propamm::router::{QuoteOptions, QuoteOverrides};

// default: streaming WS source created automatically
let router = PropAmmRouter::new(client, router_address);

// or attach a source explicitly
let router = PropAmmRouter::with_overrides(client, router_address, Arc::new(OverridesRpcSource::default()));

// per-call control
let opts = QuoteOptions { overrides: QuoteOverrides::Skip, ..Default::default() };
let stale = router.quote_with(WETH, USDC, amount_in, &opts).await?;
```

When a snapshot has no Bebop entry, a default slot override zeroes Bebop's
price so a stale on-chain quote can't win venue selection (disable with
`skip_bebop_default`). The Uniswap V3 fallback quoter only reads live pool
state, so pAMM overrides never affect it (pin it via
`venues: Some(vec![router.fallback_swap_router().await?])` if needed).
Custom state diffs go through `ContractClient::call` with `CallOverrides`
directly.

Admin functions (`addVenue`, `pause`, `setPairFee`, ...) have no typed
methods, but their signatures are in the ABI module — encode and send them
through the generic client:

```rust
use propamm::router::abi::{self, Value};
use ethrex_l2_sdk::calldata::encode_calldata;

let calldata = encode_calldata(abi::ADD_VENUE, &[Value::Address(venue)])?;
let hash = client.send(router_address, calldata, None).await?;
```

## Price levels

Alongside the raw state overrides, Titan publishes prices it has *already
quoted*, grouped per pAMM: for each pair, an `order_book` of rungs mapping an
input amount to the output it would receive. This lets a taker read prices
across a range of trade sizes without an `eth_call` per size. Rungs are either
`Simulated` (from an EVM simulation) or `Interpolated` (a linear spline between
simulated rungs, for finer granularity).

The `PriceLevels` client wraps it, mirroring `PropAmmRouter`: a single type with
a default snapshot source you can override.

```rust
use propamm::common::helpers::parse_units;
use propamm::common::tokens::{USDC, WETH};
use propamm::prices::PriceLevels;

let prices = PriceLevels::new(); // default: one-shot HTTP snapshot source

let snapshot = prices.get_price_levels().await?;
// snapshot.pamms[i].pairs[j].order_book -> [{ amount_in, amount_out, variant }, ...]

// Quote helpers are served from Titan's latest snapshot over HTTP, skipping the
// on-chain eth_call that router.quote runs.
let best = prices.get_quote(USDC, WETH, parse_units("1000", 6)?).await?;
// TitanQuote { token_in, token_out, amount_in, amount_out, pamm, router, block_number, slot, .. }
let pinned = prices.get_quote_venue(best.pamm, USDC, WETH, parse_units("1000", 6)?).await?;
```

The snapshot source defaults to a `PriceLevelsRpcSource` (one
`titan_getPammPriceLevels` call per `get_price_levels`). For a live feed, pass a
`PriceLevelsWsSource` instead — it streams complete snapshots, reconnects with
backoff, and idle auto-closes, like `OverridesWsSource`. The stream is served
from regional hosts (`eu.`, `ap.`, `us.`); pick the nearest:

```rust
use std::sync::Arc;
use propamm::prices::{PriceLevels, PriceLevelsWsSource, PriceLevelsWsSourceConfig};

let ws = PriceLevelsWsSource::new(PriceLevelsWsSourceConfig {
    url: "wss://eu.rpc.titanbuilder.xyz/ws/pamm_price_levels".into(),
    ..Default::default()
});
let prices = PriceLevels::with_source(Arc::new(ws));
let snapshot = prices.get_price_levels().await?; // served from the live stream
prices.close(); // close the stream socket when done (no-op for the HTTP default)
```

Passing a `PriceLevelsRpcSource` with a custom URL to `with_source` instead
points both the snapshots and the quote helpers at that endpoint (the quotes are
HTTP-only).

A runnable version lives in [`examples/price_levels.rs`](examples/price_levels.rs)
(`cargo run --example price_levels`; override the HTTP endpoint with `PRICE_LEVELS_URL`).

## Layout

- `src/client.rs` — rex/ethrex-based contract client (`call` with state/block overrides, `send`, `wait_for_transaction`).
- `src/router/mod.rs` — `PropAmmRouter` bindings (`quote`/`quote_with`, `swap`/`swap_with`, `swap_and_wait`(`_with`), `wait_for_swap`, `approve`/`allowance`, views) plus `MAX_FEE_BPS`.
- `src/router/abi.rs` — hand-rolled `PropAMMRouter` ABI: signature constants (selector-tested), return/event decoding, and the custom-error table.
- `src/overrides/mod.rs` — pAMM state-override sources (`OverridesWsSource`, `OverridesRpcSource`), payload parsing, and `to_state_override`.
- `src/prices/mod.rs` — `PriceLevels` client plus its swappable snapshot sources (`PriceLevelsWsSource`, `PriceLevelsRpcSource`), snapshot parsing, and the Titan quote helpers (`get_quote`, `get_quote_venue`).
- `src/common/tokens.rs` — `ETH_SENTINEL` and mainnet token addresses.
- `src/common/pamms.rs` — pAMM venue addresses.
- `src/common/helpers.rs` — `apply_slippage`, `deadline_in`, `parse_address`, and unit conversion (`parse_ether`, `parse_units`, `format_ether`, `format_units`).

The on-chain quote functions are nonpayable (not view), so the bindings call
them through `eth_call` simulation (`ContractClient::call`) rather than a
plain read.
