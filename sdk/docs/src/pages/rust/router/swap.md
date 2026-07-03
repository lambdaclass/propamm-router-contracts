# swap

Swap through the best-quoting venue (across all whitelisted venues by default, or restricted to a subset of selected venues); falls back to Uniswap V3 if the chosen venue fails to fill. Returns the transaction hash — pair with [`wait_for_swap`](/rust/router/wait_for_swap), or use `swap_and_wait` to do both in one call.

```rust
pub async fn swap(&self, params: &SwapParams) -> Result<H256>
pub async fn swap_with(&self, params: &SwapParams, opts: &SwapOptions) -> Result<H256>
pub async fn swap_and_wait(&self, params: &SwapParams) -> Result<SwapResult>
pub async fn swap_and_wait_with(&self, params: &SwapParams, opts: &SwapOptions) -> Result<SwapResult>
```

## Usage

::: code-group

```rust [example.rs]
use propamm::common::helpers::{apply_slippage, deadline_in, parse_ether};
use propamm::common::tokens::{ETH_SENTINEL, USDC};
use propamm::router::SwapParams;

let amount_in = parse_ether("1")?;
let quote = router.quote(ETH_SENTINEL, USDC, amount_in).await?;

let hash = router
    .swap(&SwapParams {
        token_in: ETH_SENTINEL,
        token_out: USDC,
        amount_in,
        amount_out_min: apply_slippage(quote.amount_out, 50)?,
        recipient: me,
        deadline: deadline_in(300),
    })
    .await?;
```

```rust [setup.rs]
use propamm::common::helpers::parse_address;
use propamm::{ContractClient, PropAmmRouter};

let client = ContractClient::connect_with_signer("https://...", "0x...")?;
let me = client.signer_address().unwrap();
let router = PropAmmRouter::new(client, parse_address("0x...")?);
```

:::

## Returns

`Result<H256>`

The transaction hash. Requires a signing client
(`ContractClient::connect_with_signer`).

## swap_with

Same, plus [`opts: &SwapOptions`](/rust/types#swapoptions) — restrict the
venues and/or charge a frontend fee.

`venues` restricts the swap: a single entry executes through that venue
directly (failing `UnknownVenue` on a non-venue address), several re-quote
on-chain and fill via the best of them. Must be non-empty when present;
`None` swaps through the best-quoting venue overall.

```rust
use propamm::common::pamms::KIPSELI;
use propamm::router::SwapOptions;

let opts = SwapOptions {
    venues: Some(vec![KIPSELI]), // exactly this venue
    ..Default::default()
};
let hash = router.swap_with(&params, &opts).await?;
```

`frontend_fee` skims a fee from the output token, paid to its `recipient`.
`bps` must be in `[1, MAX_FEE_BPS]` (100 = 1%) — validated before sending.
With a fee, `amount_out_min` is the **net** minimum the recipient must
receive after the fee, and the decoded result's `fee` field (via
[`wait_for_swap`](/rust/router/wait_for_swap)) carries the charged amount
and recipient.

```rust
use propamm::router::{FrontendFee, SwapOptions};

let opts = SwapOptions {
    frontend_fee: Some(FrontendFee { bps: 25, recipient: fee_recipient }), // 0.25%
    ..Default::default()
};
let hash = router.swap_with(&params, &opts).await?;
```

`gas_limit` sets an explicit transaction gas limit, overriding the per-function
default described below.

```rust
use propamm::router::SwapOptions;

let opts = SwapOptions { gas_limit: Some(800_000), ..Default::default() };
let hash = router.swap_with(&params, &opts).await?;
```

## Gas limits

Swaps attach a **hardcoded per-function gas limit** and skip node gas
estimation. Estimation runs against the current state, but the swap can take a
heavier branch when it executes, so an estimate can under-shoot and the
transaction runs out of gas. The hardcoded limits sit above the worst observed
branch (plus headroom), and are tiered by how much quoting each entrypoint does
on-chain (a single named venue is cheapest; the all-venues requote is highest).

Pass [`SwapOptions.gas_limit`](/rust/types#swapoptions) to override the default
for a call.

## swap_and_wait

Same parameters; additionally waits for the receipt and decodes the outcome.
Returns [`SwapResult`](/rust/router/wait_for_swap#returns) —
`swap_and_wait_with` is the options-taking twin.

```rust
let result: SwapResult = router.swap_and_wait(&params).await?;
```

## Parameters

### params

- **Type:** [`&SwapParams`](/rust/types#swapparams)

The parameters shared by every swap entrypoint — see the type for
field-by-field docs. Derive `amount_out_min` from a quote with
`apply_slippage`, and `deadline` with `deadline_in`.

```rust
let params = SwapParams {
    // ...
    amount_out_min: apply_slippage(quote.amount_out, 50)?, // quote - 0.5%
};
```
