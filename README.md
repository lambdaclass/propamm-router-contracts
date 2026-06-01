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

The Uniswap V3 fallback always prices and swaps at the `fallbackFee` pool tier (`3000`, i.e. the 0.30% tier, by default) — callers never pass a fee. For pairs whose deepest Uniswap V3 pool is not at the 0.30% tier (e.g. USDC/WETH on mainnet, which is `500`), an `UPGRADER_ROLE` holder retunes it with `setFallbackFee` (no contract upgrade required).

### Kipseli quote caveat

Kipseli does not expose a usable on-chain quote function. To price it, the router calls `Kipseli.simulateKipseliSwap`, which executes a real swap and then reverts with the resulting `amountOut` ABI-encoded in the revert payload. The router decodes that payload to recover the quote.

The Uniswap V3 fallback branch also prices via revert-based simulation, since QuoterV2 reverts with the simulated `amountOut`.

As a consequence:

- `quoteV1` and `quoteVenueV1` are not `view`. They must be called via `eth_call` (staticcall) from off-chain so the simulated swaps are rolled back automatically.
- The Kipseli simulation pulls `tokenIn` from the router's own balance. When quoting against Kipseli (directly via `quoteVenueV1`, or implicitly through `quoteV1`), the RPC call must include a `stateDiff` override that gives the router a sufficient balance of `tokenIn`. Without the override, the Kipseli branch is silently skipped while the other branches still quote.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed.
- Node.js installed (required by `openzeppelin-foundry-upgrades` for storage layout validation during upgrades).
- A mainnet RPC URL (Infura, Alchemy, etc.) exported as `MAINNET_RPC_URL`.

### Deployment

**Important**: the PropAMMRouter depends on Ethereum mainnet state, since it interacts with the Fermi, Kipseli, and Bebop router addresses (and the UniswapV3 router fallback). Therefore, for local development we suggest using a fork of mainnet. You can start an anvil instance forking mainnet with:

```bash
anvil --fork-url https://ethereum-rpc.publicnode.com
```

To deploy the PropAMMRouter contract, run the `scripts/Deploy.s.sol` script. It deploys a `RouterAccessManager` (an OpenZeppelin `AccessManager`) as the authority, deploys the router proxy under it, and activates the policy with a single `configureRouter` call.

The roles and their delays are contract constants:

- `UPGRADER_ROLE` — UUPS upgrades, fallback config (`setFallbackSwapRouter` / `setFallbackQuoter` / `setFallbackFee`), and `rescueTokens`. `UPGRADE_DELAY` = 7 days, so queued changes are publicly visible before they apply.
- `GUARDIAN_ROLE` — `pause()`. Zero delay: an instant circuit breaker for a security council.
- `RESUMER_ROLE` — `unpause()`. `RESUME_DELAY` = 2 hours, kept separate from the guardian because resuming is fail-open and should be deliberate.

Role grants happen in the manager's constructor; `configureRouter(proxy)` then wires the selectors and sets the re-gating delay (`ADMIN_DELAY` = 7 days). It is one-shot — it cannot be re-run to bypass `ADMIN_DELAY`; later changes go through the standard, delayed `AccessManager` interface. (To tune delays per network, change the constants in `RouterAccessManager` or promote them to immutable constructor args.)

The script only supplies the deployment-specific role holders and runs the optional governance handoff. Required environment variables:

- `ROUTER_ADMIN` — bootstrap admin of the manager; **must be the account you broadcast from**, since `configureRouter` and the handoff are admin-gated.
- `ROUTER_UPGRADER` — holder of `UPGRADER_ROLE`.
- `ROUTER_GUARDIAN` — holder of `GUARDIAN_ROLE`.

Optional (with defaults): `ROUTER_RESUMER` (defaults to `ROUTER_UPGRADER`), `GOV_ADMIN` (governance multisig to receive `ADMIN_ROLE`), `ADMIN_EXEC_DELAY` (7 days), and `RENOUNCE_BOOTSTRAP` (when `true`, the bootstrap admin renounces `ADMIN_ROLE` after the handoff). If `GOV_ADMIN` is omitted, `ROUTER_ADMIN` remains a delay-0 master key — hand it off and renounce it for production.

**Example:**

```bash
export ROUTER_ADMIN=<bootstrap admin = broadcaster>
export ROUTER_UPGRADER=<upgrader multisig>
export ROUTER_GUARDIAN=<security council>
export GOV_ADMIN=<governance multisig>      # optional but recommended
forge clean && forge script scripts/Deploy.s.sol \
    --broadcast \
    --rpc-url $RPC_URL \
    --private-key $DEPLOYER_KEY
```

`$DEPLOYER_KEY` must correspond to `ROUTER_ADMIN`.

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
#    The Uniswap V3 fallback always prices at the configured `fallbackFee` tier
#    (3000 by default); there is no per-call fee argument.
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

The router is `PausableUpgradeable`. Access is governed by the `RouterAccessManager`:

- `pause()` — held by `GUARDIAN_ROLE` with **zero delay**, so a security council can halt swaps instantly. While paused, `swapV1`, `swapViaVenueV1`, and `swapViaSelectedVenuesV1` revert with OpenZeppelin's `EnforcedPause` error. `quoteV1`, `quoteVenueV1`, and `quoteSelectedVenuesV1` are unaffected and remain callable.
- `unpause()` — held by `RESUMER_ROLE` with a short execution delay (default 2 hours). Because resuming is fail-open, it is deliberately *not* on the guardian's instant path: it is scheduled on the manager and executed after the delay.

The state initializes to unpaused on `initialize`.

### Upgrading the contract

Upgrades are gated through the `RouterAccessManager`: `_authorizeUpgrade` is `restricted`, and the `upgradeToAndCall` selector is assigned to `UPGRADER_ROLE`, which carries an execution delay (default 7 days). Upgrades therefore can no longer be applied in a single transaction — they are **scheduled** on the manager and **executed** after the delay, by the account holding `UPGRADER_ROLE`.

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

Because upgrades carry an execution delay, the flow is two steps:

**1. Schedule** with `scripts/Upgrade.s.sol`. It deploys and upgrade-safety-validates the new implementation via `Upgrades.prepareUpgrade` (without applying it), then schedules the `upgradeToAndCall` on the manager. It logs the new implementation address, the operation id, the timestamp at which it becomes executable, and the exact `EXEC_TARGET` / `EXEC_DATA` to use in step 2.

It reads:
- `ACCESS_MANAGER`: the `RouterAccessManager` address (logged by `Deploy.s.sol`).
- `ROUTER_PROXY`: address of the deployed proxy to upgrade.
- `ROUTER_IMPL_NAME`: filename of the new implementation in `src/` (e.g. `"PropAMMRouterV2.sol"`).
- `ROUTER_IMPL_REFERENCE` (optional): reference contract for storage-layout validation, unless the new implementation carries an `@custom:oz-upgrades-from` annotation.

```bash
export ACCESS_MANAGER=<manager address logged by Deploy.s.sol>
export ROUTER_PROXY=<proxy address logged by Deploy.s.sol>
export ROUTER_IMPL_NAME=PropAMMRouterV2.sol
forge clean && forge script scripts/Upgrade.s.sol \
    --broadcast --rpc-url $RPC_URL --private-key $UPGRADER_KEY
```

**2. Execute** with `scripts/Execute.s.sol` once the delay has elapsed, using the `EXEC_TARGET` / `EXEC_DATA` logged in step 1:

```bash
export ACCESS_MANAGER=<manager address>
export EXEC_TARGET=<proxy address>
export EXEC_DATA=<calldata logged by Upgrade.s.sol>
forge script scripts/Execute.s.sol \
    --broadcast --rpc-url $RPC_URL --private-key $UPGRADER_KEY
```

`$UPGRADER_KEY` must hold `UPGRADER_ROLE`, and **the same account must run both steps** — the scheduled operation is keyed by `(caller, target, data)`. Alternatively, after the delay the upgrader can call `upgradeToAndCall(newImpl, "")` on the proxy directly; the `restricted` modifier consumes the schedule.

The scheduled call passes no reinitializer calldata. If the new implementation defines a `reinitializer`, edit `scripts/Upgrade.s.sol` to encode it (e.g. `abi.encodeCall(PropAMMRouterV2.initializeV2, (newField))`) in place of the empty `""` before scheduling.
