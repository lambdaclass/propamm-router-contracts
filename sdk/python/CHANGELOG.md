# Changelog

All notable changes to the Python SDK (`propamm`) are documented here.

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
