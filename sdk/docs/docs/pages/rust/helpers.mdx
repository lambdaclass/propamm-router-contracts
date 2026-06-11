# Helpers

Utilities from `common::helpers`, plus the token/venue constants.

## apply_slippage

```rust
pub fn apply_slippage(amount: U256, bps: u32) -> Result<U256>
```

Shave basis points off an amount — derive `amount_out_min` from a quote.

```rust
use propamm_sdk::common::helpers::apply_slippage;

let min_out = apply_slippage(quote.amount_out, 50)?; // quote - 0.5%
```

**Parameters:** `amount: U256`, `bps: u32` (at most `10000`; fails with
`Error::InvalidInput` otherwise).
**Returns** `Result<U256>` — `amount - amount * bps / 10000`.

## deadline_in

```rust
pub fn deadline_in(seconds: u64) -> U256
```

Unix-timestamp deadline some seconds from now, for swap `deadline` params.

```rust
use propamm_sdk::common::helpers::deadline_in;

let deadline = deadline_in(300); // now + 5 min
```

**Parameters:** `seconds: u64`. **Returns** `U256`.

## parse_address

```rust
pub fn parse_address(s: &str) -> Result<Address>
```

Parse a 0x-prefixed (or bare) 20-byte hex address.

```rust
use propamm_sdk::common::helpers::parse_address;

let router_address = parse_address("0x4DdF368080CD7946db5b459aD591c350158175e1")?;
```

**Returns** `Result<Address>`.

## parse_units / format_units / parse_ether / format_ether

```rust
pub fn parse_units(amount: &str, decimals: u32) -> Result<U256>
pub fn format_units(value: U256, decimals: u32) -> String
pub fn parse_ether(amount: &str) -> Result<U256>
pub fn format_ether(value: U256) -> String
```

Decimal ↔ atomic-unit conversion; the `ether` variants fix `decimals = 18`.
Parsing fails on malformed numbers, more fractional digits than `decimals`,
or uint256 overflow. Formatting trims trailing zeros.

```rust
use propamm_sdk::common::helpers::{format_units, parse_units};

parse_units("1.5", 6)?;            // 1500000
format_units(1500000.into(), 6);   // "1.5"
```

## Constants

| Module | Exports |
|---|---|
| `common::tokens` | `ETH_SENTINEL` (signals native ETH), `USDC`, `USDT`, `WETH` |
| `common::pamms` | `FERMI`, `BEBOP`, `KIPSELI`, `PAMMS` (name → address array) |
