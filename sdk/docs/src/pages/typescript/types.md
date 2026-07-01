# Types

Shared types across the TypeScript SDK. Import value types from
`propamm/router` / `propamm/client` / `propamm/overrides`;
primitives (`Address`, `Hash`, `Account`, `Chain`) re-export from the root.

## SwapParams

Common parameters shared by every [swap entrypoint](/typescript/router/swap).

```ts
interface SwapParams {
  tokenIn: Address;
  tokenOut: Address;
  amountIn: bigint;
  amountOutMin: bigint;
  recipient: Address;
  deadline: bigint;
}
```

- `tokenIn` — token being sold, or `ETH_SENTINEL` for native ETH (attaches
  `msg.value` automatically).
- `tokenOut` — token being bought; `ETH_SENTINEL` delivers native ETH.
- `amountIn` — exact input amount, in atomic units.
- `amountOutMin` — minimum acceptable output (net of the frontend fee, when
  one is passed); derive from a quote with `applySlippage`.
- `recipient` — receiver of `tokenOut`.
- `deadline` — unix timestamp after which the swap is invalid; build with
  `deadlineIn`.

## Quote

Result of every quote method.

```ts
interface Quote {
  amountOut: bigint;
  venue: Address;
}
```

- `amountOut` — the quoted output amount, in atomic units.
- `venue` — the venue that produced the quote (or the Uniswap fallback
  router); pin it in a follow-up [`swap`](/typescript/router/swap) via
  [`SwapOptions.venues`](#swapoptions) to execute against it.

## SwapResult

Decoded outcome of a mined swap, from
[`waitForSwap`](/typescript/router/waitForSwap) or `swapAndWait`.

```ts
interface SwapResult {
  hash: Hash;
  receipt: TransactionReceipt;
  amountIn: bigint;
  amountOut: bigint;
  executedVenue: Address;
  recipient: Address;
  fee?: { recipient: Address; amount: bigint };
}
```

- `hash` / `receipt` — the transaction and its receipt.
- `amountIn` — input pulled from the sender (from the `Swapped` event).
- `amountOut` — output delivered to the recipient, net of any fee.
- `executedVenue` — the venue that actually filled, or the Uniswap fallback
  router.
- `recipient` — who received `tokenOut`.
- `fee` — present when the swap charged a frontend fee (from
  `FrontendFeeCharged`).

## SwapOptions

Per-swap options, accepted by [`swap`](/typescript/router/swap) and
`swapAndWait`.

```ts
interface SwapOptions {
  venues?: readonly Address[];
  frontendFee?: FrontendFee;
  gasLimit?: bigint;
}
```

- `venues` — restrict the swap to these venues: a single entry executes
  through that venue directly, several re-quote on-chain and fill via the
  best of them. Must be non-empty when present; omit to swap through the
  best-quoting venue overall.
- `frontendFee` — skim a [frontend fee](#frontendfee) from the output;
  routes the call through the contract's `WithFee` selector.
- `gasLimit` — explicit transaction gas limit, in gas units. Overrides the
  hardcoded per-function default (see [swap](/typescript/router/swap#gas-limits));
  read the effective value with [`gasLimitFor`](/typescript/router/swap#gaslimitfor).

## FrontendFee

Frontend fee skimmed from a swap's output; pass via
[`SwapOptions.frontendFee`](#swapoptions). Validated before the swap is
sent.

```ts
interface FrontendFee {
  bps: number;
  recipient: Address;
}
```

- `bps` — fee in basis points of the output token, an integer in
  `[1, MAX_FEE_BPS]` (`MAX_FEE_BPS = 100`, i.e. 1%).
- `recipient` — receives the fee in `tokenOut`; must not be the zero
  address.

## QuoteOptions

Per-call options accepted by [`quote`](/typescript/router/quote).

```ts
interface QuoteOptions {
  overrides?: OverridesSource | OverridesSnapshot | null;
  bebopDefault?: boolean;
  venues?: readonly Address[];
}
```

- `overrides` — replace the router's attached overrides source for this call:
  another source, a fixed snapshot, or `null` to quote raw on-chain state.
- `bebopDefault` — set `false` to keep Bebop's raw on-chain slot instead of
  zeroing it when the snapshot has no Bebop entry (default `true`).
- `venues` — restrict the quote to these venues: a single entry quotes that
  venue directly, several pick the best among them. Must be non-empty when
  present.

## CallParams

Parameters of `ContractClient.call` — an `eth_call` simulation with optional
overrides.

```ts
interface CallParams {
  address: Address;
  abi: Abi;
  functionName: string;
  args?: unknown[];
  value?: bigint;
  stateOverride?: StateOverride;
  blockNumber?: bigint;
  blockTimestamp?: bigint;
}
```

- `stateOverride` — state overrides applied to the call (third `eth_call`
  parameter, viem format; see `toStateOverride`).
- `blockNumber` / `blockTimestamp` — pin the simulated `block.number` /
  `block.timestamp` (block overrides, fourth parameter).

## OverridesSnapshot

A parsed pAMM state-override payload, returned by every source's
`getOverrides()`.

```ts
interface OverridesSnapshot {
  blockNumber?: bigint;
  timestampNs?: bigint;
  perPamm: Record<Address, Record<Address, Record<Hex, Hex>>>;
}
```

- `blockNumber` — block the overrides were generated against; quotes pin the
  simulation to it.
- `timestampNs` — generation time in nanoseconds since epoch; quotes pin the
  simulated `block.timestamp` to it.
- `perPamm` — pAMM address → overridden contract → storage slot → value.

## OverridesSource

The interface both override sources implement — implement it to plug in a
custom source.

```ts
interface OverridesSource {
  getOverrides(): Promise<OverridesSnapshot | undefined>;
  close?(): void;
}
```

## PriceLevelsSnapshot

A parsed price-levels payload, returned by every source's `getPriceLevels()`.

```ts
interface PriceLevelsSnapshot {
  blockNumber?: bigint;
  slot?: bigint;
  timestampNs?: bigint;
  pamms: PammPriceLevels[];
}
```

- `blockNumber` — block the levels were generated against.
- `slot` — beacon slot the levels were generated against.
- `timestampNs` — generation time in nanoseconds since epoch (approximate —
  JSON serialization loses sub-millisecond precision for large values).
- `pamms` — per-pAMM order books.

## PammPriceLevels

One pAMM's price levels across all pairs it quotes.

```ts
interface PammPriceLevels {
  pamm: Address;
  pairs: PairPriceLevels[];
}
```

## PairPriceLevels

The order book a pAMM quotes for one `tokenIn`/`tokenOut` pair.

```ts
interface PairPriceLevels {
  tokenIn: Address;
  tokenOut: Address;
  orderBook: PriceLevel[];
}
```

## PriceLevel

One rung of a pair's order book.

```ts
interface PriceLevel {
  amountIn: bigint;
  amountOut: bigint;
  variant: "Simulated" | "Interpolated";
}
```

- `amountIn` / `amountOut` — amounts in atomic units.
- `variant` — `"Simulated"` means the rung came from an EVM simulation;
  `"Interpolated"` from a linear spline between simulated rungs.

## TitanQuote

Result of `getQuote` / `getQuoteVenue` (`titan_getPammQuote` /
`titan_getPammQuoteVenue`).

```ts
interface TitanQuote {
  tokenIn: Address;
  tokenOut: Address;
  amountIn: bigint;
  amountOut: bigint;
  pamm: Address;
  router: Address;
  blockNumber?: bigint;
  slot?: bigint;
  timestampNs?: bigint;
}
```

- `pamm` — pAMM that produced the quote.
- `router` — router associated with the quote.

## PriceLevelsSource

The interface both price-level sources implement — implement it to plug in a
custom source.

```ts
interface PriceLevelsSource {
  getPriceLevels(): Promise<PriceLevelsSnapshot | undefined>;
  close?(): void;
}
```
