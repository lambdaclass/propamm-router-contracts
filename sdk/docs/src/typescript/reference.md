# Reference

Public API by import path. The root export (`@propamm/sdk`) carries only
`ContractClient`, `PropAmmRouter`, and core types (`Address`, `Hash`,
`Account`, `Chain`); everything else lives on its subpath.

## `@propamm/sdk/client`

### `new ContractClient(options)`

Generic JSON-RPC contract client.

- `options.rpcUrl: string` — JSON-RPC endpoint, e.g. `http://localhost:8545`.
- `options.chain: Chain` — target chain (e.g. `mainnet` or `anvil` from
  `@propamm/sdk/common/chains`).
- `options.account?: Account` — account used to sign transactions (e.g. from
  `privateKeyToAccount`). Omit for a read-only client: reads, calls, and
  quotes work; `write` throws.

### `read({ address, abi, functionName, args? })`

Call a read-only (`view`/`pure`) contract function.

- `address: Address` — contract to call.
- `abi: Abi` — contract ABI.
- `functionName: string` — function to call.
- `args?: unknown[]` — arguments (default `[]`).

**Returns** `Promise<T>` — the decoded return value.

### `call({ address, abi, functionName, args?, value?, stateOverride?, blockNumber?, blockTimestamp? })`

Simulate a state-changing function via `eth_call` and return its result
without sending a transaction. This is how the router's quote functions
(which are nonpayable on-chain) are called.

- `value?: bigint` — ETH attached to the simulated call, in wei.
- `stateOverride?: StateOverride` — state overrides applied to the call
  (third `eth_call` parameter, viem format).
- `blockNumber?: bigint` — pin the simulated `block.number` (block override,
  fourth parameter).
- `blockTimestamp?: bigint` — pin the simulated `block.timestamp`, in seconds.

**Returns** `Promise<T>` — the decoded return value. Reverts throw with the
contract's named error decoded when possible.

### `write({ address, abi, functionName, args?, value? })`

Send a state-changing call as a transaction. Simulates first, so reverts
surface as errors before any gas is spent. Requires an `account`.

**Returns** `Promise<Hash>` — the transaction hash (not mined yet).

### `waitForTransaction(hash)`

Wait until a transaction is mined.

- `hash: Hash` — transaction hash from `write`.

**Returns** `Promise<TransactionReceipt>`.

### Properties

- `publicClient` / `walletClient` — the underlying viem clients, for anything
  not wrapped here (`walletClient` is undefined on read-only clients).

## `@propamm/sdk/router`

### `new PropAmmRouter(client, address, options?)`

Typed `PropAMMRouter` bindings. Method names drop the on-chain `V1` suffix
(`swap` calls `swapV1`, ...).

- `client: ContractClient` — the client to call/send through.
- `address: Address` — deployed router (proxy) address.
- `options.overrides?: OverridesSource` — source of pAMM state overrides
  applied to quotes. Defaults to a streaming `OverridesWsSource` that
  connects lazily on the first quote. Exposed as `router.overrides`.

### Quotes

All quote methods simulate via `eth_call`, by default carrying the latest
state overrides plus their block number/timestamp, and return
`Quote { amountOut: bigint; venue: Address }` — the output amount and the
venue that produced it.

Common parameters:

- `tokenIn: Address` — token being sold, or `ETH_SENTINEL` for native ETH.
- `tokenOut: Address` — token being bought, or `ETH_SENTINEL`.
- `amountIn: bigint` — exact input amount, in atomic units.
- `opts?: QuoteOptions` — per-call options:
  - `overrides?: OverridesSource | OverridesSnapshot | null` — replace the
    router's attached source for this call; `null` quotes without overrides.
  - `bebopDefault?: boolean` — set `false` to keep Bebop's raw on-chain slot
    instead of zeroing it when the snapshot has no Bebop entry (default `true`).

#### `quote(tokenIn, tokenOut, amountIn, opts?)`

Best quote across all whitelisted venues and the Uniswap V3 fallback.

#### `quoteVenue(venue, tokenIn, tokenOut, amountIn, opts?)`

Quote a specific venue.

- `venue: Address` — a whitelisted pAMM (see `PAMMS`) or the fallback router
  address. When the venue can't be priced, the call does **not** revert: it
  falls back to the Uniswap V3 quote and reports the fallback router as
  `venue` in the result.

#### `quoteSelectedVenues(venues, tokenIn, tokenOut, amountIn, opts?)`

Best quote among a caller-supplied set of venues.

- `venues: Address[]` — the only venues considered. Venues that revert while
  quoting are skipped; when none can be priced the router falls back to the
  Uniswap V3 quote.

#### `quoteUniswapV3(tokenIn, tokenOut, amountIn)`

Quote the Uniswap V3 fallback route directly, at the pair's resolved fee
tier. Never applies overrides (the fallback quoter only reads live on-chain
pool state).

**Returns** `Promise<bigint>` — the output amount.

### Swaps

All swap entrypoints take `SwapParams`:

- `tokenIn: Address` — token being sold; `ETH_SENTINEL` for native ETH (the
  SDK attaches `msg.value = amountIn` automatically; otherwise the router
  needs an ERC-20 allowance — see `approve`).
- `tokenOut: Address` — token being bought; `ETH_SENTINEL` delivers native ETH.
- `amountIn: bigint` — exact input amount, in atomic units.
- `amountOutMin: bigint` — minimum acceptable output. On the `WithFee` paths
  this is the **net** minimum the recipient must receive after the fee.
- `recipient: Address` — receiver of `tokenOut`.
- `deadline: bigint` — unix timestamp after which the swap is invalid (see
  `deadlineIn`).

Each returns `Promise<Hash>` — the transaction hash. Reverts during gas
estimation surface before anything is sent.

#### `swap(params)`

Swap through the best-quoting venue; falls back to Uniswap V3 if the chosen
venue fails to fill.

#### `swapWithFee(params, fee)`

`swap` plus a frontend fee skimmed from the output token.

- `fee: FrontendFee` — build with `frontendFee(bps, recipient)`.

#### `swapViaVenue(venue, params)`

Swap through an explicit venue.

- `venue: Address` — a whitelisted pAMM or the fallback router address;
  anything else reverts with `UnknownVenue`.

#### `swapViaVenueWithFee(venue, params, fee)`

`swapViaVenue` plus a frontend fee.

#### `swapViaSelectedVenues(venues, params)`

Re-quote only `venues` on-chain and swap through the best one; routes to the
Uniswap V3 fallback when none can be priced.

#### `swapViaSelectedVenuesWithFee(venues, params, fee)`

`swapViaSelectedVenues` plus a frontend fee.

#### `swapAndWait`, `swapWithFeeAndWait`, `swapViaVenueAndWait`, `swapViaVenueWithFeeAndWait`, `swapViaSelectedVenuesAndWait`, `swapViaSelectedVenuesWithFeeAndWait`

Same signatures as their base methods, but wait for the receipt and decode
the outcome in one call. **Return** `Promise<SwapResult>`.

#### `waitForSwap(hash)`

Wait until a swap is mined and decode its outcome from the router's events.

- `hash: Hash` — hash returned by any swap method.

**Returns** `Promise<SwapResult>`:

- `hash` / `receipt` — the transaction and its receipt.
- `amountIn: bigint` — input pulled from the sender (from `Swapped`).
- `amountOut: bigint` — output delivered to the recipient (net of any fee).
- `executedVenue: Address` — the venue that actually filled, or the Uniswap
  fallback router.
- `recipient: Address` — who received `tokenOut`.
- `fee?: { recipient: Address; amount: bigint }` — present when the swap
  charged a frontend fee (from `FrontendFeeCharged`).

Throws if the transaction reverted or emitted no `Swapped` event.

### ERC-20

#### `approve(token, amount)`

Approve the router to pull `amount` of `token` from the signer. **Returns**
`Promise<Hash>`.

#### `allowance(token, owner)`

Current allowance `owner` has granted the router for `token`. **Returns**
`Promise<bigint>`.

### Views

| Method | Returns | Description |
|---|---|---|
| `fallbackSwapRouter()` | `Address` | the Uniswap fallback "venue" address (dynamic router configuration) |
| `fallbackQuoter()` | `Address` | quoter used to price the fallback route |
| `fallbackFee()` | `number` | global fallback fee tier, in hundredths of a bip (e.g. `3000` = 0.30%) |
| `getPairFee(tokenA, tokenB)` | `number` | raw per-pair tier override, `0` if unset; order-independent |
| `resolvedFee(tokenIn, tokenOut)` | `number` | effective tier for a pair: the override if set, else the global fee |
| `isWhitelistedVenue(venue)` | `boolean` | whether `venue` is a whitelisted pAMM (the fallback is *not* a member) |
| `getWhitelistedVenues()` | `Address[]` | every whitelisted pAMM; order not guaranteed |
| `paused()` | `boolean` | whether swaps are paused (quotes still work while paused) |

### `frontendFee(bps, recipient)`

Validated `FrontendFee` builder.

- `bps: number` — fee in basis points of the output; integer in
  `[0, MAX_FEE_BPS]` (`MAX_FEE_BPS = 100`, i.e. 1%).
- `recipient: Address` — receives the fee in `tokenOut`; must be non-zero.

**Returns** `FrontendFee`. Throws `RangeError` on invalid input.

### `@propamm/sdk/router/abi`

`propAmmRouterAbi` — the full router ABI (user-facing functions, admin
functions, events, and custom errors) for use with the generic client, e.g.
`client.write({ abi: propAmmRouterAbi, functionName: "addVenue", ... })`.

## `@propamm/sdk/overrides`

### `new OverridesWsSource(options?)`

Streaming source for pAMM state overrides (the router default).

- `options.url?: string` — stream endpoint (default
  `wss://rpc.titanbuilder.xyz/ws/pamm_quote_stream`).
- `options.firstFrameTimeoutMs?: number` — how long `getOverrides` waits for
  the first frame before throwing (default `5000`).
- `options.idleTimeoutMs?: number` — close the socket after this long without
  a `getOverrides` call (default `30000`); the next call reconnects
  transparently and waits for a fresh frame. `0` closes right after each
  call; `Infinity` keeps the stream open until `close()`.

#### `getOverrides()`

**Returns** `Promise<OverridesSnapshot>` — the accumulated snapshot
(per-pAMM entries persist across frames; a frame only carries the pAMMs it
updates). Connects lazily on first use; throws on first-frame timeout or
after `close()`.

#### `close()`

Immediate, permanent teardown (pending waiters reject). Not needed for
process exit — the idle timeout handles that.

### `new OverridesRpcSource(options?)`

Fetch-on-demand source: one `titan_getPammStateOverrides` HTTP call per
`getOverrides()`.

- `options.url?: string` — endpoint (default `https://rpc.titanbuilder.xyz`).
- `options.fetch?: typeof fetch` — custom fetch implementation.

### `parseOverridesMessage(raw)`

Parse a raw payload (a WS frame or the JSON-RPC `result`) into an
`OverridesSnapshot`: metadata keys split out, addresses/slots lowercased,
empty `stateDiff`s dropped. Throws if `raw` is not a JSON object.

### `toStateOverride(snapshot, options?)`

Flatten a snapshot into viem's `StateOverride` array for `eth_call`.

- `options.pamms?: Address[]` — restrict to these pAMM entries (default all).
- `options.bebopDefault?: boolean` — inject the Bebop default slot when no
  Bebop entry is present (default `true`).

**Returns** `StateOverride` — diffs merged at slot level, words padded to 32
bytes.

### Types and constants

- `OverridesSnapshot { blockNumber?: bigint; timestampNs?: bigint; perPamm }`
  — `perPamm` maps pAMM address → contract address → slot → value.
- `OverridesSource { getOverrides(); close?() }` — implement to plug in a
  custom source.
- `BEBOP_DEFAULT_SLOT`, `DEFAULT_OVERRIDES_RPC_URL`, `DEFAULT_OVERRIDES_WS_URL`.

## `@propamm/sdk/common/*`

### `common/tokens`

`ETH_SENTINEL` (pass as `tokenIn`/`tokenOut` to signal native ETH), and the
mainnet token addresses `USDC`, `USDT`, `WETH`.

### `common/pamms`

`FERMI`, `BEBOP`, `KIPSELI` venue addresses; `PAMMS` name → address mapping
(`PammName = "fermi" | "bebop" | "kipseli"`). The Uniswap fallback is
intentionally absent — read it via `router.fallbackSwapRouter()`.

### `common/helpers`

#### `applySlippage(amount, bps)`

Shave `bps` basis points off `amount` — derive `amountOutMin` from a quote.

- `amount: bigint` — e.g. a quoted output.
- `bps: number` — integer in `[0, 10000]`; throws `RangeError` otherwise.

**Returns** `bigint` — `amount - amount * bps / 10000`.

#### `deadlineIn(seconds)`

Unix-timestamp deadline `seconds` from now. **Returns** `bigint`.

#### `parseEther` / `parseUnits` / `formatEther` / `formatUnits`

viem's unit conversion, re-exported: `parseUnits("1.5", 6)` → `1500000n`;
`formatUnits(1500000n, 6)` → `"1.5"`.

### `common/chains`, `common/accounts`

viem re-exports so basic usage needs no direct viem import: `mainnet`,
`anvil`, `sepolia` (+ the `Chain` type); `privateKeyToAccount`,
`mnemonicToAccount` (+ the `Account` type).
