# Changelog

All notable changes to the TypeScript SDK (`propamm`) are documented here.

## [1.2.2] - 2026-07-01

### Added

- The `swap` and `swapAndWait` functions now attach a hardcoded per-function gas limit and skip
  node gas estimation, which can under-shoot when execution takes a heavier
  branch than it simulated. Override per call with the new `SwapOptions.gasLimit`.
- `PropAmmRouter.gasLimitFor(opts?)` returns the gas limit a swap will attach
  for the given options (the explicit `gasLimit`, else the per-function
  default) — for previewing the maximum network fee without sending.

## [1.2.1] - 2026-06-25

### Fixed

- State-override quotes now pin the simulated `block.timestamp` to the beacon
  slot's canonical block time (`genesis + slot*12`) instead of the frame's emit
  time, falling back to the emit time when no slot is present. Venues validate
  `block.timestamp` against the state they pushed, which is keyed to the slot.
  ([#61](https://github.com/lambdaclass/propamm-router-contracts/pull/61))

## [1.2.0] - 2026-06-25

### Added

- Browser / injected wallet support: `ContractClient.fromClients` accepts
  prebuilt [viem](https://viem.sh) public and wallet clients (e.g. wagmi's
  `usePublicClient` / `useWalletClient`), so swaps can be signed by a browser
  wallet instead of a raw private key.
  ([#56](https://github.com/lambdaclass/propamm-router-contracts/pull/56))

### Changed

- **Breaking:** the `ContractClient` constructor is now private. Build a client
  from an RPC URL with the new `ContractClient.fromRpc` static method instead of
  `new ContractClient(...)`.
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
