# get_quotes

Every whitelisted venue that actually prices a pair right now, best output
first.

Each venue is quoted on its own through `quoteVenueV1`, which propagates the
venue's revert. Quoting them together would go through
`quoteSelectedVenuesV1`, which falls back to Uniswap and would report every
venue as alive. Venues that revert or quote zero are dropped, so the result
doubles as the venue list for a [`swap`](/rust/router/swap) restricted with
`venues` — the gas saving of skipping the venues that cannot serve the pair.

All venues price against a single overrides snapshot, so their outputs are
comparable; resolving overrides per venue would mix blocks.

```rust
pub async fn get_quotes(&self, token_in: Address, token_out: Address, amount_in: U256) -> Result<Vec<Quote>>
pub async fn get_quotes_with(&self, token_in: Address, token_out: Address, amount_in: U256, opts: &QuoteOptions) -> Result<Vec<Quote>>
```

## Usage

::: code-group

```rust [example.rs]
use propamm::common::helpers::parse_ether;
use propamm::common::tokens::{ETH_SENTINEL, USDC};

let quotes = router
    .get_quotes(ETH_SENTINEL, USDC, parse_ether("1")?)
    .await?;
let venues: Vec<_> = quotes.iter().map(|quote| quote.venue).collect();
```

```rust [setup.rs]
use propamm::{ContractClient, PropAmmRouter};

let client = ContractClient::connect("https://...")?;
let router = PropAmmRouter::new(client, parse_address("0x...")?);
```

:::

## Returns

`Vec<`[`Quote`](/rust/types#quote)`>`

One entry per venue that priced the pair, sorted by `amount_out` descending.
Empty when no venue serves it — unlike [`quote`](/rust/router/quote), this
never falls back to Uniswap, so an empty vector means exactly that.

A venue that fails for any reason other than `Error::Revert` — a transport
error, a node failure — returns the error instead of being dropped, so the
list never silently shortens.

## Parameters

### token_in

- **Type:** `Address`

Address of the token being sold, or `ETH_SENTINEL` for native ETH.

### token_out

- **Type:** `Address`

Address of the token being bought, or `ETH_SENTINEL` for native ETH.

### amount_in

- **Type:** `U256`

Exact input amount, in atomic units. Venues quote against depth, so the set
that answers depends on the size.

### opts

- **Type:** [`QuoteOptions`](/rust/types#quoteoptions)

Per-call quote options on `get_quotes_with`, with the same `overrides` and
`skip_bebop_default` semantics as [`quote`](/rust/router/quote).

`venues` narrows the candidates instead of restricting a single quote: each
listed venue is still quoted on its own.

```rust
use propamm::common::pamms::{BEBOP, FERMI};
use propamm::QuoteOptions;

let opts = QuoteOptions {
    venues: Some(vec![FERMI, BEBOP]),
    ..Default::default()
};
let quotes = router
    .get_quotes_with(ETH_SENTINEL, USDC, parse_ether("1")?, &opts)
    .await?;
```
