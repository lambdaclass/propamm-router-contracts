# Getting started

Once the SDK is [installed](/rust/installation), a quote and swap is a client,
a router, and two calls.

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
