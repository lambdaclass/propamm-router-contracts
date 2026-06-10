# PropAMM Rust SDK

SDK for interacting with the `PropAMMRouter` contract over JSON-RPC, built on
[rex](https://github.com/lambdaclass/rex) / [ethrex](https://github.com/lambdaclass/ethrex)
for the transport (`EthClient`, signing, state overrides) with alloy's `sol!`
macro kept for the typed ABI surface (calls, events, errors — for now).
Mirrors the TypeScript SDK (`../typescript`): same surface, snake_case names,
no on-chain `V1` suffix.

rex's `StateOverrideSet` and `BlockOverrideSet` are re-exported, and all
`eth_call`s go through rex's `call_with_overrides` (rex pinned to the main
commit that merged eth_call overrides, until a tag is cut). rex flattens revert data
into its error string; the client recovers the payload from the
`" (data: 0x…)"` suffix so reverts still decode into named contract errors —
if rex ever exposes the data structurally, that parsing can go away.

## Setup

```sh
cargo build
cargo clippy
cargo fmt --check
```

## Getting started

Quote and swap 1 ETH for USDC through the best venue:

```rust
use propamm_sdk::common::helpers::{apply_slippage, deadline_in, parse_ether};
use propamm_sdk::common::tokens::{ETH_SENTINEL, USDC};
use propamm_sdk::router::SwapParams;
use propamm_sdk::{ContractClient, PropAmmRouter};

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
use propamm_sdk::overrides::{OverridesRpcSource, OverridesWsSource};
use propamm_sdk::router::{QuoteOptions, QuoteOverrides};

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
`skip_bebop_default`). `quote_uniswap_v3` never applies overrides — the
fallback quoter only reads live pool state. Custom state diffs go through
`ContractClient::call` with `CallOverrides` directly.

Admin functions (`addVenue`, `pause`, `setPairFee`, ...) have no typed
methods, but their call types are in the generated ABI bindings — send them
through the generic client:

```rust
use propamm_sdk::router::abi::IPropAMMRouter;

let hash = client
    .send(router_address, &IPropAMMRouter::addVenueCall { venue }, None)
    .await?;
```

## Layout

- `src/client.rs` — rex/ethrex-based contract client (`call` with state/block overrides, `send`, `wait_for_transaction`).
- `src/convert.rs` — conversions between alloy primitives (ABI surface) and ethrex primitives (transport).
- `src/router/mod.rs` — `PropAmmRouter` bindings (quotes, swaps, `*_and_wait` variants, `wait_for_swap`, `approve`/`allowance`, views) plus `frontend_fee` and `MAX_FEE_BPS`.
- `src/router/abi.rs` — `sol!`-generated `PropAMMRouter` ABI (functions, events, errors).
- `src/overrides/mod.rs` — pAMM state-override sources (`OverridesWsSource`, `OverridesRpcSource`), payload parsing, and `to_state_override`.
- `src/common/tokens.rs` — `ETH_SENTINEL` and mainnet token addresses.
- `src/common/pamms.rs` — pAMM venue addresses.
- `src/common/helpers.rs` — `apply_slippage`, `deadline_in`, and unit conversion re-exports (`parse_ether`, `parse_units`, `format_ether`, `format_units`).

The on-chain quote functions are nonpayable (not view), so the bindings call
them through `eth_call` simulation (`ContractClient::call`) rather than a
plain read.
