# swap

Swap through the best-quoting venue (across all whitelisted venues by default, or restricted to a subset of selected venues); falls back to Uniswap V3 if the chosen venue fails to fill. Returns the transaction hash — pair with [`waitForSwap`](/typescript/router/waitForSwap), or use `swapAndWait` to do both in one call.

```ts
swap(params: SwapParams, opts?: SwapOptions): Promise<Hash>
swapAndWait(params: SwapParams, opts?: SwapOptions): Promise<SwapResult>
```

## Usage

::: code-group

```ts [example.ts]
import { applySlippage, deadlineIn, parseEther } from "propamm/common/helpers";
import { ETH_SENTINEL, USDC } from "propamm/common/tokens";
import { account, router } from "./config";

const amountIn = parseEther("1");
const { amountOut } = await router.quote(ETH_SENTINEL, USDC, amountIn);

const hash = await router.swap({
  tokenIn: ETH_SENTINEL,
  tokenOut: USDC,
  amountIn,
  amountOutMin: applySlippage(amountOut, 50),
  recipient: account.address,
  deadline: deadlineIn(300),
});
```

```ts [config.ts]
import { ContractClient } from "propamm/client";
import { PropAmmRouter } from "propamm/router";
import { mainnet } from "propamm/common/chains";
import { privateKeyToAccount } from "propamm/common/accounts";

export const account = privateKeyToAccount("0x...");
export const client = ContractClient.fromRpc({
  rpcUrl: "https://...",
  chain: mainnet,
  account,
});
export const router = new PropAmmRouter(client); // defaults to the mainnet router proxy
```

:::

## Returns

`Hash`

The transaction hash. The transaction is simulated before sending, so
reverts surface as errors without spending gas.

## swapAndWait

Same parameters; additionally waits for the receipt and decodes the outcome.
Returns [`SwapResult`](/typescript/router/waitForSwap#returns).

```ts
const result = await router.swapAndWait({ ...params });
```

## Parameters

### params

- **Type:** [`SwapParams`](/typescript/types#swapparams)

The parameters shared by every swap entrypoint — see the type for
field-by-field docs. Derive `amountOutMin` from a quote with
`applySlippage`, and `deadline` with `deadlineIn`.

```ts
const hash = await router.swap({
  // ...
  amountOutMin: applySlippage(amountOut, 50), // quote - 0.5%
});
```

### opts (optional)

- **Type:** [`SwapOptions`](/typescript/types#swapoptions)

Per-swap options: restrict the venues and/or charge a frontend fee.

`venues` restricts the swap: a single entry executes through that venue
directly (reverting `UnknownVenue` on a non-venue address), several
re-quote on-chain and fill via the best of them. Must be non-empty when
present; omit to swap through the best-quoting venue overall.

```ts
import { PAMMS } from "propamm/common/pamms";

// exactly this venue
const hash = await router.swap(params, { venues: [PAMMS.kipseli] });

// best of a subset
const hash2 = await router.swap(params, { venues: [PAMMS.fermi, PAMMS.bebop] });
```

`frontendFee` skims a fee from the output token, paid to its `recipient`.
`bps` must be an integer in `[1, MAX_FEE_BPS]` (100 = 1%) — validated
before sending. With a fee, `amountOutMin` is the **net** minimum the
recipient must receive after the fee, and the decoded result's `fee` field
(via [`waitForSwap`](/typescript/router/waitForSwap)) carries the charged
amount and recipient.

```ts
const hash = await router.swap(params, {
  frontendFee: { bps: 25, recipient: "0x..." }, // 0.25% to the fee recipient
});
```

`gasLimit` sets an explicit transaction gas limit, overriding the per-function
default described below.

```ts
const hash = await router.swap(params, { gasLimit: 800_000n });
```

## Gas limits

Swaps attach a **hardcoded per-function gas limit** and skip node gas
estimation. Estimation runs against the current state, but the swap can take a
heavier branch when it executes, so an estimate can under-shoot and the
transaction runs out of gas. The hardcoded limits sit above the worst observed
branch (plus headroom), and are tiered by how much quoting each entrypoint does
on-chain (a single named venue is cheapest; the all-venues requote is highest).

Pass [`SwapOptions.gasLimit`](/typescript/types#swapoptions) to override the
default for a call.

## gasLimitFor

Returns the gas limit [`swap`](#swap) / `swapAndWait` will attach for a given
`SwapOptions` — the explicit `gasLimit` if set, otherwise the hardcoded
per-function default. Pure (no RPC), so it's suited to previewing the maximum
network fee (`gasLimit × gas price`) or sizing a balance check before sending.

```ts
gasLimitFor(opts?: SwapOptions): bigint
```

```ts
import { PAMMS } from "propamm/common/pamms";

router.gasLimitFor(); // all-venues swap
router.gasLimitFor({ venues: [PAMMS.kipseli] }); // single-venue (cheapest)
router.gasLimitFor({ venues: [PAMMS.fermi, PAMMS.bebop] }); // selected-venues
router.gasLimitFor({ gasLimit: 800_000n }); // explicit override → 800000n

// fee preview
const gasPrice = await client.publicClient.getGasPrice();
const maxFeeWei = router.gasLimitFor({ venues }) * gasPrice;
```
