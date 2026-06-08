# RouterAccessManager: how access control works and how to call restricted functions

The router's administrative surface is governed by [`RouterAccessManager`](../src/RouterAccessManager.sol), an [OpenZeppelin `AccessManager`](https://docs.openzeppelin.com/contracts/5.x/access-control#access-management) that acts as the single authority for every `restricted` function on `BlitzRouter`. This document explains the model, the roles and delays in force, and — operationally — how each restricted function must be called.

## The model in one paragraph

`BlitzRouter` is `AccessManagedUpgradeable`: every admin entrypoint carries the `restricted` modifier, which asks the manager "can this caller invoke this selector on this target, and with what delay?". The manager holds the whole policy as state: a map from `(target, selector)` to a **role**, and per-`(role, account)` **execution delays**. A caller with the right role and a **zero** delay calls the router directly, in one transaction. A caller whose role carries a **non-zero** delay cannot: they must first **schedule** the operation on the manager, wait out the delay (during which the pending operation is publicly visible on-chain), and then **execute** it. This makes the manager double as a timelock — there is no separate timelock contract.

```
zero-delay role             non-zero-delay role
───────────────             ───────────────────
caller ──► router.f()       caller ──► manager.schedule(router, data, when)
                                          │  (wait ≥ execution delay)
                                          ▼
                            caller ──► manager.execute(router, data)
                                          └──► router.f()
```

Unlike a plain `AccessManager`, the policy here is **codified in the contract** rather than assembled by a deployment script: the role catalog and delays are constants, the role grants happen in the constructor, and a one-shot `configureRouter(router)` wires the router's selectors to the roles. A deployer never supplies per-selector wiring or delay values off-chain.

## Roles and delays

Role IDs are `uint64`. Two are inherited from OpenZeppelin: `ADMIN_ROLE = 0` (can manage the policy itself) and `PUBLIC_ROLE = 2**64-1` (everyone; unused here). The router-specific catalog:

| Role | ID | Execution delay | Governs (selectors on the router) |
|---|---|---|---|
| `UPGRADER_ROLE` | 1 | `UPGRADE_DELAY` = **7 days** | `upgradeToAndCall`, `setFallbackSwapRouter`, `setFallbackQuoter`, `setFallbackFee`, `setPairFee`, `setPairFees`, `rescueTokens` |
| `GUARDIAN_ROLE` | 2 | **0 (instant)** | `pause` |
| `RESUMER_ROLE` | 3 | `RESUME_DELAY` = **2 hours** | `unpause` |
| `LISTING_ROLE` | 4 | `LISTING_DELAY` = **1 day** | `addVenue`, `removeVenue` |
| `ADMIN_ROLE` | 0 | per-grant (bootstrap admin: 0; governance: `ADMIN_EXEC_DELAY`, default 7 days) | the manager itself: `grantRole`, `revokeRole`, `setTargetFunctionRole`, `setTargetAdminDelay`, `configureRouter`, … |

Why the delays differ:

- **Pausing is fail-safe** — halting swaps can't lose funds, so the guardian gets an instant circuit breaker.
- **Unpausing is fail-open** — resuming should be deliberate, hence a short but non-zero delay, and a role distinct from the guardian's.
- **Listing is operational and low blast-radius** — a bad venue just reverts and the Uniswap fallback engages, so 1 day suffices.
- **Upgrades and fallback/fee/rescue config are the slow path** — 7 days makes every queued change publicly visible long before it takes effect.

There is additionally a **target admin delay** on the router (`ADMIN_DELAY` = 7 days), set by `configureRouter`. It does not gate router calls; it gates *re-gating* — future `setTargetFunctionRole` / `setTargetAdminDelay` calls aimed at the router go through that delay too, so the policy itself cannot be silently rewired.

## How to call each function

### Instant path (zero execution delay)

Only `pause()` qualifies. The `GUARDIAN_ROLE` holder calls the router directly:

```solidity
BlitzRouter(proxy).pause();
```

One transaction, effective immediately. (The bootstrap `ADMIN_ROLE` holder, while it exists with delay 0, can also call anything directly — see [Deployment and bootstrap](#deployment-and-bootstrap).)

### Delayed path (everything else)

Every other restricted function is held by a role with a non-zero execution delay, so a direct call to the router **reverts** with `AccessManagedRequiredDelay`. The flow is always the same two steps, both **from the same account** (the role holder):

**1. Schedule** the exact call on the manager:

```solidity
bytes memory data = abi.encodeCall(BlitzRouter.unpause, ());
// when = 0 means "earliest allowed": block.timestamp + the caller's execution delay.
(bytes32 operationId, uint32 nonce) = manager.schedule(address(proxy), data, 0);
```

`when` may also be an explicit timestamp, as long as it is at least `block.timestamp + delay`. `manager.getSchedule(operationId)` returns the timestamp at which the operation becomes executable.

**2. Execute** once the delay has elapsed. Two equivalent options:

```solidity
// (a) through the manager, with the identical calldata:
manager.execute(address(proxy), data);

// (b) directly on the router — the `restricted` modifier detects and
//     consumes the matching schedule:
BlitzRouter(proxy).unpause();
```

Key mechanics to be aware of:

- **Operations are keyed by `(caller, target, data)`** — `operationId = keccak256(abi.encode(caller, target, data))`. The account that schedules **must** be the account that executes, and the calldata must match byte-for-byte. Argument changes mean a different operation.
- **Operations expire.** An operation is executable from its `when` timestamp until `when + expiration()` (OpenZeppelin default: **1 week**). Past that, execution reverts with `AccessManagerExpired` and the call must be re-scheduled.
- **Scheduling is not consent by anyone else.** Anything a role holder schedules will be executable after the delay unless cancelled. Monitoring `OperationScheduled` events on the manager is how the public (and the team) audits pending changes.
- **Cancelling:** `manager.cancel(caller, target, data)` can be called by the scheduler themselves, an `ADMIN_ROLE` holder, or a *guardian of the scheduler's role* (`setRoleGuardian`; none configured by default — admins and the scheduler are the cancellers in practice).
- **One pending instance per operation id.** Re-scheduling the same `(caller, target, data)` while one is pending reverts with `AccessManagerAlreadyScheduled`; cancel first or wait for expiry.

### Concrete recipes

#### Pause / unpause

```bash
# Guardian: instant.
cast send $ROUTER_PROXY "pause()" --private-key $GUARDIAN_KEY

# Resumer: schedule, wait 2 hours, execute.
DATA=$(cast calldata "unpause()")
cast send $ACCESS_MANAGER "schedule(address,bytes,uint48)" $ROUTER_PROXY $DATA 0 \
  --private-key $RESUMER_KEY
# ... ≥ 2 hours later, same account:
cast send $ACCESS_MANAGER "execute(address,bytes)" $ROUTER_PROXY $DATA \
  --private-key $RESUMER_KEY
```

#### Venue whitelist (`addVenue` / `removeVenue`)

Same pattern from the `LISTING_ROLE` holder, with a 1-day delay:

```bash
DATA=$(cast calldata "addVenue(address)" $VENUE)
cast send $ACCESS_MANAGER "schedule(address,bytes,uint48)" $ROUTER_PROXY $DATA 0 \
  --private-key $LISTER_KEY
# ... ≥ 1 day later:
cast send $ACCESS_MANAGER "execute(address,bytes)" $ROUTER_PROXY $DATA \
  --private-key $LISTER_KEY
```

#### Fallback / fee config and `rescueTokens`

Same pattern from the `UPGRADER_ROLE` holder, with the 7-day delay. E.g. retuning the global fallback fee:

```bash
DATA=$(cast calldata "setFallbackFee(uint24)" 3000)
cast send $ACCESS_MANAGER "schedule(address,bytes,uint48)" $ROUTER_PROXY $DATA 0 \
  --private-key $UPGRADER_KEY
# ... ≥ 7 days later:
cast send $ACCESS_MANAGER "execute(address,bytes)" $ROUTER_PROXY $DATA \
  --private-key $UPGRADER_KEY
```

#### UUPS upgrades

`_authorizeUpgrade` is `restricted` and the `upgradeToAndCall` selector maps to `UPGRADER_ROLE`, so upgrades can no longer happen in a single transaction. Two scripts wrap the flow:

1. **Schedule** with [`scripts/Upgrade.s.sol`](../scripts/Upgrade.s.sol) (broadcast by the `UPGRADER_ROLE` holder). It deploys the new implementation, runs the OpenZeppelin upgrade-safety validations, and schedules `upgradeToAndCall(newImpl, "")` on the manager. It logs the `operationId`, the ready-at timestamp, and the exact `EXEC_TARGET` / `EXEC_DATA` for step 2.

   ```bash
   ACCESS_MANAGER=0x... ROUTER_PROXY=0x... ROUTER_IMPL_NAME="BlitzRouterV2.sol" \
   ROUTER_IMPL_REFERENCE="BlitzRouter.sol" \
   forge script scripts/Upgrade.s.sol --rpc-url $RPC --broadcast --private-key $UPGRADER_KEY
   ```

2. **Execute** with [`scripts/Execute.s.sol`](../scripts/Execute.s.sol) after the 7 days, **from the same account**, with the logged values:

   ```bash
   ACCESS_MANAGER=0x... EXEC_TARGET=0x<proxy> EXEC_DATA=0x<data> \
   forge script scripts/Execute.s.sol --rpc-url $RPC --broadcast --private-key $UPGRADER_KEY
   ```

`Execute.s.sol` is generic — it executes *any* ready scheduled operation (unpause, fee config, rescue, …), not just upgrades.

## Managing the policy itself (`ADMIN_ROLE`)

The manager is its own target: role and policy management go through `ADMIN_ROLE`, subject to that holder's own execution delay (so a governance admin granted with a 7-day delay must also schedule-then-execute its `grantRole` / `setTargetFunctionRole` calls on the manager).

- **Granting / revoking roles:** `grantRole(roleId, account, executionDelay)` / `revokeRole(roleId, account)`. The `executionDelay` passed at grant time is what gates that account's restricted calls. Multiple accounts can hold the same role with different delays.
- **Changing an account's delay:** re-`grantRole` with the new delay. *Decreasing* a delay does not take effect immediately — it phases in after the old delay's worth of setback, so a compromised holder can't shorten their own waiting period instantly. Increases apply immediately.
- **Re-gating the router:** `setTargetFunctionRole(router, selectors, role)` and `setTargetAdminDelay(router, delay)` are themselves subject to the router's target admin delay (`ADMIN_DELAY` = 7 days; delay changes phase in after `minSetback()` = 5 days).
- **Role labels:** the constructor emits `RoleLabel` for UPGRADER/GUARDIAN/RESUMER/LISTING — cosmetic, for explorer and dashboard discoverability.

## Deployment and bootstrap

[`scripts/Deploy.s.sol`](../scripts/Deploy.s.sol) performs the whole sequence atomically:

1. **Deploy the manager.** The constructor takes the five role holders (`initialAdmin`, `upgrader`, `guardian`, `resumer`, `lister`) and grants the four router roles immediately (grant delay 0) with their codified execution delays. `initialAdmin` gets `ADMIN_ROLE` with **zero** delay — a temporary master key used only for bootstrap.
2. **Deploy the router proxy** with the manager as its authority (`initialize(..., address(manager))`).
3. **`configureRouter(proxy)`** — one-shot. Wires every restricted selector to its role (using internal setters, so the bootstrap is instant) and sets the router's `ADMIN_DELAY`. The `routerConfigured` flag guarantees it can never be re-run to re-gate around the delay; all later policy changes go through the standard delayed `AccessManager` interface.
4. **Governance handoff (optional but required for production).** If `GOV_ADMIN` is set, it receives `ADMIN_ROLE` with `ADMIN_EXEC_DELAY` (default 7 days), and with `RENOUNCE_BOOTSTRAP=true` the bootstrap admin renounces. **Until renounced, the bootstrap admin remains a delay-0 master key** — it can call anything instantly. Hand off and renounce as soon as the deployment is verified.

## Quick reference

| You want to… | Role you need | How |
|---|---|---|
| Halt swaps now | `GUARDIAN_ROLE` | `router.pause()` directly |
| Resume swaps | `RESUMER_ROLE` | schedule on manager → wait 2 h → execute |
| Add/remove a venue | `LISTING_ROLE` | schedule → wait 1 day → execute |
| Change fallback router/quoter/fees, per-pair fees | `UPGRADER_ROLE` | schedule → wait 7 days → execute |
| Rescue stuck tokens | `UPGRADER_ROLE` | schedule → wait 7 days → execute |
| Upgrade the implementation | `UPGRADER_ROLE` | `Upgrade.s.sol` → wait 7 days → `Execute.s.sol` (same account) |
| Cancel a pending operation | the scheduler or `ADMIN_ROLE` | `manager.cancel(caller, target, data)` |
| Grant/revoke roles, rewire selectors | `ADMIN_ROLE` | through the manager, subject to your own execution delay and the router's `ADMIN_DELAY` |

And the invariants worth keeping in mind:

- Schedule and execute **must come from the same account**, with **identical calldata**.
- A scheduled operation is executable from `when` until `when + 1 week`, then it expires.
- Watch `OperationScheduled` on the manager — every delayed admin action is publicly queued there before it can take effect.
- Delay *decreases* (role delays via re-grant, target admin delays) phase in; they never apply instantly.
