# Quotes

The router's quote functions are **nonpayable on-chain** (not `view`), so the
SDK calls them through `eth_call` simulation — by default carrying the latest
pAMM state overrides plus their block
number/timestamp, so venues quote fresh off-chain liquidity.

All quote methods return `Quote { amount_out: U256, venue: Address }`.

```rust
// Best quote across all whitelisted venues and the Uniswap V3 fallback
let best = router.quote(WETH, USDC, amount_in).await?;

// Pin a specific venue (falls back to the Uniswap quote — reporting the
// fallback router as `venue` — when the venue can't be priced)
use propamm_sdk::common::pamms::FERMI;
let pinned = router.quote_venue(FERMI, WETH, USDC, amount_in).await?;

// Best among a caller-supplied subset
use propamm_sdk::common::pamms::BEBOP;
let subset = router
    .quote_selected_venues(vec![FERMI, BEBOP], WETH, USDC, amount_in)
    .await?;

// The Uniswap V3 fallback route directly (never applies overrides)
let uni = router.quote_uniswap_v3(WETH, USDC, amount_in).await?;
```

Venue addresses are in `common::pamms` (`FERMI`, `BEBOP`, `KIPSELI`, plus the
`PAMMS` name → address array). The Uniswap fallback is intentionally not
there — its address is router configuration, read it with
`router.fallback_swap_router()`.

## Per-call options

Each quote method has a `_with` variant taking `QuoteOptions`:

```rust
use propamm_sdk::router::{QuoteOptions, QuoteOverrides};

// skip overrides entirely (raw on-chain state)
let opts = QuoteOptions { overrides: QuoteOverrides::Skip, ..Default::default() };
let stale = router.quote_with(WETH, USDC, amount_in, &opts).await?;

// use a different source (or a fixed snapshot) for this call
let opts = QuoteOptions {
    overrides: QuoteOverrides::Source(Arc::new(OverridesRpcSource::default())),
    ..Default::default()
};

// keep Bebop's raw on-chain slot instead of the default zeroing
let opts = QuoteOptions { skip_bebop_default: true, ..Default::default() };
```

A router-wide source can be attached at construction:

```rust
use propamm_sdk::overrides::OverridesRpcSource;
let router = PropAmmRouter::with_overrides(client, address, Arc::new(OverridesRpcSource::default()));
```

## Reverts

Quote reverts decode into the contract's named errors — e.g. quoting an
unquotable pair surfaces as `NoQuotesAvailable()`, and a pre-checked swap
shortfall as `InsufficientOutput(expected, received)`.
