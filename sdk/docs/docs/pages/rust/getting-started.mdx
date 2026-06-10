# Getting started

The Rust SDK lives in `sdk/rust` (`propamm-sdk`), built entirely on
[rex](https://github.com/lambdaclass/rex) /
[ethrex](https://github.com/lambdaclass/ethrex): `EthClient` transport,
signing, `eth_call` overrides, and ABI encoding/decoding via ethrex's
calldata codec. Same surface as the TypeScript SDK, in snake_case, without
the on-chain `V1` suffix.

```sh
cd sdk/rust
cargo build
cargo test   # incl. ABI parity tests against the compiled contract
```

## Quote and swap

```rust
use propamm_sdk::common::helpers::{
    apply_slippage, deadline_in, format_units, parse_address, parse_ether,
};
use propamm_sdk::common::tokens::{ETH_SENTINEL, USDC};
use propamm_sdk::router::SwapParams;
use propamm_sdk::{ContractClient, PropAmmRouter};

let client = ContractClient::connect_with_signer("https://...", "0x<private key>")?;
// ContractClient::connect("https://...") for a read-only client
let me = client.signer_address().unwrap();
let router = PropAmmRouter::new(client, parse_address("0x...")?); // deployed router proxy

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
println!(
    "received {} USDC via {:#x}",
    format_units(result.amount_out, 6),
    result.executed_venue
);
```

The quote already reflects fresh off-chain liquidity — pAMM state overrides
are applied automatically. Native ETH input is signalled with `ETH_SENTINEL`
(no ERC-20 approval needed; `msg.value` is attached automatically).

## Runnable example

```sh
cargo run --example getting_started
```

It defaults to a local anvil mainnet fork with anvil's funded account and the
mainnet router deployment; override with `RPC_URL` / `PRIVATE_KEY` /
`ROUTER_ADDRESS` / `SLIPPAGE_BPS`.

## Checks

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
```

The test suite includes a two-direction ABI parity test against the Foundry
artifact: every SDK signature must exist in the contract, and every contract
function/event/error must be bound or explicitly allowlisted. Run
`forge build` at the repo root first so the artifact exists (the test skips
with a notice otherwise; CI requires it).
