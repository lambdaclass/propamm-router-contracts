# Changelog

All notable changes to the TypeScript SDK (`propamm`) are documented here.

## [1.2.0] - 2026-06-25

### Added

- Browser / injected wallet support: `ContractClient.fromClients` accepts
  prebuilt [viem](https://viem.sh) public and wallet clients (e.g. wagmi's
  `usePublicClient` / `useWalletClient`), so swaps can be signed by a browser
  wallet instead of a raw private key.
  ([#56](https://github.com/lambdaclass/propamm-router-contracts/pull/56))

## [1.1.0] - 2026-06-24

### Added

- Price levels: subscribe to maker price-level updates and apply them to quotes
  via `PriceLevelsWsSource` (WebSocket) or `PriceLevelsRpcSource` (RPC), plus
  the `PriceLevels` container and related utilities.
  ([#51](https://github.com/lambdaclass/propamm-router-contracts/pull/51))

## [1.0.0] - 2026-06-18

### Added

- Initial release. Core surface for interacting with the `PropAMMRouter`:
  - Router actions: `quote`, `swap`, `waitForSwap`, `approve`, `allowance`, and
    view helpers.
  - State overrides: apply fresh pAMM state to quotes via `OverridesWsSource`
    (WebSocket) or `OverridesRpcSource` (RPC), plus utilities.
  - Shared helpers and types.
