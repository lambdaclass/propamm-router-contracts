# PropAMM TypeScript SDK

SDK for interacting with the `PropAMMRouter` contract over JSON-RPC.

## Setup

```sh
pnpm install
pnpm build      # compile to dist/
pnpm typecheck
```

## Getting started

Quote and swap 1 ETH for USDC through the best venue:

```ts
import { ContractClient } from "propamm/client";
import { PropAmmRouter } from "propamm/router";
import { ETH_SENTINEL, USDC } from "propamm/common/tokens";
import { applySlippage, deadlineIn, formatUnits, parseEther } from "propamm/common/helpers";
import { mainnet } from "propamm/common/chains";
import { privateKeyToAccount } from "propamm/common/accounts";

const account = privateKeyToAccount("0x...");
const client = new ContractClient({ rpcUrl: "https://...", chain: mainnet, account });
const router = new PropAmmRouter(client); // defaults to the mainnet router proxy

const amountIn = parseEther("1");
const { amountOut } = await router.quote(ETH_SENTINEL, USDC, amountIn);

const result = await router.swapAndWait({
  tokenIn: ETH_SENTINEL,
  tokenOut: USDC,
  amountIn,
  amountOutMin: applySlippage(amountOut, 50), // quote - 0.5%
  recipient: account.address,
  deadline: deadlineIn(300), // now + 5 min
});
console.log(`received ${formatUnits(result.amountOut, 6)} USDC via ${result.executedVenue}`);
```

A runnable version of this example lives in
[`examples/getting-started.ts`](examples/getting-started.ts):

```sh
pnpm build
node examples/getting-started.ts   # Node >= 22.18 runs TypeScript directly
```

It defaults to a local anvil mainnet fork with anvil's funded account and the
mainnet router deployment; override with `RPC_URL` / `PRIVATE_KEY` /
`ROUTER_ADDRESS` / `SLIPPAGE_BPS`.

## Usage

```ts
import { ContractClient } from "propamm/client";
import { PropAmmRouter } from "propamm/router";
import { ETH_SENTINEL, USDC, WETH } from "propamm/common/tokens";
import { PAMMS } from "propamm/common/pamms";
import { applySlippage, deadlineIn, parseEther, parseUnits } from "propamm/common/helpers";
import { mainnet } from "propamm/common/chains";
import { privateKeyToAccount } from "propamm/common/accounts";

const client = new ContractClient({
  rpcUrl: "http://localhost:8545",
  chain: mainnet,
  account: privateKeyToAccount("0x..."), // omit for read-only (quotes/views still work)
});
const router = new PropAmmRouter(client, "0x..."); // pass an explicit proxy; omit for the mainnet default

// Quote, approve, swap, then wait
const amountIn = parseUnits("100", 6); // 100 USDC
const { amountOut, venue } = await router.quote(USDC, WETH, amountIn);

await router.approve(USDC, amountIn); // ERC-20 input requires router allowance

const hash = await router.swap({
  tokenIn: USDC,
  tokenOut: WETH,
  amountIn,
  amountOutMin: applySlippage(amountOut, 50), // quote - 0.5%
  recipient: me,
  deadline: deadlineIn(300), // now + 5 min
});
const result = await router.waitForSwap(hash);
// { hash, receipt, amountIn, amountOut, executedVenue, recipient, fee? }

// One-shot: swap + wait combined, pinned to a single venue
const res = await router.swapAndWait(
  {
    tokenIn: USDC,
    tokenOut: WETH,
    amountIn,
    amountOutMin: minOut,
    recipient: me,
    deadline: deadlineIn(300),
  },
  { venues: [PAMMS.kipseli] },
);

// Native ETH input: sentinel token, msg.value attached automatically
await router.swapAndWait({
  tokenIn: ETH_SENTINEL,
  tokenOut: USDC,
  amountIn: parseEther("1"),
  amountOutMin: minOut,
  recipient: me,
  deadline: deadlineIn(300),
});

// Frontend fee: optional, bps validated in [1, MAX_FEE_BPS]
await router.swap(params, { frontendFee: { bps: 25, recipient: feeRecipient } });

// Pinned / selected-venue quotes
const pinned = await router.quote(USDC, WETH, amountIn, { venues: [PAMMS.fermi] });
const subset = await router.quote(USDC, WETH, amountIn, { venues: [PAMMS.fermi, PAMMS.bebop] });

// Views
await router.getWhitelistedVenues();
await router.paused();
await router.fallbackSwapRouter(); // Uniswap fallback "venue" address (dynamic, not in PAMMS)
```

## State overrides

The pAMM venues price off-chain liquidity that on-chain state does not
reflect, so a plain `eth_call` quote sees stale prices. Titan publishes
fresh state overrides, and quotes apply them automatically: the simulation
carries the overrides plus their block number/timestamp so venues price
their pushed state instead of the chain's.

Two sources are available; both need no authentication:

- `OverridesWsSource` — streams `wss://rpc.titanbuilder.xyz/ws/pamm_quote_stream`,
  caching per-pAMM entries across frames and reconnecting with backoff. This
  is the **default**: a router constructed without options creates one
  (connecting lazily on the first quote). The socket auto-closes after an
  idle window without quotes (`idleTimeoutMs`, default 30s; `0` closes after
  each quote, `Infinity` never) and reconnects transparently, so no teardown
  is needed — `close()` exists for immediate, permanent shutdown.
- `OverridesRpcSource` — calls `titan_getPammStateOverrides` over HTTP on
  each quote. No connection to manage.

```ts
import { OverridesRpcSource, OverridesWsSource } from "propamm/overrides";

// default: streaming WS source created automatically
const router = new PropAmmRouter(client, ROUTER);

// or attach a source explicitly
const rpcRouter = new PropAmmRouter(client, ROUTER, {
  overrides: new OverridesRpcSource(),
});

// per-call control
await router.quote(WETH, USDC, amountIn, { overrides: null }); // skip overrides
await router.quote(WETH, USDC, amountIn, { overrides: rpcSource }); // one-off source
```

Admin functions (`addVenue`, `pause`, `setPairFee`, ...) have no typed
methods, but they are in the exported ABI — call them through the generic
client:

```ts
import { propAmmRouterAbi } from "propamm/router/abi";

await client.write({
  address: router.address,
  abi: propAmmRouterAbi,
  functionName: "addVenue",
  args: [newVenue],
});
```

## Price levels

Alongside the raw state overrides, Titan publishes prices it has _already
quoted_, grouped per pAMM: for each pair, an `orderBook` of rungs mapping an
input amount to the output it would receive. This lets a taker read prices
across a range of trade sizes without an `eth_call` per size. Rungs are either
`Simulated` (from an EVM simulation) or `Interpolated` (a linear spline between
simulated rungs, for finer granularity).

The `PriceLevels` client wraps it, mirroring `PropAmmRouter`: a single class
with a default snapshot source you can override in the constructor.

```ts
import { PriceLevels } from "propamm/prices";
import { USDC, WETH } from "propamm/common/tokens";
import { parseUnits } from "propamm/common/helpers";

const prices = new PriceLevels(); // default: one-shot HTTP snapshot source

const snapshot = await prices.getPriceLevels();
// snapshot.pamms[i].pairs[j].orderBook -> [{ amountIn, amountOut, variant }, ...]

// Quote helpers are served from Titan's latest snapshot over HTTP, skipping the
// on-chain eth_call that router.quote runs.
const best = await prices.getQuote(USDC, WETH, parseUnits("1000", 6));
// { tokenIn, tokenOut, amountIn, amountOut, pamm, router, blockNumber, slot }
const pinned = await prices.getQuoteVenue(best.pamm, USDC, WETH, parseUnits("1000", 6));
```

The snapshot source defaults to a `PriceLevelsRpcSource` (one
`titan_getPammPriceLevels` call per `getPriceLevels`). For a live feed, pass a
`PriceLevelsWsSource` instead — it streams complete snapshots, reconnects with
backoff, and idle auto-closes, like `OverridesWsSource`. The stream is served
from regional hosts (`eu.`, `ap.`, `us.`); pick the nearest:

```ts
import { PriceLevels, PriceLevelsWsSource } from "propamm/prices";

const prices = new PriceLevels({
  source: new PriceLevelsWsSource({ url: "wss://eu.rpc.titanbuilder.xyz/ws/pamm_price_levels" }),
});
const snapshot = await prices.getPriceLevels(); // served from the live stream
prices.close(); // close the stream socket when done (no-op for the HTTP default)
```

Passing a `PriceLevelsRpcSource` with a custom `url` instead points both the
snapshots and the quote helpers at that endpoint (the quotes are HTTP-only).

A runnable version lives in [`examples/price-levels.ts`](examples/price-levels.ts)
(`node examples/price-levels.ts`; override the HTTP endpoint with `PRICE_LEVELS_URL`).

## Layout

Source modules map 1:1 to import paths (`src/<path>.ts` → `propamm/<path>`):

- `src/client.ts` — generic viem-based contract client (`read`/`call`/`write`/`waitForTransaction`); `call` accepts state and block overrides.
- `src/router/index.ts` — `PropAmmRouter` bindings (`quote`, `swap`, `swapAndWait`, `waitForSwap`, `approve`/`allowance`, views) plus `MAX_FEE_BPS`.
- `src/router/abi.ts` — human-readable `PropAMMRouter` ABI (functions, events, errors).
- `src/overrides/index.ts` — pAMM state-override sources (`OverridesWsSource`, `OverridesRpcSource`), payload parsing, and `toStateOverride`.
- `src/prices/index.ts` — `PriceLevels` client plus its swappable snapshot sources (`PriceLevelsWsSource`, `PriceLevelsRpcSource`), snapshot parsing, and the Titan quote helpers (`getQuote`, `getQuoteVenue`).
- `src/common/tokens.ts` — `ETH_SENTINEL` and mainnet token addresses.
- `src/common/pamms.ts` — `PAMMS` name → venue address mapping.
- `src/common/helpers.ts` — `applySlippage`, `deadlineIn`, and unit conversion (`parseEther`, `parseUnits`, `formatEther`, `formatUnits`).
- `src/common/chains.ts`, `src/common/accounts.ts` — viem re-exports.

The on-chain quote functions are nonpayable (not view), so the bindings call
them through `eth_call` simulation (`ContractClient.call`) rather than a
plain read.
