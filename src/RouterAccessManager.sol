// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PropAMMRouter} from "./PropAMMRouter.sol";

/// @title RouterAccessManager
/// @notice Central authority governing every `restricted` administrative
/// entrypoint on `PropAMMRouter`, with the access policy codified here in the
/// contract rather than applied by a deployment script.
/// @dev The policy is `AccessManager` state (selector->role maps and per-role
/// execution delays), so it cannot be pure `immutable` data and is not held by
/// the router. What lives here instead is the policy *definition*: the role
/// catalog, the delays as constants, the grants in the constructor, and a single
/// one-shot {configureRouter} that wires the selectors. A deployer only has to
/// deploy this manager, deploy the router proxy under it, and call
/// {configureRouter} once — no per-selector wiring or delay values supplied
/// off-chain. `ADMIN_ROLE` (0) and `PUBLIC_ROLE` (2**64-1) are inherited.
contract RouterAccessManager is AccessManager {
    /// @notice Sensitive, slow-path actions: UUPS upgrades (`upgradeToAndCall`),
    /// fallback reconfiguration, and `rescueTokens`. Carries {UPGRADE_DELAY}.
    uint64 public constant UPGRADER_ROLE = 1;

    /// @notice Emergency role for `pause`. Granted with a *zero* execution delay
    /// so a security council can halt swaps instantly — pausing is fail-safe.
    uint64 public constant GUARDIAN_ROLE = 2;

    /// @notice Role for `unpause`. Distinct from {GUARDIAN_ROLE} because resuming
    /// is fail-open and should be deliberate, so it carries {RESUME_DELAY}.
    uint64 public constant RESUMER_ROLE = 3;

    /// @notice Operational role for the venue whitelist (`addVenue` /
    /// `removeVenue`). Separate from {UPGRADER_ROLE} so listing is run by a
    /// different account on a shorter, operations-paced delay ({LISTING_DELAY}).
    uint64 public constant LISTING_ROLE = 4;

    /// @notice Execution delay on {UPGRADER_ROLE}. Long, so queued upgrades and
    /// config changes are publicly visible before they take effect.
    uint32 public constant UPGRADE_DELAY = 7 days;

    /// @notice Execution delay on {RESUMER_ROLE}. Short but non-zero.
    uint32 public constant RESUME_DELAY = 1 days;

    /// @notice Execution delay on {LISTING_ROLE}. Shorter than {UPGRADE_DELAY}:
    /// listing is operational and lower blast-radius — a bad venue just reverts
    /// and the Uniswap fallback engages, so no funds are at risk.
    uint32 public constant LISTING_DELAY = 1 days;

    /// @notice Delay applied to *re-gating* the router (future external
    /// `setTargetFunctionRole` / `setTargetAdminDelay`) once configured.
    uint32 public constant ADMIN_DELAY = 7 days;

    /// @notice Set once {configureRouter} has wired a router. Guards against a
    /// second call re-gating instantly and thereby bypassing {ADMIN_DELAY}.
    bool public routerConfigured;

    /// @notice Thrown when {configureRouter} is called after a router is wired.
    error RouterAlreadyConfigured();
    /// @notice Thrown when a constructor address argument is zero.
    error ZeroAddress();

    /// @param initialAdmin Bootstrap holder of `ADMIN_ROLE`, active immediately
    /// with no delay. Used to run {configureRouter} and the governance handoff,
    /// then renounced — otherwise it lingers as a delay-free master key.
    /// @param upgrader Holder of {UPGRADER_ROLE}.
    /// @param guardian Holder of {GUARDIAN_ROLE} (instant pause).
    /// @param resumer Holder of {RESUMER_ROLE} (unpause).
    /// @param lister Holder of {LISTING_ROLE} (venue whitelist management).
    constructor(address initialAdmin, address upgrader, address guardian, address resumer, address lister)
        AccessManager(initialAdmin)
    {
        require(
            upgrader != address(0) && guardian != address(0) && resumer != address(0) && lister != address(0),
            ZeroAddress()
        );

        // Grants need no router address, so they are codified at deploy time.
        // `_grantRole(role, account, grantDelay, executionDelay)`: grantDelay 0
        // makes the membership active immediately; the execution delay is what
        // gates the holder's calls.
        _grantRole(UPGRADER_ROLE, upgrader, 0, UPGRADE_DELAY);
        _grantRole(GUARDIAN_ROLE, guardian, 0, 0); // 0 execution delay => instant circuit breaker
        _grantRole(RESUMER_ROLE, resumer, 0, RESUME_DELAY);
        _grantRole(LISTING_ROLE, lister, 0, LISTING_DELAY);

        // Labels are cosmetic (explorer/dashboard discoverability).
        emit RoleLabel(UPGRADER_ROLE, "UPGRADER");
        emit RoleLabel(GUARDIAN_ROLE, "GUARDIAN");
        emit RoleLabel(RESUMER_ROLE, "RESUMER");
        emit RoleLabel(LISTING_ROLE, "LISTING");
    }

    /// @notice Wires the router's admin selectors to roles and locks in the
    /// re-gating delay. Run ONCE by the bootstrap admin after the proxy exists
    /// (the selector maps are per-target, so the router address is required and
    /// only known post-deployment).
    /// @dev Uses the internal setters so this bootstrap is instant; the one-shot
    /// guard ensures it cannot later be reused to re-gate around {ADMIN_DELAY}.
    /// Subsequent policy changes go through the standard external (delayed)
    /// `AccessManager` interface. `onlyAuthorized` resolves to `ADMIN_ROLE` here
    /// (this selector is unmapped on the manager-as-target, so it defaults to
    /// admin).
    /// @param router The deployed `PropAMMRouter` proxy.
    function configureRouter(address router) external onlyAuthorized {
        if (routerConfigured) revert RouterAlreadyConfigured();
        if (router == address(0)) revert ZeroAddress();
        routerConfigured = true;

        // UPGRADER_ROLE: upgrades + fallback config (incl. per-pair fees) + rescue.
        _setTargetFunctionRole(router, UUPSUpgradeable.upgradeToAndCall.selector, UPGRADER_ROLE);
        _setTargetFunctionRole(router, PropAMMRouter.setFallbackQuoter.selector, UPGRADER_ROLE);
        _setTargetFunctionRole(router, PropAMMRouter.setFallbackFee.selector, UPGRADER_ROLE);
        _setTargetFunctionRole(router, PropAMMRouter.setPairFee.selector, UPGRADER_ROLE);
        _setTargetFunctionRole(router, PropAMMRouter.setPairFees.selector, UPGRADER_ROLE);
        _setTargetFunctionRole(router, PropAMMRouter.rescueTokens.selector, UPGRADER_ROLE);

        // GUARDIAN_ROLE: instant pause. RESUMER_ROLE: deliberate unpause.
        _setTargetFunctionRole(router, PropAMMRouter.pause.selector, GUARDIAN_ROLE);
        _setTargetFunctionRole(router, PropAMMRouter.unpause.selector, RESUMER_ROLE);

        // LISTING_ROLE: venue whitelist management (operations-paced).
        _setTargetFunctionRole(router, PropAMMRouter.addVenue.selector, LISTING_ROLE);
        _setTargetFunctionRole(router, PropAMMRouter.removeVenue.selector, LISTING_ROLE);

        // Future re-gating of the router now carries a delay (phases in after
        // minSetback(), 5 days, since it is an increase from 0).
        _setTargetAdminDelay(router, ADMIN_DELAY);
    }
}
