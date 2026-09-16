# Changelog

All notable changes to the Rust SDK (`propamm`) are documented here.

## [1.4.0] - 2026-09-16

### Changed

- **Titan moved the state-override and price-level endpoints to dedicated
  infrastructure.** Every default now points at `eu.data.titanbuilder.xyz`
  instead of `rpc.titanbuilder.xyz`:
  - `DEFAULT_OVERRIDES_RPC_URL` — `https://eu.data.titanbuilder.xyz`
  - `DEFAULT_OVERRIDES_WS_URL` — `wss://eu.data.titanbuilder.xyz/ws/pamm_quote_stream`
  - `DEFAULT_PRICE_LEVELS_RPC_URL` — `https://eu.data.titanbuilder.xyz`
  - `DEFAULT_PRICE_LEVELS_WS_URL` — `wss://eu.data.titanbuilder.xyz/ws/pamm_price_levels`

  Titan serves the same data from `eu.`, `ap.` and `us.` hosts; the old `rpc.`
  hosts still respond but are deprecated. Callers that pass an explicit URL are
  unaffected — update it to the matching `*.data.titanbuilder.xyz` host. Callers
  on the defaults outside the EU should now set the URL explicitly, since the
  previous non-regional default has no `data.` equivalent.

## [1.3.0] - 2026-09-07

### Added

- `EL_ZORRO` venue constant in `common::pamms`, plus its `elzorro` entry in
  `PAMMS` (whose length goes from 6 to 7).

### Removed

- `TokenOutBalanceDecreased()` from `ERROR_SIGNATURES`. The router stopped
  reverting with it when the bespoke Bebop adapter was removed, so the selector
  no longer decodes into a named error.
  ([#67](https://github.com/lambdaclass/propamm-router-contracts/pull/67))

## [1.2.0] - 2026-08-28

### Added

- `TEMPEST`, `TAURUSFI` and `METRIC` venue constants in `common::pamms`, plus
  their `tempest` / `taurusfi` / `metric` entries in `PAMMS` (whose length goes
  from 3 to 6).

### Changed

- **`BEBOP` now points at `0xB09AaA5614916d7AEb59C295C52c92ca82aDdD76`**, the
  current Bebop deployment. Code that hardcoded the previous Bebop address must
  be updated.

## [1.1.2] - 2026-07-01

### Added

- The `swap` and `swap_with` functions (and their `_and_wait` variants) now attach a hardcoded
  per-function gas limit and skip node gas estimation, which can under-shoot when
  execution takes a heavier branch than it simulated. Override the gas limit per
  call with the new `SwapOptions.gas_limit`.

## [1.1.1] - 2026-06-25

### Fixed

- State-override quotes now pin the simulated `block.timestamp` to the beacon
  slot's canonical block time (`genesis + slot*12`) instead of the frame's emit
  time, falling back to the emit time when no slot is present. Venues validate
  `block.timestamp` against the state they pushed, which is keyed to the slot.
  ([#62](https://github.com/lambdaclass/propamm-router-contracts/pull/62))

## [1.1.0] - 2026-06-24

### Added

- Price levels: subscribe to maker price-level updates and apply them to quotes
  via `PriceLevelsWsSource` (WebSocket) or `PriceLevelsRpcSource` (RPC), plus
  the `PriceLevels` container and related utilities.
  ([#52](https://github.com/lambdaclass/propamm-router-contracts/pull/52))

### Changed

- Updated `rex` / `ethrex` dependencies.
  ([#55](https://github.com/lambdaclass/propamm-router-contracts/pull/55))

## [1.0.0] - 2026-06-18

### Added

- Initial release. Core surface for interacting with the `PropAMMRouter`:
  - Router actions: `quote`, `swap`, `wait_for_swap`, `approve`, `allowance`,
    and view helpers.
  - State overrides: apply fresh pAMM state to quotes via `OverridesWsSource`
    (WebSocket) or `OverridesRpcSource` (RPC), plus utilities.
  - Shared helpers and types.
