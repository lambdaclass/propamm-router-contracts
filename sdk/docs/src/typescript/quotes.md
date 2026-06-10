# Quotes

The router's quote functions are **nonpayable on-chain** (not `view`), so the
SDK calls them through `eth_call` simulation — by default carrying the latest
pAMM state overrides plus their block
number/timestamp, so venues quote fresh off-chain liquidity.

All quote methods return `Quote { amountOut: bigint; venue: Address }`.

```ts
// Best quote across all whitelisted venues and the Uniswap V3 fallback
const best = await router.quote(WETH, USDC, amountIn);

// Pin a specific venue (falls back to the Uniswap quote — reporting the
// fallback router as `venue` — when the venue can't be priced)
import { PAMMS } from "@propamm/sdk/common/pamms";
const pinned = await router.quoteVenue(PAMMS.fermi, WETH, USDC, amountIn);

// Best among a caller-supplied subset
const subset = await router.quoteSelectedVenues([PAMMS.fermi, PAMMS.bebop], WETH, USDC, amountIn);

// The Uniswap V3 fallback route directly (never applies overrides)
const uni = await router.quoteUniswapV3(WETH, USDC, amountIn);
```

`PAMMS` maps venue names to addresses (`fermi`, `bebop`, `kipseli`). The
Uniswap fallback is intentionally not in it — its address is router
configuration, read it with `router.fallbackSwapRouter()`.

## Per-call options

Every quote method takes optional trailing `QuoteOptions`:

```ts
// skip overrides entirely (raw on-chain state)
await router.quote(WETH, USDC, amountIn, { overrides: null });

// use a different source (or a fixed snapshot) for this call
await router.quote(WETH, USDC, amountIn, { overrides: new OverridesRpcSource() });

// keep Bebop's raw on-chain slot instead of the default zeroing
await router.quote(WETH, USDC, amountIn, { bebopDefault: false });
```

A router-wide source can be attached at construction:

```ts
import { OverridesRpcSource } from "@propamm/sdk/overrides";
const router = new PropAmmRouter(client, ROUTER, { overrides: new OverridesRpcSource() });
```

## Reverts

Quote reverts decode into the contract's named errors — e.g. quoting an
unquotable pair surfaces as `NoQuotesAvailable()`, and a pre-checked swap
shortfall as `InsufficientOutput(expected, received)`.
