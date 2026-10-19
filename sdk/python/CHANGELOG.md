# Changelog

All notable changes to the Python SDK (`propamm`) are documented here.

## [1.7.1] - 2026-10-19

### Changed

- `decimals` values on `PriceLevels`, `PriceLevelsRpcSource` and
  `PriceLevelsWsSource` must be integers from 0 to 255; anything else raises
  `PricesError` when the source is built. A book whose decimals in the table
  passed to `parse_price_levels_message` aren't valid is skipped.

### Removed

- **The `eth_rpc_url` keyword argument** on `PriceLevels`,
  `PriceLevelsRpcSource` and `PriceLevelsWsSource`. A single failed
  `decimals()` read skipped that token's books for the source's lifetime, and
  timeouts escaped as raw exceptions. Pass the decimals of tokens missing from
  `TOKEN_DECIMALS` with `decimals` instead; code that passed `eth_rpc_url` must
  drop it.

### Fixed

- A v2 price rung whose amounts don't fit a uint256 is dropped, instead of
  raising `decimal.InvalidOperation` (past 100 digits) or being returned. So is
  a rung whose input rounds to zero base units, which read as a free fill.

## [1.7.0] - 2026-10-16

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
  (`QUOTE_ADDRESS_VENUES` in `common.pamms` maps Kipseli's and Metric's
  publishing addresses), and a book quoting a token without known decimals is
  skipped.
- `PriceLevel.variant` is now `PriceVariant | None` (default `None`): the v2 feed doesn't say whether a rung was simulated or
  interpolated, so it is only set for v1 payloads.
- `to_state_override`'s `pamms` argument now also matches an entry whose priced addresses or mapped router
  venue include the listed address, so `METRIC` selects both of Metric's
  entries and `KIPSELI` selects Kipseli's.

### Added

- `TOKEN_DECIMALS` in `common.tokens`: decimals of the tokens Titan's price
  levels quote today, read from each token's `decimals()`.
- `decimals` and `eth_rpc_url` keyword arguments on `PriceLevels`, `PriceLevelsRpcSource` and `PriceLevelsWsSource`: extra decimals, and an Ethereum RPC URL to read the
  `decimals()` of any other token once and cache it.
- `OverridesSnapshot.priced_addresses`: the addresses priced from each entry, from the v2 payload.
- `parse_price_levels_message` takes an optional decimals table.
- `QUOTE_ADDRESS_VENUES` in `common.pamms`.

## [1.6.0] - 2026-10-15

### Added

- `GOLIATH` venue constant in `common.pamms`, plus its `goliath` entry in
  `PAMMS`.

### Changed

- **`METRIC` now points at `0x99Ab7c1C5eab47801F7937075998527a550fbA8a`**,
  Metric's new adapter over its own pool factory, whitelisted on 2026-10-15.
  The previous address is no longer whitelisted on the router, so naming it in
  `venues` selected nothing. Code that hardcoded the old address must be
  updated.

## [1.5.0] - 2026-10-08

### Added

- `STELAXIS` venue constant in `common.pamms`, plus its `stelaxis` entry in
  `PAMMS`.

### Changed

- **`BEBOP` now points at `0xB09AAA8933626d7E4C48D65dAd2D77021CFBCA9a`** and
  **`TAURUSFI` at `0x3ce2672Aa806138585920421406Bf0dEcB8130Cb`**, the current
  deployments. The previous addresses are no longer whitelisted on the router,
  so naming them in `venues` selected nothing. Code that hardcoded either old
  address must be updated.
- The Bebop default slot that `to_state_override` zeroes now lands on the new
  `BEBOP` address, which is the key Titan serves Bebop's overrides under.

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

- `EL_ZORRO` venue constant in `common.pamms`, plus its `elzorro` entry in
  `PAMMS`.

### Removed

- `TokenOutBalanceDecreased` from the bundled router ABI. The router stopped
  reverting with it when the bespoke Bebop adapter was removed, so it is no
  longer part of the compiled ABI and no longer decodes from a revert.
  ([#67](https://github.com/lambdaclass/propamm-router-contracts/pull/67))

## [1.2.0] - 2026-08-28

### Added

- `TEMPEST`, `TAURUSFI` and `METRIC` venue constants in `common.pamms`, plus
  their `tempest` / `taurusfi` / `metric` entries in `PAMMS`.

### Changed

- **`BEBOP` now points at `0xB09AaA5614916d7AEb59C295C52c92ca82aDdD76`**, the
  current Bebop deployment. Code that hardcoded the previous Bebop address must
  be updated.

### Removed

- `_LEGACY_BEBOP_LOWER` and the legacy-Bebop handling in `to_state_override`.
  The superseded Bebop deployments are no longer whitelisted on the router, so
  they can be neither quoted nor dispatched and need no price neutralization;
  `bebop_default` now zeroes only the current `BEBOP` slot when a snapshot
  omits it.

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
