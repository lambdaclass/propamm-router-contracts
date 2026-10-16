# Changelog

All notable changes to the TypeScript SDK (`propamm`) are documented here.

## [Unreleased]

### Fixed

- A v2 price rung whose amounts don't fit a uint256 is dropped instead of being
  returned. So is a rung whose input rounds to zero base units, which read as a
  free fill.

## [1.8.0] - 2026-10-16

### Changed

- **Titan's v2 pAMM feeds are the default.** Titan deprecated
  `/ws/pamm_quote_stream` and `/ws/pamm_price_levels` (they may stop after
  2026-10-23). `OverridesWsSource` now defaults to
  `wss://eu.data.titanbuilder.xyz/ws/pamm_quote_stream_v2` and `PriceLevelsWsSource` to
  `wss://eu.data.titanbuilder.xyz/ws/pamm_price_levels_v2`; `OverridesRpcSource` calls
  `titan_getPammVenues` and `PriceLevelsRpcSource` calls `titan_getPammBooks` instead of
  the undocumented `titan_getPammStateOverrides` / `titan_getPammPriceLevels`.
  The default JSON-RPC URL is now `https://eu.data.titanbuilder.xyz/data`, the
  path Titan documents. Both parsers still accept the v1 payloads.
- **v2 price levels are rebuilt into the same base-unit order books.** The v2
  feed sends one book per maker and pair with float `price`/`cumVolume` bids
  and asks; each side becomes a `token_in -> token_out` order book of base-unit
  amounts, as before. Titan's floats can leave an amount a few base units off
  the exact simulated value. Books are filed under the router venue address
  (`QUOTE_ADDRESS_VENUES` in `common/pamms` maps Kipseli's and Metric's
  publishing addresses), and a book quoting a token without known decimals is
  skipped.
- `PriceLevel.variant` is now optional (`variant?`): the v2 feed doesn't say whether a rung was simulated or
  interpolated, so it is only set for v1 payloads.
- `toStateOverride`'s `pamms` option now also matches an entry whose priced addresses or mapped router
  venue include the listed address, so `METRIC` selects both of Metric's
  entries and `KIPSELI` selects Kipseli's.

### Added

- `TOKEN_DECIMALS` in `common/tokens`: decimals of the tokens Titan's price
  levels quote today, read from each token's `decimals()`.
- `decimals` and `ethRpcUrl` options on `PriceLevels`, `PriceLevelsRpcSource` and `PriceLevelsWsSource`: extra decimals, and an Ethereum RPC URL to read the
  `decimals()` of any other token once and cache it.
- `OverridesSnapshot.pricedAddresses`: the addresses priced from each entry, from the v2 payload.
- `parsePriceLevelsMessage` takes an optional decimals table.
- `QUOTE_ADDRESS_VENUES` in `common/pamms`.

## [1.7.0] - 2026-10-15

### Added

- `GOLIATH` venue constant in `common/pamms`, plus its `goliath` entry in
  `PAMMS` (and therefore in the `PammName` union).

### Changed

- **`METRIC` now points at `0x99Ab7c1C5eab47801F7937075998527a550fbA8a`**,
  Metric's new adapter over its own pool factory, whitelisted on 2026-10-15.
  The previous address is no longer whitelisted on the router, so naming it in
  `venues` selected nothing. Code that hardcoded the old address must be
  updated.

## [1.6.0] - 2026-10-08

### Added

- `STELAXIS` venue constant in `common/pamms`, plus its `stelaxis` entry in
  `PAMMS` (and therefore in the `PammName` union).

### Changed

- **`BEBOP` now points at `0xB09AAA8933626d7E4C48D65dAd2D77021CFBCA9a`** and
  **`TAURUSFI` at `0x3ce2672Aa806138585920421406Bf0dEcB8130Cb`**, the current
  deployments. The previous addresses are no longer whitelisted on the router,
  so naming them in `venues` selected nothing. Code that hardcoded either old
  address must be updated.
- The Bebop default slot that `toStateOverride` zeroes now lands on the new
  `BEBOP` address, which is the key Titan serves Bebop's overrides under.

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
