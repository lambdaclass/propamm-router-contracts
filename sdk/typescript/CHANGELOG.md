# Changelog

All notable changes to the TypeScript SDK (`propamm`) are documented here.

## [1.5.0] - 2026-09-16

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

## [1.4.0] - 2026-09-07

### Added

- `EL_ZORRO` venue constant in `common/pamms`, plus its `elzorro` entry in
  `PAMMS` (and therefore in the `PammName` union).

### Removed

- `TokenOutBalanceDecreased()` from `propAmmRouterAbi`. The router stopped
  reverting with it when the bespoke Bebop adapter was removed, so viem can no
  longer decode a revert into it.
  ([#67](https://github.com/lambdaclass/propamm-router-contracts/pull/67))

## [1.3.0] - 2026-08-28

### Added

- `TEMPEST`, `TAURUSFI` and `METRIC` venue constants in `common/pamms`, plus
  their `tempest` / `taurusfi` / `metric` entries in `PAMMS` (and therefore in
  the `PammName` union).

### Changed

- **`BEBOP` now points at `0xB09AaA5614916d7AEb59C295C52c92ca82aDdD76`**, the
  current Bebop deployment. Code that hardcoded the previous Bebop address must
  be updated.

## [1.2.2] - 2026-07-01

### Added

- The `swap` and `swapAndWait` functions now attach a hardcoded per-function gas limit and skip
  node gas estimation, which can under-shoot when execution takes a heavier
  branch than it simulated. Override the gas limit per call with the new
  `SwapOptions.gasLimit`.
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
