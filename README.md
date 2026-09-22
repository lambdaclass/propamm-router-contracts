# PropAMMRouter

Single-hop router that quotes and executes swaps against a proprietary AMM (FermiSwap, Kipseli, Bebop, Tempest, TaurusFi, Metric, or El Zorro) or directly against Uniswap V3, and falls back to Uniswap V3 when the chosen proprietary venue cannot fill the swap.

## Deployed Contracts

The Prop AMM router contract is deployed on mainnet at `0x4ddf368080cd7946db5b459ad591c350158175e1`.

The PropAMMs the router interacts with are deployed at:
- Bebop: `0xB09AaA5614916d7AEb59C295C52c92ca82aDdD76`
- Fermi: `0x5979458912f80b96d30d4220af8e2e4925a33320`
- Kipseli: `0x71e790dd841c8a9061487cb3e78c288e75ce0b3d`
- Tempest: `0x00000003f1ec2379e79F58E12EC6C4F51Ee92149`
- TaurusFi: `0x217d58931A8549ca539426AA8152E33dAfc3d95A`
- Metric: `0xE715Dc29d2c273D0FC5A03e5Cca9CcB0Abb1dCDB`
- El Zorro: `0xCF211B4dD0D2be5C173Ea57Bcf938FC61d1d3bd3`

## Overview

Venues are identified **by address**: the proprietary AMM routers (FermiSwap, Kipseli, Bebop, Tempest, TaurusFi, Metric, El Zorro) plus the Uniswap V3 fallback, denoted by the SwapRouter02 address wired in at deployment. The router exposes the following external functions (see `src/interfaces/IPropAMMRouter.sol` for the full NatSpec and the [rationale](https://github.com/lambdaclass/propamm-router-contracts/blob/main/docs/rationale.md) document with some design decisions):

- `swapV1(tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline)`: pulls `amountIn` of `tokenIn` from `msg.sender`, routes through the best-quoting venue, and falls back to Uniswap V3 if that venue reverts or under-delivers. Returns `(amountOut, executedVenue)`, where `executedVenue` is the proprietary venue that filled or the SwapRouter02 address when the fallback ran. Routes to Uniswap V3 if the best propAMM quote is below `amountOutMin`, and checks `amountOutMin` against the measured balance delta of `recipient` after execution (`InsufficientOutput`). Reverts when the contract is paused (see [Pausing the contract](#pausing-the-contract)); quote functions remain callable.
- `swapViaVenueV1(venue, tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline)`: attempts the caller-specified `venue` first. A proprietary venue still falls back to Uniswap V3 if it fails to fill; naming the Uniswap V3 SwapRouter02 address routes directly to Uniswap V3 (it *is* the fallback, so there is nothing further to fall back to). Reverts `UnknownVenue` if `venue` is neither a whitelisted proprietary AMM nor the SwapRouter02 address.
- `swapViaSelectedVenuesV1(venues, tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline)`: like `swapV1`, but considers only the caller-supplied `venues` subset. An on-chain requote across them selects the best, which executes — with the Uniswap V3 fallback still applying as the transparent safety net if the chosen venue fails to fill. Routes to Uniswap V3 if none of the listed venues can be priced. Returns `(amountOut, executedVenue)`. List the SwapRouter02 address among `venues` to opt Uniswap V3 into the selection (it is not a selection candidate otherwise, only the execution-time safety net).
- `swapSplitV1(tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline)`: takes exactly the same arguments as `swapV1`, but plans and executes a split of `amountIn` across multiple whitelisted propAMM venues, on-chain, in the same transaction. Returns only `amountOut` — a split has no single executing venue, so there is nothing to put in `swapV1`'s second return slot. See [Splitting a swap across venues](#splitting-a-swap-across-venues) below.
- `quoteV1(tokenIn, tokenOut, amount)`: quotes every venue (the proprietary AMMs and the Uniswap V3 fallback) and returns the best `amountOut` along with the venue address that produced it. Reverts `NoQuotesAvailable` if every venue is skipped or reverts.
- `quoteVenueV1(venue, tokenIn, tokenOut, amount)`: quotes a single venue by address. Reverts `UnknownVenue` for any address that is neither a proprietary AMM nor the SwapRouter02 fallback, and bubbles up any underlying venue revert.
- `quoteSelectedVenuesV1(venues, tokenIn, tokenOut, amountIn)`: quotes only the caller-supplied `venues` subset and returns the best `(bestAmountOut, bestVenue)`. Venues that revert (including non-whitelisted addresses) are skipped; reverts `NoQuotesAvailable` if none of them can be priced.

The Uniswap V3 fallback prices and swaps at a per-pair fee tier, resolved on every quote and swap: the per-pair override for that pair if one exists, otherwise the global `fallbackFee` (`3000`, i.e. the 0.30% tier, by default). Callers never pass a fee. An `UPGRADER_ROLE` holder sets overrides with `setPairFee(tokenA, tokenB, fee)` or `setPairFees(tokenA[], tokenB[], fee[])` (order-independent; `fee == 0` clears an override), and retunes the global default with `setFallbackFee` — all without a contract upgrade. This lets stablecoin pairs use their tight tier (e.g. USDC/USDT at `100`) while volatile pairs keep `3000`/`10000`. Query the effective tier with `resolvedFee(tokenIn, tokenOut)` and the raw override with `getPairFee(tokenA, tokenB)`.

A from-scratch deploy is pre-seeded by `initialize` with the global `fallbackFee` (`3000`) and the deep mainnet tiers — USDT/USDC at `100`, USDT/WETH and USDC/WETH at `500` — so the Uniswap fallback needs no post-deploy fee configuration. This runs only in `initialize` (initializer-gated), so it does not re-apply when an existing proxy upgrades. An `UPGRADER_ROLE` holder can clear or retune any seeded tier afterward with `setPairFee`.

The **venue whitelist is not seeded**: `initialize` leaves `_whitelistedVenues` empty, so a freshly deployed router can only take the Uniswap V3 fallback until a `LISTING_ROLE` holder lists each propAMM with `addVenue` (see [Deployment](#deployment)). The venues to list are the addresses in [Deployed Contracts](#deployed-contracts) above. Because `_pickBestVenue` iterates the live set, a venue added this way is picked up by `swapV1` / `quoteV1` immediately, with no contract upgrade.

### Kipseli quote caveat

Kipseli does not expose a usable on-chain quote function. To price it, the router calls `Kipseli.simulateKipseliSwap`, which executes a real swap and then reverts with the resulting `amountOut` ABI-encoded in the revert payload. The router decodes that payload to recover the quote.

The Uniswap V3 fallback branch also prices via revert-based simulation, since QuoterV2 reverts with the simulated `amountOut`.

As a consequence:

- `quoteV1` and `quoteVenueV1` are not `view`. They must be called via `eth_call` (staticcall) from off-chain so the simulated swaps are rolled back automatically.
- The Kipseli simulation pulls `tokenIn` from the router's own balance. When quoting against Kipseli (directly via `quoteVenueV1`, or implicitly through `quoteV1`), the RPC call must include a `stateDiff` override that gives the router a sufficient balance of `tokenIn`. Without the override, the Kipseli branch is silently skipped while the other branches still quote.

### Frontend fees

Four entrypoints take a per-call, basis-point fee from the swap **output token** and
forward it to a caller-supplied recipient. They are declared in `IPropAMMRouter` like
every other entrypoint (each implemented with `@inheritdoc`); encode them against the
deployed `PropAMMRouter`.

- `swapWithFeeV1(tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline, fee)`
- `swapViaVenueWithFeeV1(venue, tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline, fee)`
- `swapViaSelectedVenuesWithFeeV1(venues, tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline, fee)`
- `swapSplitWithFeeV1(tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline, fee)` — `swapSplitV1` with a fee skimmed from the split's aggregate output; see [Fee basis](#fee-basis) below for how this interacts with the per-leg `Swapped` events.

`fee` is a `FrontendFee { uint16 bps; address recipient }`:
- `bps` is the fee in basis points, capped at `MAX_FEE_BPS` (100 = 1.00%).
- `recipient` receives the fee in `tokenOut`; must be non-zero.

`amountOutMin` is the **net** amount the user must receive **after** the fee — the router
grosses it up internally, so the user always nets at least `amountOutMin`. The returned
`amountOut` and the `Swapped` event's `amountOut` are the **net** delivered to `recipient`
for the single-venue variants (`swapSplitWithFeeV1`'s per-leg `Swapped` events are
**gross** — see [Fee basis](#fee-basis)). A `FrontendFeeCharged` event is emitted whenever
a non-zero fee is taken. Quote functions are unchanged and return **gross** output; a
frontend nets out by subtracting its own bps.

### Splitting a swap across venues

`swapSplitV1(tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline)` plans and
executes a split of one exact-input order across whitelisted propAMM venues, entirely
on-chain, in the same transaction that runs it — no off-chain solver, no caller-supplied
route. It takes **exactly the same arguments as `swapV1`** and returns only `amountOut`,
because a split has no single executing venue — there is nothing to put in `swapV1`'s
`executedVenue` slot. A caller that ignores `swapV1`'s second return value switches to
`swapSplitV1` with a one-word change; a caller that destructures both return values
adapts by dropping one line. `swapSplitWithFeeV1` is the fee-charging counterpart, taking
the same `FrontendFee` as the other `*WithFeeV1` entrypoints (see
[Frontend fees](#frontend-fees) above).

The router probes every whitelisted venue for capacity, ranks what it finds against a
Uniswap V3 reference quote, and places up to `MAX_LEGS = 5` propAMM legs. Any input that
isn't placed on a propAMM leg — because a venue had no more capacity, or because none was
whitelisted — is coalesced into one Uniswap V3 remainder leg. That remainder is exempt
from the `MAX_LEGS` cap: it's the safety net every split falls back on, not a planning
choice, so a split executes **at most 6 legs total** (5 propAMM + 1 coalesced Uniswap).

`MAX_SPLIT_VENUES = 12` bounds how large the whitelist can grow before `swapSplitV1` /
`swapSplitWithFeeV1` stop working: `isSplitAvailable()` returns `false` once the
whitelist outgrows that bound, and past it the split entrypoints revert `TooManyVenues`
rather than silently probing an arbitrary subset (`EnumerableSet` ordering shifts on
removal, so "the first 12" would be nondeterministic across calls). Every other
entrypoint (`swapV1`, `quoteV1`, ...) is unaffected by the whitelist size. **Listing a
venue past `MAX_SPLIT_VENUES` with `addVenue` disables both split entrypoints** — check
`isSplitAvailable()` first if you plan to keep splitting available.

#### Competing on size: `IPropAMMFillable`

By default the router discovers a venue's capacity with a blind two-point quote probe
(at the full order size and at half of it), which only locates capacity within roughly 2x
of the order size — a venue whose real depth is far below or far above what those two
points see is priced poorly or missed entirely. A propAMM can do better by implementing
`IPropAMMFillable` (advertised via ERC-165):

```solidity
function quoteFillable(address tokenIn, address tokenOut, uint256 amountIn)
    external
    returns (uint256 fillableAmountIn, uint256 amountOut);
```

Given an offered `amountIn`, the venue reports back how much of it it will actually take
(`fillableAmountIn`) and what it pays for exactly that amount (`amountOut` — never the
output for the full `amountIn`). The router enforces `fillableAmountIn <= amountIn` by
**discarding** a venue that reports more, not by clamping it down to `amountIn`: clamping
would keep the inflated `amountOut` against a smaller fill, inflating that venue's
apparent rate by exactly the over-report and letting it sweep the ranking ahead of honest
venues before its own leg fails. Implementing this interface — priced in a single call,
independent of the router's probe size — is how a venue competes on orders far larger
than its own inventory, something the blind two-point probe cannot discover on its own.

#### The MEV caveat — read this before setting `amountOutMin`

**A propAMM leg that fails at execution time has its input absorbed into the coalesced
Uniswap remainder, and that remainder's only floor is the aggregate shortfall against
`amountOutMin`.** That shortfall is **zero** whenever the legs that already succeeded
clear `amountOutMin` on their own — which is the normal outcome of splitting into venues
that quote better than Uniswap in the first place. So in the common case, the coalesced
slice that absorbs a failed leg executes with **no minimum output at all**, and an
attacker who sandwiches it can capture the full difference between what it actually
delivers and `amountOutMin`.

The user can never receive less than `amountOutMin` in total, so the loss from this is
bounded by the user's own stated tolerance — but that means **`amountOutMin` is the only
lever protecting a split, and it should be set tight.** This is a deliberate, accepted
consequence of this design: there is no `fallbackMinOut` parameter (unlike the split
design this superseded) to give the coalesced remainder its own floor. Do not treat this
as a bug to be softened by loosening the aggregate check — the tradeoff is intentional,
and the fix is a tight `amountOutMin` on the caller's side.

#### Fee basis

On `swapSplitWithFeeV1`, `amountOutMin` is the **net** amount the user must be left with
**after** the fee (grossed up internally before planning, same as the other
`*WithFeeV1` entrypoints), and the returned `amountOut` is the **net** amount delivered.
The per-leg `Swapped` events, however, are **gross** — one is emitted per executed leg
(including the coalesced Uniswap remainder), before the fee is skimmed. So the net amount
the user actually keeps is:

```
net = SUM(Swapped.amountOut for this tx) − FrontendFeeCharged.feeAmount
```

not any single `Swapped.amountOut` on its own.

#### Event semantics

`swapSplitV1` and `swapSplitWithFeeV1` emit **one `Swapped` event per executed leg** —
up to 6 of them for a single call (see above). This means `(txHash)` is no longer a
unique key for "one swap" the way it is for the single-venue entrypoints: an indexer
that assumed one `Swapped` per transaction must key on `(txHash, logIndex)` instead. The
`Swapped` event's ABI is unchanged; only how many of them a single transaction can emit.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed.
- Node.js installed (required by `openzeppelin-foundry-upgrades` for storage layout validation during upgrades).
- A mainnet RPC URL (Infura, Alchemy, etc.) exported as `MAINNET_RPC_URL`.

### Deployment

**Important**: the PropAMMRouter depends on Ethereum mainnet state, since it interacts with the propAMM router addresses listed in [Deployed Contracts](#deployed-contracts) (and the UniswapV3 router fallback). Therefore, for local development we suggest using a fork of mainnet. You can start an anvil instance forking mainnet with:

```bash
anvil --fork-url https://ethereum-rpc.publicnode.com
```

To deploy the PropAMMRouter contract, run the `scripts/Deploy.s.sol` script. It deploys a `RouterAccessManager` (an OpenZeppelin `AccessManager`) as the authority, deploys the router proxy under it, and activates the policy with a single `configureRouter` call.

The roles and their delays are contract constants:

- `UPGRADER_ROLE` — UUPS upgrades, fallback config (`setFallbackSwapRouter` / `setFallbackQuoter` / `setFallbackFee`), per-pair fee tuning (`setPairFee` / `setPairFees`), and `rescueTokens`. `UPGRADE_DELAY` = 7 days, so queued changes are publicly visible before they apply.
- `GUARDIAN_ROLE` — `pause()`. Zero delay: an instant circuit breaker for a security council.
- `RESUMER_ROLE` — `unpause()`. `RESUME_DELAY` = 2 hours, kept separate from the guardian because resuming is fail-open and should be deliberate.
- `LISTING_ROLE` — venue whitelist management (`addVenue` / `removeVenue`). `LISTING_DELAY` = 1 day — a separate, operations-paced account, since listing is lower blast-radius than an upgrade (a bad venue just reverts and the Uniswap fallback engages).

Role grants happen in the manager's constructor; `configureRouter(proxy)` then wires the selectors and sets the re-gating delay (`ADMIN_DELAY` = 7 days). It is one-shot — it cannot be re-run to bypass `ADMIN_DELAY`; later changes go through the standard, delayed `AccessManager` interface. (To tune delays per network, change the constants in `RouterAccessManager` or promote them to immutable constructor args.)

The script only supplies the deployment-specific role holders and runs the optional governance handoff. Required environment variables:

- `ROUTER_ADMIN` — bootstrap admin of the manager; **must be the account you broadcast from**, since `configureRouter` and the handoff are admin-gated.
- `ROUTER_UPGRADER` — holder of `UPGRADER_ROLE`.
- `ROUTER_GUARDIAN` — holder of `GUARDIAN_ROLE`.

Optional (with defaults): `ROUTER_RESUMER` (defaults to `ROUTER_UPGRADER`), `ROUTER_LISTER` (defaults to `ROUTER_UPGRADER`), `GOV_ADMIN` (governance multisig to receive `ADMIN_ROLE`), `ADMIN_EXEC_DELAY` (7 days), and `RENOUNCE_BOOTSTRAP` (when `true`, the bootstrap admin renounces `ADMIN_ROLE` after the handoff). If `GOV_ADMIN` is omitted, `ROUTER_ADMIN` remains a delay-0 master key — hand it off and renounce it for production.

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
    "0x5979458912f80b96d30d4220af8e2e4925a33320": { "stateOverride": { ... } },
    "0xb09aaa5614916d7aeb59c295c52c92ca82addd76": { "stateOverride": { ... } },
    "0x71e790dd841c8a9061487cb3e78c288e75ce0b3d": { "stateOverride": { ... } }
  }
}
```

The keys are propAMM router addresses — above, FermiSwap, Bebop, and Kipseli respectively. A snapshot only carries the venues Titan has fresh state for, so the set of keys varies between calls. When calling `quoteVenueV1(venue, ...)`, pick the entry matching the venue address you want to quote. Kipseli additionally requires the router to hold `tokenIn`, since `simulateKipseliSwap` transfers it to Kipseli; we fund it with a `stateDiff` over the token contract's `_balances` slot for the router. The other venues ignore the balance override, so the same snippet works for every proprietary venue (only the venue address needs to change). For the Uniswap V3 fallback (naming the SwapRouter02 address) the Titan overrides aren't needed at all — QuoterV2 only reads on-chain pool state — so you can skip the `titan_getPammStateOverrides` call entirely and pass an empty state override (or omit the third `eth_call` parameter).

**Example: quote 1 WETH for USDC against the deployed router on the anvil fork.**

```bash
RPC_URL=http://127.0.0.1:8545
ROUTER=<PropAMMRouter proxy address logged by Deploy.s.sol>
WETH=0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2
USDC=0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48

# === Pick the venue to quote (only edit this line) ===
# Venues are addresses: the Uniswap V3 fallback is the SwapRouter02 address;
# the proprietary AMM routers are listed in the table below.
VENUE_ADDR=0x71e790dd841c8a9061487cb3e78c288e75ce0b3d    # Kipseli

# WETH stores balances in storage slot 3 (mapping(address => uint)).
# balanceOf[ROUTER] lives at keccak256(abi.encode(ROUTER, 3)).
WETH_BAL_SLOT=$(cast index address $ROUTER 3)

# 1. Fetch the venue's Titan overrides and fund the router with 10 WETH.
#    (Skip this step for the Uniswap V3 fallback — QuoterV2 only needs on-chain state.)
OVERRIDES=$(curl -s -X POST https://eu.data.titanbuilder.xyz \
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
| FermiSwap | `0x5979458912f80b96d30d4220af8e2e4925a33320` |
| Kipseli | `0x71e790dd841c8a9061487cb3e78c288e75ce0b3d` |
| Bebop | `0xB09AaA5614916d7AEb59C295C52c92ca82aDdD76` |
| Tempest | `0x00000003f1ec2379e79F58E12EC6C4F51Ee92149` |
| TaurusFi | `0x217d58931A8549ca539426AA8152E33dAfc3d95A` |
| Metric | `0xE715Dc29d2c273D0FC5A03e5Cca9CcB0Abb1dCDB` |
| El Zorro | `0xCF211B4dD0D2be5C173Ea57Bcf938FC61d1d3bd3` |

### Pausing the contract

The router is `PausableUpgradeable`. Access is governed by the `RouterAccessManager`:

- `pause()` — held by `GUARDIAN_ROLE` with **zero delay**, so a security council can halt swaps instantly. While paused, `swapV1`, `swapViaVenueV1`, and `swapViaSelectedVenuesV1` revert with OpenZeppelin's `EnforcedPause` error. `quoteV1`, `quoteVenueV1`, and `quoteSelectedVenuesV1` are unaffected and remain callable.
- `unpause()` — held by `RESUMER_ROLE` with a short execution delay (default 2 hours). Because resuming is fail-open, it is deliberately *not* on the guardian's instant path: it is scheduled on the manager and executed after the delay.

The state initializes to unpaused on `initialize`.

### Upgrading the contract

Upgrades are gated through the `RouterAccessManager`: `_authorizeUpgrade` is `restricted`, and the `upgradeToAndCall` selector is assigned to `UPGRADER_ROLE`, which carries an execution delay (default 7 days). Upgrades therefore can no longer be applied in a single transaction — they are **scheduled** on the manager and **executed** after the delay, by the account holding `UPGRADER_ROLE`.

> **Config precondition:** The whole fresh-deploy configuration is seeded only in `initialize` — i.e. on a fresh deploy — and is never re-applied on upgrade. This bites a proxy that predates that config in two ways. (1) Unconfigured pairs resolve their Uniswap fallback tier to the global `fallbackFee`; an enum-era deployment carries `fallbackFee = 0` after the upgrade, so the fallback resolves to tier `0` (invalid on Uniswap V3) for every unconfigured pair and reverts. (2) An enum-era deployment also has an **empty venue whitelist**, so `swapV1` can only ever take the Uniswap fallback and never routes the propAMMs. **After upgrading such a proxy, restore the config manually** to match a fresh `initialize`: call `setFallbackFee(3000)` and `setPairFees` for the deep tiers (USDT/USDC at `100`, USDT/WETH and USDC/WETH at `500`) as an `UPGRADER_ROLE` holder, then `addVenue` for each propAMM in [Deployed Contracts](#deployed-contracts) as a `LISTING_ROLE` holder. Until the fee backfill runs, the Uniswap fallback is unusable, so consider `pause()`-ing the router across the upgrade + config window if swaps could arrive in between (see "Running the upgrade" below).

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
