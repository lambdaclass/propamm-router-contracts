# Swaps

All swap entrypoints share `SwapParams`:

```rust
pub struct SwapParams {
    pub token_in: Address,       // or ETH_SENTINEL for native ETH
    pub token_out: Address,      // or ETH_SENTINEL
    pub amount_in: U256,         // atomic units
    pub amount_out_min: U256,    // net of fee on the with_fee paths
    pub recipient: Address,
    pub deadline: U256,          // unix timestamp — see deadline_in()
}
```

The six entrypoints mirror the contract (names drop the on-chain `V1`
suffix) and return the transaction hash:

| Method | Routing |
|---|---|
| `swap(&params)` | best-quoting venue |
| `swap_with_fee(&params, fee)` | best venue + frontend fee |
| `swap_via_venue(venue, &params)` | explicit venue (or the fallback router) |
| `swap_via_venue_with_fee(venue, &params, fee)` | explicit venue + fee |
| `swap_via_selected_venues(venues, &params)` | best of a subset |
| `swap_via_selected_venues_with_fee(venues, &params, fee)` | subset + fee |

Each has a `_and_wait` variant that waits for the receipt and decodes the
result in one call; or do it in two steps:

```rust
let hash = router.swap(&params).await?;
let result = router.wait_for_swap(hash).await?;
// SwapResult { hash, receipt, amount_in, amount_out, executed_venue, recipient, fee }
```

`wait_for_swap` decodes the router's `Swapped` event (and
`FrontendFeeCharged` when present — `result.fee` carries the recipient and
amount). It fails if the transaction reverted or emitted no `Swapped` event.

## Token inputs

- **ERC-20 input** requires a prior allowance for the router:

  ```rust
  router.approve(USDC, amount_in).await?;            // approve(token, amount)
  router.allowance(USDC, me).await?;                 // check current allowance
  ```

- **Native ETH input**: pass `ETH_SENTINEL` as `token_in` — the SDK attaches
  `msg.value = amount_in` automatically. No approval needed. `ETH_SENTINEL`
  as `token_out` delivers native ETH.

## Frontend fees

The `_with_fee` variants skim a fee from the output token. Build the fee with
the validated helper (`bps` capped at `MAX_FEE_BPS = 100`, recipient must be
non-zero); `amount_out_min` is the **net** minimum the recipient must receive:

```rust
use propamm_sdk::router::frontend_fee;
router.swap_with_fee(&params, frontend_fee(25, fee_recipient)?).await?; // 0.25%
```

## Helpers

```rust
use propamm_sdk::common::helpers::{apply_slippage, deadline_in, parse_units};

let amount_in = parse_units("100", 6)?;                   // 100 USDC
let min_out = apply_slippage(quote.amount_out, 50)?;      // quote - 0.5%
let deadline = deadline_in(300);                          // now + 5 min
```

## Admin functions

`addVenue`, `pause`, `setPairFee`, ... have no typed methods, but their
signatures are in the ABI module — encode and send through the generic
client:

```rust
use propamm_sdk::router::abi::{self, Value};
use ethrex_l2_sdk::calldata::encode_calldata;

let calldata = encode_calldata(abi::ADD_VENUE, &[Value::Address(venue)])?;
let hash = client.send(router_address, calldata, None).await?;
```
