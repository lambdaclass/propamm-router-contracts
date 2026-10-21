# getQuotes

Every whitelisted venue that actually prices a pair right now, best output
first.

Each venue is quoted on its own through `quoteVenueV1`, which propagates the
venue's revert. Quoting them together would go through
`quoteSelectedVenuesV1`, which falls back to Uniswap and would report every
venue as alive. Venues that revert or quote zero are dropped, so the result
doubles as the venue list for a [`swap`](/typescript/router/swap) restricted
with `venues` — the gas saving of skipping the venues that cannot serve the
pair.

All venues price against a single overrides snapshot, so their outputs are
comparable; resolving overrides per venue would mix blocks.

```ts
getQuotes(tokenIn: Address, tokenOut: Address, amountIn: bigint, opts?: QuoteOptions): Promise<Quote[]>
```

## Usage

::: code-group

```ts [example.ts]
import { parseEther } from "propamm/common/helpers";
import { ETH_SENTINEL, USDC } from "propamm/common/tokens";
import { router } from "./config";

const quotes = await router.getQuotes(ETH_SENTINEL, USDC, parseEther("1"));
const venues = quotes.map((quote) => quote.venue);

// Swap through only the venues that can serve the pair.
await router.swap(
  {
    tokenIn: ETH_SENTINEL,
    tokenOut: USDC,
    amountIn: parseEther("1"),
    amountOutMin: quotes[0].amountOut,
    recipient: "0x...",
  },
  { venues },
);
```

```ts [config.ts]
import { ContractClient, PropAmmRouter } from "propamm";

export const client = new ContractClient("https://...");
export const router = new PropAmmRouter(client, "0x..."); // router proxy
```

:::

## Returns

[`Quote`](/typescript/types#quote)`[]`

One entry per venue that priced the pair, sorted by `amountOut` descending.
Empty when no venue serves it — unlike [`quote`](/typescript/router/quote),
this never falls back to Uniswap, so an empty array means exactly that.

A venue that fails for any reason other than a revert — a transport error, a
node failure — throws instead of being dropped, so the list never silently
shortens.

## Parameters

### tokenIn

- **Type:** `Address`

Address of the token being sold, or `ETH_SENTINEL` for native ETH.

### tokenOut

- **Type:** `Address`

Address of the token being bought, or `ETH_SENTINEL` for native ETH.

### amountIn

- **Type:** `bigint`

Exact input amount, in atomic units. Venues quote against depth, so the set
that answers depends on the size.

### opts (optional)

- **Type:** [`QuoteOptions`](/typescript/types#quoteoptions)

Per-call quote options, with the same `overrides` and `bebopDefault`
semantics as [`quote`](/typescript/router/quote).

`venues` narrows the candidates instead of restricting a single quote: each
listed venue is still quoted on its own.

```ts
import { BEBOP, FERMI } from "propamm/common/pamms";

const quotes = await router.getQuotes(ETH_SENTINEL, USDC, parseEther("1"), {
  venues: [FERMI, BEBOP],
});
```
