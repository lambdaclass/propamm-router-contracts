# Running an admin operation through the Safe and AccessManager

The admin roles on `PropAMMRouter` (UPGRADER, GUARDIAN, RESUMER, LISTING, ADMIN)
are held by Safe multisigs. To run any admin operation you go through two layers:

```
Safe owners sign  ->  Safe sends tx  ->  AccessManager  ->  Router
```

For the roles and delays themselves, see [`access-manager.md`](./access-manager.md).
This doc is just the steps.

## What you need to know first

The AccessManager identifies a scheduled operation by `(caller, target, data)`:

- `caller` is whoever calls the manager. When the Safe sends the transaction, the
  caller is the **Safe address**, not the owner who clicked execute.
- `target` is the contract being called (the router proxy).
- `data` is the calldata of the function you want to run.

Two results follow:

1. Schedule and execute must both be sent from the same Safe.
2. The `data` must be exactly the same bytes in both steps. Different arguments =
   different operation = the execute step finds nothing and reverts.

A pause is one Safe transaction. Everything else is two: schedule, wait the delay,
then execute.

## Instant: pause

GUARDIAN has no delay, so pause is a single Safe transaction to the router.

```
To:     <router proxy>
Value:  0
Method: pause()
```

Sign to threshold, execute. It takes effect immediately. Unpause does not work
this way — it is on RESUMER with a 1-day delay, so it uses the steps below.

## Delayed: everything else

Example used below: `addVenue(<venue>)`, on LISTING, 1-day delay. Swap in your
own function, role, and delay.

### 1. Build the calldata

This is the call you want the router to run. Build it once and reuse the same
bytes in both steps.

```bash
cast calldata "addVenue(address)" $VENUE
# 0x...   <- this is DATA
```

### 2. Schedule

Safe transaction to the AccessManager:

```
To:     <access manager>
Value:  0
Method: schedule(address target, bytes data, uint48 when)
        target = <router proxy>
        data   = DATA
        when   = 0      # 0 means earliest allowed: now + the role's delay
```

Sign to threshold, execute. The operation is now queued under the Safe.

Check when it can be run (read-only, no Safe needed):

```bash
# operation id:
cast call $ACCESS_MANAGER "hashOperation(address,address,bytes)" $SAFE $ROUTER_PROXY $DATA
# unix timestamp it becomes executable:
cast call $ACCESS_MANAGER "getSchedule(bytes32)" $OPERATION_ID
```

### 3. Wait the delay

Wait until `getSchedule(...)` time. The operation is then executable until that
time + 1 week. After that it expires and you have to schedule again.

### 4. Execute

Safe transaction, pick either form:

```
# a) through the manager, same target and data:
To:     <access manager>
Method: execute(address target, bytes data)
        target = <router proxy>
        data   = DATA

# b) directly on the router:
To:     <router proxy>
Method: addVenue(address)
        <venue>
```

Sign to threshold, execute. The operation runs and is consumed.

## Cancel a pending operation

Also a Safe transaction. Sender must be the Safe that scheduled it (or an ADMIN
holder).

```
To:     <access manager>
Method: cancel(address caller, address target, bytes data)
        caller = <the scheduling Safe>
        target = <router proxy>
        data   = DATA
```

## Upgrades

Same two-step flow. The calldata is `upgradeToAndCall(newImpl, "")`, on UPGRADER,
7-day delay.

`scripts/Upgrade.s.sol` broadcasts from an EOA, so it cannot drive the Safe. Use
it only to deploy and validate the new implementation and to print `newImpl` and
the exact `EXEC_DATA`. Then:

1. Schedule (step 2 above) in the Safe with `target = proxy`, `data = EXEC_DATA`.
2. After 7 days, execute (step 4) in the same Safe with the same `EXEC_DATA`, or
   call `upgradeToAndCall(newImpl, "")` on the proxy directly.

Do not let `Upgrade.s.sol` send the `schedule` itself when the role is on the
Safe — the EOA is not a role holder.

## Common errors

- Executing before the delay: reverts. Wait.
- Executing after 1 week past ready: expired, reverts. Schedule again.
- Different `target` or `data` between schedule and execute: no matching
  operation, reverts. Reuse the exact bytes.
- Scheduling the same operation twice while one is pending: reverts. Cancel or
  wait for expiry.

## Per-operation table

| Operation | Role | Delay | Steps |
|---|---|---|---|
| `pause` | GUARDIAN | 0 | one Safe tx to the router |
| `unpause` | RESUMER | 1 day | schedule, wait, execute |
| `addVenue`, `removeVenue` | LISTING | 1 day | schedule, wait, execute |
| `setFallbackSwapRouter`, `setFallbackQuoter`, `setFallbackFee`, `setPairFee`, `setPairFees`, `rescueTokens` | UPGRADER | 7 days | schedule, wait, execute |
| `upgradeToAndCall` | UPGRADER | 7 days | schedule, wait, execute (see Upgrades) |
| `grantRole`, `revokeRole`, `setTargetFunctionRole`, ... | ADMIN | per-grant | schedule, wait, execute |
