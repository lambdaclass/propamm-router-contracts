# Swaps

All swap entrypoints share `SwapParams`:

```ts
interface SwapParams {
  tokenIn: Address;      // or ETH_SENTINEL for native ETH
  tokenOut: Address;     // or ETH_SENTINEL
  amountIn: bigint;      // atomic units
  amountOutMin: bigint;  // net of fee on the WithFee paths
  recipient: Address;
  deadline: bigint;      // unix timestamp — see deadlineIn()
}
```

The six entrypoints mirror the contract (TS names drop the on-chain `V1`
suffix) and return the transaction hash:

| Method | Routing |
|---|---|
| `swap(params)` | best-quoting venue |
| `swapWithFee(params, fee)` | best venue + frontend fee |
| `swapViaVenue(venue, params)` | explicit venue (or the fallback router) |
| `swapViaVenueWithFee(venue, params, fee)` | explicit venue + fee |
| `swapViaSelectedVenues(venues, params)` | best of a subset |
| `swapViaSelectedVenuesWithFee(venues, params, fee)` | subset + fee |

Each has an `...AndWait` variant that waits for the receipt and decodes the
result in one call; or do it in two steps:

```ts
const hash = await router.swap(params);
const result = await router.waitForSwap(hash);
// SwapResult: { hash, receipt, amountIn, amountOut, executedVenue, recipient, fee? }
```

`waitForSwap` decodes the router's `Swapped` event (and `FrontendFeeCharged`
when present — `result.fee` carries the recipient and amount). It throws if
the transaction reverted or emitted no `Swapped` event.

## Token inputs

- **ERC-20 input** requires a prior allowance for the router:

  ```ts
  await router.approve(USDC, amountIn);            // approve(token, amount)
  await router.allowance(USDC, account.address);   // check current allowance
  ```

- **Native ETH input**: pass `ETH_SENTINEL` as `tokenIn` — the SDK attaches
  `msg.value = amountIn` automatically. No approval needed. `ETH_SENTINEL` as
  `tokenOut` delivers native ETH.

## Frontend fees

The `*WithFee` variants skim a fee from the output token. Build the fee with
the validated helper (`bps` capped at `MAX_FEE_BPS = 100`, recipient must be
non-zero); `amountOutMin` is the **net** minimum the recipient must receive:

```ts
import { frontendFee } from "@propamm/sdk/router";
await router.swapWithFee(params, frontendFee(25, feeRecipient)); // 0.25%
```

## Helpers

```ts
import { applySlippage, deadlineIn, parseUnits, parseEther } from "@propamm/sdk/common/helpers";

const amountIn = parseUnits("100", 6);              // 100 USDC
const minOut = applySlippage(quote.amountOut, 50);  // quote - 0.5%
const deadline = deadlineIn(300);                   // now + 5 min
```

## Admin functions

`addVenue`, `pause`, `setPairFee`, ... have no typed methods, but they're in
the exported ABI — call them through the generic client:

```ts
import { propAmmRouterAbi } from "@propamm/sdk/router/abi";

await client.write({
  address: router.address,
  abi: propAmmRouterAbi,
  functionName: "addVenue",
  args: [newVenue],
});
```
