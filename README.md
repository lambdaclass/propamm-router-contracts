# PropAMMRouter

Single-hop router that quotes and executes swaps against a proprietary AMM (FermiSwap, Kipseli, or Bebop) or directly against Uniswap V3, and falls back to Uniswap V3 when the chosen proprietary venue cannot fill the swap.

## Overview

Venues are identified **by address**: the three proprietary AMM routers (FermiSwap, Kipseli, Bebop) plus the Uniswap V3 fallback, denoted by the SwapRouter02 address wired in at deployment. The router exposes the following external functions (see `src/interfaces/IPropAMMRouter.sol` for the full NatSpec):

- `swapV1(tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline)`: pulls `amountIn` of `tokenIn` from `msg.sender`, routes through the best-quoting venue, and falls back to Uniswap V3 if that venue reverts or under-delivers. Returns `(amountOut, executedVenue)`, where `executedVenue` is the proprietary venue that filled or the SwapRouter02 address when the fallback ran. Reverts `QuoteBelowMinimum` before pulling funds if the best quote is below `amountOutMin`, and re-checks `amountOutMin` against the measured balance delta of `recipient` after execution. Reverts when the contract is paused (see [Pausing the contract](#pausing-the-contract)); quote functions remain callable.
- `swapViaVenueV1(venue, tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline)`: attempts the caller-specified `venue` first. A proprietary venue still falls back to Uniswap V3 if it fails to fill; naming the Uniswap V3 SwapRouter02 address routes directly to Uniswap V3 (it *is* the fallback, so there is nothing further to fall back to). Reverts `UnknownVenue` if `venue` is neither a whitelisted proprietary AMM nor the SwapRouter02 address.
- `swapViaSelectedVenuesV1(venues, tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline)`: like `swapV1`, but considers only the caller-supplied `venues` subset. An on-chain requote across them selects the best, which executes — with the Uniswap V3 fallback still applying as the transparent safety net if the chosen venue fails to fill. Reverts `NoQuotesAvailable` if none of the listed venues can be priced. Returns `(amountOut, executedVenue)`. List the SwapRouter02 address among `venues` to opt Uniswap V3 into the selection (it is not a selection candidate otherwise, only the execution-time safety net).
- `quoteV1(tokenIn, tokenOut, amount)`: quotes every venue (the proprietary AMMs and the Uniswap V3 fallback) and returns the best `amountOut` along with the venue address that produced it. Reverts `NoQuotesAvailable` if every venue is skipped or reverts.
- `quoteVenueV1(venue, tokenIn, tokenOut, amount)`: quotes a single venue by address. Reverts `UnknownVenue` for any address that is neither a proprietary AMM nor the SwapRouter02 fallback, and bubbles up any underlying venue revert.
- `quoteSelectedVenuesV1(venues, tokenIn, tokenOut, amountIn)`: quotes only the caller-supplied `venues` subset and returns the best `(bestAmountOut, bestVenue)`. Venues that revert (including non-whitelisted addresses) are skipped; reverts `NoQuotesAvailable` if none of them can be priced.

The Uniswap V3 fallback prices and swaps at a per-pair fee tier, resolved on every quote and swap: the owner-set override for that pair if one exists, otherwise the global `fallbackFee` (`3000`, i.e. the 0.30% tier, by default). Callers never pass a fee. The owner sets overrides with `setPairFee(tokenA, tokenB, fee)` or `setPairFees(tokenA[], tokenB[], fee[])` (order-independent; `fee == 0` clears an override), and retunes the global default with `setFallbackFee` — all without a contract upgrade. This lets stablecoin pairs use their tight tier (e.g. USDC/USDT at `100`) while volatile pairs keep `3000`/`10000`. Query the effective tier with `resolvedFee(tokenIn, tokenOut)` and the raw override with `getPairFee(tokenA, tokenB)`.

A from-scratch deploy is pre-seeded by `initialize` with the global `fallbackFee` (`3000`), the deep mainnet tiers — USDT/USDC at `100`, USDT/WETH and USDC/WETH at `500` — and the default propAMM venue whitelist (FermiSwap, Kipseli, Bebop), so no post-deploy config step is needed. This runs only in `initialize` (initializer-gated), so it does not re-apply when an existing proxy upgrades; those deployments restore the same config via `scripts/setupRouterVariables.s.sol`, which sets `fallbackFee`, the per-pair tiers, and re-adds the default venues. The owner can clear or retune any seeded tier afterward with `setPairFee`.

### Kipseli quote caveat

Kipseli does not expose a usable on-chain quote function. To price it, the router calls `Kipseli.simulateKipseliSwap`, which executes a real swap and then reverts with the resulting `amountOut` ABI-encoded in the revert payload. The router decodes that payload to recover the quote.

The Uniswap V3 fallback branch also prices via revert-based simulation, since QuoterV2 reverts with the simulated `amountOut`.

As a consequence:

- `quoteV1` and `quoteVenueV1` are not `view`. They must be called via `eth_call` (staticcall) from off-chain so the simulated swaps are rolled back automatically.
- The Kipseli simulation pulls `tokenIn` from the router's own balance. When quoting against Kipseli (directly via `quoteVenueV1`, or implicitly through `quoteV1`), the RPC call must include a `stateDiff` override that gives the router a sufficient balance of `tokenIn`. Without the override, the Kipseli branch is silently skipped while the other branches still quote.

### Frontend fees

Three implementation-only entrypoints take a per-call, basis-point fee from the swap
**output token** and forward it to a caller-supplied recipient. They are **not** part of
`IPropAMMRouter`; encode them against the deployed `PropAMMRouter`.

- `swapWithFeeV1(tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline, fee)`
- `swapViaVenueWithFeeV1(venue, tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline, fee)`
- `swapViaSelectedVenuesWithFeeV1(venues, tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline, fee)`

`fee` is a `FrontendFee { uint16 bps; address recipient }`:
- `bps` is the fee in basis points, capped at `MAX_FEE_BPS` (100 = 1.00%).
- `recipient` receives the fee in `tokenOut`; must be non-zero.

`amountOutMin` is the **net** amount the user must receive **after** the fee — the router
grosses it up internally, so the user always nets at least `amountOutMin`. The returned
`amountOut` and the `Swapped` event's `amountOut` are the **net** delivered to `recipient`.
A `FrontendFeeCharged` event is emitted whenever a non-zero fee is taken. Quote functions
are unchanged and return **gross** output; a frontend nets out by subtracting its own bps.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed.
- Node.js installed (required by `openzeppelin-foundry-upgrades` for storage layout validation during upgrades).
- A mainnet RPC URL (Infura, Alchemy, etc.) exported as `MAINNET_RPC_URL`.

### Deployment

**Important**: the PropAMMRouter depends on Ethereum mainnet state, since it interacts with the Fermi, Kipseli, and Bebop router addresses (and the UniswapV3 router fallback). Therefore, for local development we suggest using a fork of mainnet. You can start an anvil instance forking mainnet with:

```bash
anvil --fork-url https://ethereum-rpc.publicnode.com
```

To deploy the PropAMMRouter contract, run the `scripts/Deploy.s.sol` script. The script requires to set the `ROUTER_OWNER` environment variable, which defines the owner of the contract.

**Example:**

```bash
export ROUTER_OWNER=ROUTER_OWNER_ADDRESS
forge clean && forge script scripts/Deploy.s.sol \
    --broadcast \
    --rpc-url $RPC_URL \
    --private-key $DEPLOYER_KEY
```

### Running the fork tests

`test/PropAMMRouterForkTests.t.sol` tests the `PropAMMRouter` against a Foundry fork of mainnet, pinned to the block Titan publishes per request. Each test applies the per-venue Titan stateOverride via `vm.store` / `vm.deal` / `vm.setNonceUnsafe`, then runs a USDC → WETH swap and asserts the delivered `amountOut` is at least the venue's quoted `amountOut`.

Driven by `test/run_fork_tests.sh`, which:

1. Queries Titan for the latest per-PMM overrides, flattens them into JSON arrays Foundry's `parseJson` can decode, and exports them as env vars.
2. Forks mainnet at `min(titanBlock, rpcHead)` (the local RPC may lag Titan by 1-2 blocks; `vm.createSelectFork` rejects future blocks).
3. Runs `forge test --match-contract PropAMMRouterForkTests --gas-report -vvvv`.

**Required env vars:**

- `ETH_RPC_URL`: mainnet RPC endpoint
- `TITAN_URL` (optional): defaults to `https://us.rpc.titanbuilder.xyz`.

Run with:

```bash
export ETH_RPC_URL=<your mainnet RPC>
./test/run_fork_tests.sh
```

You can append any `forge test` flags (e.g. `--match-test test_swapViaVenueV1Kipseli`) — they're forwarded verbatim to the underlying `forge test` invocation.

### Quoting with Titan state overrides

The proprietary AMMs maintain off-chain liquidity that is not reflected by mainnet state, so a plain `eth_call` to `PropAMMRouter.quoteV1` against the anvil fork only sees stale liquidity. To get accurate quotes, Titan exposes the JSON-RPC method `titan_getPammStateOverrides`, whose result is passed as the third parameter of `eth_call`.
The Titan endpoint only serves `titan_getPammStateOverrides`. The `eth_call` itself is sent to the anvil fork.

The response is keyed by proprietary AMM router address, with one entry per venue:

```json
{
  "result": {
    "blockNumber": "0x...",
    "0xb1076fe3ab5e28005c7c323bac5ac06a680d452e": { "stateOverride": { ... } },
    "0x160141a205f5ddcf096ba3f48b7ed21eb52c62ea": { "stateOverride": { ... } },
    "0x5cdbe59400cc2efdcc2b54acca4a99fe00dd588c": { "stateOverride": { ... } }
  }
}
```

The three keys are the FermiSwap, Bebop, and Kipseli routers, respectively. When calling `quoteVenueV1(venue, ...)`, pick the entry matching the venue address you want to quote. Kipseli additionally requires the router to hold `tokenIn`, since `simulateKipseliSwap` transfers it to Kipseli; we fund it with a `stateDiff` over the token contract's `_balances` slot for the router. FermiSwap and Bebop ignore the balance override, so the same snippet works for all three proprietary venues (only the venue address needs to change). For the Uniswap V3 fallback (naming the SwapRouter02 address) the Titan overrides aren't needed at all — QuoterV2 only reads on-chain pool state — so you can skip the `titan_getPammStateOverrides` call entirely and pass an empty state override (or omit the third `eth_call` parameter).

**Example: quote 1 WETH for USDC against the deployed router on the anvil fork.**

```bash
RPC_URL=http://127.0.0.1:8545
ROUTER=<PropAMMRouter proxy address logged by Deploy.s.sol>
WETH=0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2
USDC=0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48

# === Pick the venue to quote (only edit this line) ===
# Venues are addresses: the Uniswap V3 fallback is the SwapRouter02 address;
# the three proprietary AMM routers are listed in the table below.
VENUE_ADDR=0x5cdbe59400cc2efdcc2b54acca4a99fe00dd588c    # Kipseli

# WETH stores balances in storage slot 3 (mapping(address => uint)).
# balanceOf[ROUTER] lives at keccak256(abi.encode(ROUTER, 3)).
WETH_BAL_SLOT=$(cast index address $ROUTER 3)

# 1. Fetch the venue's Titan overrides and fund the router with 10 WETH.
#    (Skip this step for the Uniswap V3 fallback — QuoterV2 only needs on-chain state.)
OVERRIDES=$(curl -s -X POST https://eu.rpc.titanbuilder.xyz \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"titan_getPammStateOverrides","params":[]}' \
    | jq -c --arg pamm "$VENUE_ADDR" --arg weth "$WETH" --arg slot "$WETH_BAL_SLOT" '
          .result[$pamm].stateOverride
        + { ($weth): { stateDiff: { ($slot): "0x0000000000000000000000000000000000000000000000008ac7230489e80000" } } }
      ')

# 2. eth_call PropAMMRouter.quoteVenueV1(venue, WETH, USDC, 1e18) with the overrides.
#    The Uniswap V3 fallback prices at the per-pair tier (the override for this
#    pair, else the global `fallbackFee`, 3000 by default); no per-call fee arg.
DATA=$(cast calldata "quoteVenueV1(address,address,address,uint256)" $VENUE_ADDR $WETH $USDC 1000000000000000000)

curl -s -X POST $RPC_URL -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{\"to\":\"$ROUTER\",\"data\":\"$DATA\"},\"latest\",$OVERRIDES]}" \
    | jq -r .result \
    | xargs cast --abi-decode "f()(uint256)"
```

This prints `amountOut`, e.g. `2115659878` (≈ 2115.66 USDC for 1 WETH, with USDC's 6 decimals) at the current state. To quote a different venue, edit only `VENUE_ADDR`:

| Venue | `VENUE_ADDR` |
|-------|--------------|
| Uniswap V3 fallback (SwapRouter02) | `0x68b3465833fb72a70ecdf485e0e4c7bd8665fc45` — skip the Titan call |
| FermiSwap | `0xb1076fe3ab5e28005c7c323bac5ac06a680d452e` |
| Kipseli | `0x5cdbe59400cc2efdcc2b54acca4a99fe00dd588c` |
| Bebop | `0x160141a205f5ddcf096ba3f48b7ed21eb52c62ea` |

### Pausing the contract

The router is `PausableUpgradeable`. The owner can stop all new swaps with:

- `pause()` — owner-gated; flips the contract into the paused state. While paused, `swapV1`, `swapViaVenueV1`, and `swapViaSelectedVenuesV1` revert with OpenZeppelin's `EnforcedPause` error. `quoteV1`, `quoteVenueV1`, and `quoteSelectedVenuesV1` are unaffected and remain callable.
- `unpause()` — owner-gated; clears the paused state and re-enables swaps.

Both functions are restricted to the proxy owner (the address passed as `ROUTER_OWNER` at deployment, or the current owner after an `Ownable2Step` handoff). The state initializes to unpaused on `initialize`.

### Upgrading the contract

Upgrades are authorized by the proxy owner via `_authorizeUpgrade` (`onlyOwner`), so they must be broadcast from the account that holds ownership of the proxy (the address passed as `ROUTER_OWNER` at deployment, or whoever currently holds ownership after an `Ownable2Step` handoff).

> **Config precondition:** The whole fresh-deploy configuration is seeded only in `initialize` — i.e. on a fresh deploy — and is never re-applied on upgrade. This bites a proxy that predates that config in two ways. (1) Unconfigured pairs resolve their Uniswap fallback tier to the global `fallbackFee`; an enum-era deployment carries `fallbackFee = 0` after the upgrade, so the fallback resolves to tier `0` (invalid on Uniswap V3) for every unconfigured pair and reverts. (2) An enum-era deployment also has an **empty venue whitelist**, so `swapV1` can only ever take the Uniswap fallback and never routes the propAMMs. **After upgrading such a proxy, run `scripts/setupRouterVariables.s.sol` as the owner** to restore the config: it sets `fallbackFee = 3000`, seeds the deep per-pair tiers, and re-adds the default venues (FermiSwap, Kipseli, Bebop), matching a fresh `initialize`. Until that runs, the Uniswap fallback is unusable, so consider `pause()`-ing the router across the upgrade + config window if swaps could arrive in between (see "Running the upgrade" below).

### Writing a new implementation

Place the new implementation under `src/` (for example `src/PropAMMRouterV2.sol`). It must:

1. **Have a compatible storage layout:** and only append new storage variables at the end. Never reorder, rename, or remove existing storage slots.
2. **Include the `@custom:oz-upgrades-from` annotation** pointing to the previous contract name. This is what triggers automatic storage-layout validation by `openzeppelin-foundry-upgrades`.
3. **Use `reinitializer(n)`** (not `initializer`) if the new version needs to initialize new state, where `n` is the next version number.

Example skeleton:

```solidity
/// @custom:oz-upgrades-from PropAMMRouter
contract PropAMMRouterV2 {
    uint256 private _newField; // appended at the end of storage

    function initializeV2(uint256 newField_) public reinitializer(2) {
        _newField = newField_;
    }
}
```

### Running the upgrade

The upgrade script lives at `scripts/Upgrade.s.sol`. It calls `Upgrades.upgradeProxy(proxy, newImplName, "")`, which deploys the new implementation, validates storage layout against the previous version, and calls `upgradeToAndCall` on the proxy in a single transaction.

It reads two environment variables:
- `ROUTER_PROXY`: address of the deployed proxy to upgrade.
- `ROUTER_IMPL_NAME`: filename of the new implementation in `src/` (e.g. `"PropAMMRouterV2.sol"`).

The script can be executed with the following command

```bash
export ROUTER_PROXY=<proxy address logged by Deploy.s.sol>
export ROUTER_IMPL_NAME=PropAMMRouterV2.sol
forge clean && forge script scripts/Upgrade.s.sol \
    --broadcast \
    --rpc-url $RPC_URL \
    --private-key $OWNER_KEY
```

`$OWNER_KEY` must be the private key of the current proxy owner; otherwise `_authorizeUpgrade` will revert.

The script does not pass any reinitializer calldata (the third argument to `Upgrades.upgradeProxy` is `""`). If the new implementation defines a `reinitializer`, edit `scripts/Upgrade.s.sol` to pass the encoded call (e.g. `abi.encodeCall(PropAMMRouterV2.initializeV2, (newField))`) before broadcasting.

When upgrading a proxy that predates the fresh-deploy config (see the precondition above), follow the upgrade immediately with the config script, broadcast from the same owner key:

```bash
forge script scripts/setupRouterVariables.s.sol \
    --broadcast \
    --rpc-url $RPC_URL \
    --private-key $OWNER_KEY
```

This sets `fallbackFee = 3000`, seeds the deep per-pair tiers, and re-adds the default propAMM venues (FermiSwap, Kipseli, Bebop), restoring the configuration a fresh `initialize` would have produced. The `addVenue` calls are guarded by `isWhitelistedVenue`, so the script is idempotent and safe to re-run. Until it runs, the Uniswap fallback reverts for unconfigured pairs and no propAMM venue is routable.
