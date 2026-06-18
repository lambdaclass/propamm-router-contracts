# quote

Best quote across all whitelisted venues and the Uniswap V3 fallback.

The router's quote functions are nonpayable on-chain, so the SDK calls them
through `eth_call` simulation — by default carrying the latest pAMM state
overrides plus their block number/timestamp, so venues quote fresh off-chain
liquidity.

```ts
quote(tokenIn: Address, tokenOut: Address, amountIn: bigint, opts?: QuoteOptions): Promise<Quote>
```

## Usage

::: code-group

```ts [example.ts]
import { parseEther } from "@propamm/sdk/common/helpers";
import { ETH_SENTINEL, USDC } from "@propamm/sdk/common/tokens";
import { router } from "./config";

const { amountOut, venue } = await router.quote(
  ETH_SENTINEL,
  USDC,
  parseEther("1"),
);
```

```ts [config.ts]
import { ContractClient } from "@propamm/sdk/client";
import { PropAmmRouter } from "@propamm/sdk/router";
import { mainnet } from "@propamm/sdk/common/chains";

export const client = new ContractClient({
  rpcUrl: "https://...",
  chain: mainnet,
});
export const router = new PropAmmRouter(client); // defaults to the mainnet router proxy
```

:::

## Returns

[`Quote`](/typescript/types#quote)

The best output amount and the venue that produced it; pin `venue` in a
follow-up [`swap`](/typescript/router/swap) via its `venues` option.

## Parameters

### tokenIn

- **Type:** `Address`

Token being sold, or `ETH_SENTINEL` for native ETH.

### tokenOut

- **Type:** `Address`

Token being bought, or `ETH_SENTINEL` for native ETH.

### amountIn

- **Type:** `bigint`

Exact input amount, in atomic units.

### opts (optional)

- **Type:** [`QuoteOptions`](/typescript/types#quoteoptions)

Per-call quote options.

```ts
const stale = await router.quote(ETH_SENTINEL, USDC, parseEther("1"), {
  overrides: null,
});
```

`venues` restricts the quote: a single entry quotes that venue directly,
several pick the best among them (must be non-empty when present). When no
listed venue can be priced, the call does **not** revert: it falls back to
the Uniswap V3 quote and reports the fallback router as `venue`.

```ts
import { PAMMS } from "@propamm/sdk/common/pamms";

const pinned = await router.quote(ETH_SENTINEL, USDC, parseEther("1"), {
  venues: [PAMMS.fermi],
});
const subset = await router.quote(ETH_SENTINEL, USDC, parseEther("1"), {
  venues: [PAMMS.fermi, PAMMS.bebop],
});
```
