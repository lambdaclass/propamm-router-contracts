# Types

Shared types across the Rust SDK. Import from `propamm::router` /
`propamm::client` / `propamm::overrides`; primitives (`Address`,
`H256`, `U256`, `TxHash` — ethrex types) re-export from the crate root.

## SwapParams

Common parameters shared by every [swap entrypoint](/rust/router/swap).

```rust
pub struct SwapParams {
    pub token_in: Address,
    pub token_out: Address,
    pub amount_in: U256,
    pub amount_out_min: U256,
    pub recipient: Address,
    pub deadline: U256,
}
```

- `token_in` — token being sold, or `ETH_SENTINEL` for native ETH (attaches
  `msg.value` automatically).
- `token_out` — token being bought; `ETH_SENTINEL` delivers native ETH.
- `amount_in` — exact input amount, in atomic units.
- `amount_out_min` — minimum acceptable output (net of the frontend fee,
  when one is passed); derive from a quote with `apply_slippage`.
- `recipient` — receiver of `token_out`.
- `deadline` — unix timestamp after which the swap is invalid; build with
  `deadline_in`.

## Quote

Result of every quote method.

```rust
pub struct Quote {
    pub amount_out: U256,
    pub venue: Address,
}
```

- `amount_out` — the quoted output amount, in atomic units.
- `venue` — the venue that produced the quote (or the Uniswap fallback
  router); pin it in a follow-up [`swap_with`](/rust/router/swap) via
  [`SwapOptions::venues`](#swapoptions) to execute against it.

## SwapResult

Decoded outcome of a mined swap, from
[`wait_for_swap`](/rust/router/wait_for_swap) or `swap_and_wait`(`_with`).

```rust
pub struct SwapResult {
    pub hash: H256,
    pub receipt: TransactionReceipt,
    pub amount_in: U256,
    pub amount_out: U256,
    pub executed_venue: Address,
    pub recipient: Address,
    pub fee: Option<FeeCharged>,
}
```

- `hash` / `receipt` — the transaction and its receipt (ethrex `RpcReceipt`).
- `amount_in` — input pulled from the sender (from the `Swapped` event).
- `amount_out` — output delivered to the recipient, net of any fee.
- `executed_venue` — the venue that actually filled, or the Uniswap fallback
  router.
- `recipient` — who received `token_out`.
- `fee` — present when the swap charged a frontend fee (from
  `FrontendFeeCharged`).

## FeeCharged

Frontend fee actually charged by a swap.

```rust
pub struct FeeCharged {
    pub recipient: Address,
    pub amount: U256,
}
```

## SwapOptions

Per-swap options, accepted by [`swap_with`](/rust/router/swap) and
`swap_and_wait_with`; `Default` mirrors the plain `swap`.

```rust
pub struct SwapOptions {
    pub venues: Option<Vec<Address>>,
    pub frontend_fee: Option<FrontendFee>,
}
```

- `venues` — restrict the swap to these venues: a single entry executes
  through that venue directly, several re-quote on-chain and fill via the
  best of them. Must be non-empty when present; `None` swaps through the
  best-quoting venue overall.
- `frontend_fee` — skim a [frontend fee](#frontendfee) from the output;
  routes the call through the contract's `WithFee` selector.

## FrontendFee

Frontend fee skimmed from a swap's output; pass via
[`SwapOptions::frontend_fee`](#swapoptions). Validated before the swap is
sent.

```rust
pub struct FrontendFee {
    pub bps: u16,
    pub recipient: Address,
}
```

- `bps` — fee in basis points of the output token, in `[1, MAX_FEE_BPS]`
  (`MAX_FEE_BPS = 100`, i.e. 1%).
- `recipient` — receives the fee in `token_out`; must not be the zero
  address.

## QuoteOptions

Per-call options accepted by [`quote_with`](/rust/router/quote).

```rust
pub struct QuoteOptions {
    pub overrides: QuoteOverrides,
    pub skip_bebop_default: bool,
    pub venues: Option<Vec<Address>>,
}
```

- `overrides` — which override source this call uses (see below).
- `skip_bebop_default` — set `true` to keep Bebop's raw on-chain slot instead
  of zeroing it when the snapshot has no Bebop entry.
- `venues` — restrict the quote to these venues: a single entry quotes that
  venue directly, several pick the best among them. Must be non-empty when
  present.

## QuoteOverrides

Override source selection for a single quote call.

```rust
pub enum QuoteOverrides {
    Attached,                            // the router's source (default)
    Skip,                                // quote raw on-chain state
    Source(Arc<dyn OverridesSource>),    // this source, for this call only
    Snapshot(OverridesSnapshot),         // a fixed snapshot
}
```

## CallOverrides

Optional context for `ContractClient::call` — an `eth_call` simulation with
overrides.

```rust
pub struct CallOverrides {
    pub state: Option<StateOverrideSet>,
    pub block: Option<BlockOverrideSet>,
}
```

- `state` — state overrides applied to the call (third `eth_call` parameter,
  rex type; see `to_state_override`).
- `block` — block overrides (fourth parameter), e.g. a pinned `number`/`time`
  (rex's `BlockOverrideSet`).

## OverridesSnapshot

A parsed pAMM state-override payload, returned by every source's
`get_overrides()`.

```rust
pub struct OverridesSnapshot {
    pub block_number: Option<u64>,
    pub timestamp_ns: Option<u64>,
    pub per_pamm: HashMap<Address, ContractDiffs>,
}
```

- `block_number` — block the overrides were generated against; quotes pin the
  simulation to it.
- `timestamp_ns` — generation time in nanoseconds since epoch; quotes pin the
  simulated `block.timestamp` to it.
- `per_pamm` — pAMM address → overridden contract → storage slot → value
  (`ContractDiffs = HashMap<Address, HashMap<H256, U256>>`).

## PriceLevelsSnapshot

A parsed price-levels payload, returned by every source's `get_price_levels()`.

```rust
pub struct PriceLevelsSnapshot {
    pub block_number: Option<u64>,
    pub slot: Option<u64>,
    pub timestamp_ns: Option<u64>,
    pub pamms: Vec<PammPriceLevels>,
}
```

- `block_number` — block the levels were generated against.
- `slot` — beacon slot the levels were generated against.
- `timestamp_ns` — generation time in nanoseconds since epoch.
- `pamms` — per-pAMM order books.

## PammPriceLevels

One pAMM's price levels across all pairs it quotes.

```rust
pub struct PammPriceLevels {
    pub pamm: Address,
    pub pairs: Vec<PairPriceLevels>,
}
```

## PairPriceLevels

The order book a pAMM quotes for one `token_in`/`token_out` pair.

```rust
pub struct PairPriceLevels {
    pub token_in: Address,
    pub token_out: Address,
    pub order_book: Vec<PriceLevel>,
}
```

## PriceLevel

One rung of a pair's order book.

```rust
pub struct PriceLevel {
    pub amount_in: U256,
    pub amount_out: U256,
    pub variant: PriceVariant,
}

pub enum PriceVariant {
    Simulated,
    Interpolated,
}
```

- `amount_in` / `amount_out` — amounts in atomic units.
- `variant` — `Simulated` means the rung came from an EVM simulation;
  `Interpolated` from a linear spline between simulated rungs.

## TitanQuote

Result of `get_quote` / `get_quote_venue` (`titan_getPammQuote` /
`titan_getPammQuoteVenue`).

```rust
pub struct TitanQuote {
    pub token_in: Address,
    pub token_out: Address,
    pub amount_in: U256,
    pub amount_out: U256,
    pub pamm: Address,
    pub router: Address,
    pub block_number: Option<u64>,
    pub slot: Option<u64>,
    pub timestamp_ns: Option<u64>,
}
```

- `pamm` — pAMM that produced the quote.
- `router` — router associated with the quote.

## PriceLevelsSource

The trait both price-level sources implement — implement it to plug in a custom
source.

```rust
#[async_trait]
pub trait PriceLevelsSource: Send + Sync {
    async fn get_price_levels(&self) -> Result<Arc<PriceLevelsSnapshot>>;
    fn close(&self) {}
}
```

## Error

All fallible SDK calls return `Result<T, Error>`.

```rust
pub enum Error {
    Client(EthClientError),
    Revert { message: String, data: Option<Vec<u8>> },
    Abi(String),
    Overrides(String),
    Timeout(String),
    InvalidInput(String),
    Other(String),
}
```

- `Client` — transport / node / transaction errors from the rex/ethrex client.
- `Revert` — an `eth_call` reverted; `data` carries the raw revert payload,
  and router calls append the decoded named error (e.g.
  `InsufficientOutput(1000, 900)`) to `message` when recognizable.
- `Abi` — encode/decode failures.
- `Overrides` — override fetch/parse failures.
- `Timeout` — first-frame or receipt-polling timeouts.
- `InvalidInput` — invalid addresses, fee bounds, keys, URLs.
