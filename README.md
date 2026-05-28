# PropAMMRouter

Single-hop router that quotes and executes swaps against a proprietary AMM (FermiSwap, Kipseli, or Bebop) or directly against Uniswap V3, and falls back to Uniswap V3 when the chosen proprietary venue cannot fill the swap.

## Overview

The router exposes a `Venue` enum (`Fallback`, `FermiSwap`, `Kipseli`, `Bebop`) and the following external functions (see `src/interfaces/IPropAMMRouter.sol` for the full NatSpec):

- `swap(venue, tokenIn, tokenOut, amountIn, amountOutMin, recipient, uniswapFee, deadline)`: pulls `amountIn` of `tokenIn` from `msg.sender`, attempts the swap on the selected venue, and falls back to Uniswap V3 (using `uniswapFee` as the pool tier) if that venue reverts or under-delivers. Passing `Venue.Fallback` skips the proprietary AMMs and routes directly to Uniswap V3. Enforces `amountOutMin` on the measured balance delta of `recipient`. Reverts when the contract is paused (see [Pausing the contract](#pausing-the-contract)); quote functions remain callable.
- `quote(tokenIn, tokenOut, amount, uniswapFee)`: quotes every venue (the proprietary AMMs and the Uniswap V3 fallback at `uniswapFee`) and returns the best `amountOut` along with the venue that produced it. Reverts `NoQuotesAvailable` if every venue is skipped or reverts. A 3-arg overload `quote(tokenIn, tokenOut, amount)` uses `DEFAULT_FALLBACK_FEE` (`3000`, i.e. the 0.30% tier) for the Uniswap V3 branch.
- `quoteVenue(venue, tokenIn, tokenOut, amount, uniswapFee)`: quotes a single specified venue. Reverts `UnknownVenue` for unsupported enum values and bubbles up any underlying venue revert. A 4-arg overload `quoteVenue(venue, tokenIn, tokenOut, amount)` uses `DEFAULT_FALLBACK_FEE` when `venue` is `Venue.Fallback` (and is ignored otherwise).

For pairs whose deepest Uniswap V3 pool is not at the 0.30% tier (e.g. USDC/WETH on mainnet, which is `500`), prefer the explicit-fee overloads.

### Kipseli quote caveat

Kipseli does not expose a usable on-chain quote function. To price it, the router calls `Kipseli.simulateKipseliSwap`, which executes a real swap and then reverts with the resulting `amountOut` ABI-encoded in the revert payload. The router decodes that payload to recover the quote.

The Uniswap V3 `Venue.Fallback` branch also prices via revert-based simulation, since QuoterV2 reverts with the simulated `amountOut`.

As a consequence:

- `quote` and `quoteVenue` are not `view`. They must be called via `eth_call` (staticcall) from off-chain so the simulated swaps are rolled back automatically.
- The Kipseli simulation pulls `tokenIn` from the router's own balance. When quoting against Kipseli (directly via `quoteVenue`, or implicitly through `quote`), the RPC call must include a `stateDiff` override that gives the router a sufficient balance of `tokenIn`. Without the override, the Kipseli branch is silently skipped while the other branches still quote.

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

### Quoting with Titan state overrides

The proprietary AMMs maintain off-chain liquidity that is not reflected by mainnet state, so a plain `eth_call` to `PropAMMRouter.quote` against the anvil fork only sees stale liquidity. To get accurate quotes, Titan exposes the JSON-RPC method `titan_getPammStateOverrides`, whose result is passed as the third parameter of `eth_call`.
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

The three keys are the FermiSwap, Bebop, and Kipseli routers, respectively. When calling `quoteVenue(venue, ...)`, pick the entry matching the venue you want to quote. Kipseli additionally requires the router to hold `tokenIn`, since `simulateKipseliSwap` transfers it to Kipseli; we fund it with a `stateDiff` over the token contract's `_balances` slot for the router. FermiSwap and Bebop ignore the balance override, so the same snippet works for all three proprietary venues (only the address and the enum value need to change). For `Venue.Fallback` the Titan overrides aren't needed at all — Uniswap V3's QuoterV2 only reads on-chain pool state — so you can skip the `titan_getPammStateOverrides` call entirely and pass an empty state override (or omit the third `eth_call` parameter).

**Example: quote 1 WETH for USDC against the deployed router on the anvil fork.**

```bash
RPC_URL=http://127.0.0.1:8545
ROUTER=<PropAMMRouter proxy address logged by Deploy.s.sol>
WETH=0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2
USDC=0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48

# === Pick the venue to quote (only edit these two lines) ===
# Venue enum: 0 = Fallback (Uniswap V3), 1 = FermiSwap, 2 = Kipseli, 3 = Bebop.
VENUE_ADDR=0x5cdbe59400cc2efdcc2b54acca4a99fe00dd588c    # Kipseli
VENUE_ENUM=2

# WETH stores balances in storage slot 3 (mapping(address => uint)).
# balanceOf[ROUTER] lives at keccak256(abi.encode(ROUTER, 3)).
WETH_BAL_SLOT=$(cast index address $ROUTER 3)

# 1. Fetch the venue's Titan overrides and fund the router with 10 WETH.
#    (Skip this step for Venue.Fallback — QuoterV2 only needs on-chain state.)
OVERRIDES=$(curl -s -X POST https://eu.rpc.titanbuilder.xyz \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"titan_getPammStateOverrides","params":[]}' \
    | jq -c --arg pamm "$VENUE_ADDR" --arg weth "$WETH" --arg slot "$WETH_BAL_SLOT" '
          .result[$pamm].stateOverride
        + { ($weth): { stateDiff: { ($slot): "0x0000000000000000000000000000000000000000000000008ac7230489e80000" } } }
      ')

# 2. eth_call PropAMMRouter.quoteVenue(venue, WETH, USDC, 1e18) with the overrides.
#    This uses the no-fee overload, which falls back to DEFAULT_FALLBACK_FEE (3000)
#    when VENUE_ENUM is 0; for a different Uniswap V3 tier, use the 5-arg overload
#    `quoteVenue(uint8,address,address,uint256,uint24)`.
DATA=$(cast calldata "quoteVenue(uint8,address,address,uint256)" $VENUE_ENUM $WETH $USDC 1000000000000000000)

curl -s -X POST $RPC_URL -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{\"to\":\"$ROUTER\",\"data\":\"$DATA\"},\"latest\",$OVERRIDES]}" \
    | jq -r .result \
    | xargs cast --abi-decode "f()(uint256)"
```

This prints `amountOut`, e.g. `2115659878` (≈ 2115.66 USDC for 1 WETH, with USDC's 6 decimals) at the current state. To quote a different venue, edit only `VENUE_ADDR` and `VENUE_ENUM`:

| Venue | `VENUE_ADDR` | `VENUE_ENUM` |
|-------|--------------|--------------|
| Fallback (Uniswap V3) | n/a — skip the Titan call | `0` |
| FermiSwap | `0xb1076fe3ab5e28005c7c323bac5ac06a680d452e` | `1` |
| Kipseli | `0x5cdbe59400cc2efdcc2b54acca4a99fe00dd588c` | `2` |
| Bebop | `0x160141a205f5ddcf096ba3f48b7ed21eb52c62ea` | `3` |

### Running the fork tests

`test/PropAMMRouterForkTests.t.sol` tests `swapV1` and `swapViaVenueV1` against a Foundry fork of mainnet, pinned to the block Titan publishes per request. Each test applies the per-venue Titan stateOverride via `vm.store` / `vm.deal` / `vm.setNonceUnsafe`, then runs a USDC → WETH swap and asserts the delivered `amountOut` is at least the venue's quoted `amountOut`.

Driven by `scripts/run_fork_tests.sh`, which:

1. Queries Titan for the latest per-PMM overrides, flattens them into JSON arrays Foundry's `parseJson` can decode, and exports them as env vars.
2. Forks mainnet at `min(titanBlock, rpcHead)` (the local RPC may lag Titan by 1-2 blocks; `vm.createSelectFork` rejects future blocks).
3. Runs `forge test --match-contract PropAMMRouterForkTests --gas-report -vvvv`.

**Required env vars:**

- `ETH_RPC_URL`: mainnet RPC endpoint
- `TITAN_URL` (optional): defaults to `https://us.rpc.titanbuilder.xyz`.

Run with:

```bash
export ETH_RPC_URL=<your mainnet RPC>
./scripts/run_fork_tests.sh
```

You can append any `forge test` flags (e.g. `--match-test test_swapViaVenueV1Kipseli`) — they're forwarded verbatim to the underlying `forge test` invocation.

### Pausing the contract

The router is `PausableUpgradeable`. The owner can stop all new swaps with:

- `pause()` — owner-gated; flips the contract into the paused state. While paused, `swapV1` and `swapViaVenueV1` revert with OpenZeppelin's `EnforcedPause` error. `quote` and `quoteVenue` are unaffected and remain callable.
- `unpause()` — owner-gated; clears the paused state and re-enables `swapV1`.

Both functions are restricted to the proxy owner (the address passed as `ROUTER_OWNER` at deployment, or the current owner after an `Ownable2Step` handoff). The state initializes to unpaused on `initialize`.

### Upgrading the contract

Upgrades are authorized by the proxy owner via `_authorizeUpgrade` (`onlyOwner`), so they must be broadcast from the account that holds ownership of the proxy (the address passed as `ROUTER_OWNER` at deployment, or whoever currently holds ownership after an `Ownable2Step` handoff).

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
