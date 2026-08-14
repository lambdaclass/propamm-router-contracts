# Changelog

All notable changes to the Python SDK (`propamm`) are documented here.

## [Unreleased]

### Added

- `TEMPEST`, `TAURUSFI` and `METRIC` venue constants in `common.pamms`, plus
  their `tempest` / `taurusfi` / `metric` entries in `PAMMS`.

### Changed

- **`BEBOP` now points at `0xB09AaA5614916d7AEb59C295C52c92ca82aDdD76`**, the
  current Bebop deployment. Code that hardcoded the previous address
  (`0xdB13ad0fcD134E9c48f2fDaEa8f6751a0F5349ca`) must be updated.
- `to_state_override`'s `bebop_default` now also neutralizes the superseded
  `0xdB13ad…` deployment, which joins `0x160141A…` in the legacy set, so a
  stale on-chain price from either can no longer win a quote it could never
  fill. `_LEGACY_BEBOP_LOWER` is now a tuple of addresses rather than a single
  string.

## [1.1.3] - 2026-07-01

### Added

- The `swap` and `swap_and_wait` functions now attach a hardcoded per-function gas limit and
  skip gas estimation, which can under-shoot when execution takes a heavier
  branch than it simulated. Override the gas limit per call with the new
  `SwapOptions.gas_limit`.

## [1.1.2] - 2026-06-25

### Fixed

- State-override quotes now pin the simulated `block.timestamp` to the beacon
  slot's canonical block time (`genesis + slot*12`) instead of the frame's emit
  time, falling back to the emit time when no slot is present. Venues validate
  `block.timestamp` against the state they pushed, which is keyed to the slot.
  ([#63](https://github.com/lambdaclass/propamm-router-contracts/pull/63))

## [1.1.1] - 2026-06-24

### Added

- Price levels: subscribe to maker price-level updates and apply them to quotes
  via `PriceLevelsWsSource` (WebSocket) or `PriceLevelsRpcSource` (RPC), plus
  the `PriceLevels` container and related utilities.
  ([#53](https://github.com/lambdaclass/propamm-router-contracts/pull/53))
- Optional RPC URL argument on the client constructor.
  ([#53](https://github.com/lambdaclass/propamm-router-contracts/pull/53))

## [1.0.0] - 2026-06-19

### Added

- Initial release. Core surface for interacting with the `PropAMMRouter`:
  - Router actions: `quote`, `swap`, `wait_for_swap`, `approve`, `allowance`,
    and view helpers.
  - State overrides: apply fresh pAMM state to quotes via `OverridesWsSource`
    (WebSocket) or `OverridesRpcSource` (RPC), plus utilities.
  - Shared helpers and types.
