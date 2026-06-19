# Helpers

Utilities from `propamm.common.helpers`, plus the token/venue constants
and account builders.

## apply_slippage

```python
def apply_slippage(amount: int, bps: int) -> int
```

Shave basis points off an amount — derive `amount_out_min` from a quote.

```python
from propamm.common.helpers import apply_slippage

min_out = apply_slippage(amount_out, 50)  # quote - 0.5%
```

**Parameters:** `amount: int`, `bps: int` (integer in `[0, 10000]`; raises
`InvalidInputError` otherwise).
**Returns** `int` — `amount - amount * bps // 10000`.

## deadline_in

```python
def deadline_in(seconds: int) -> int
```

Unix-timestamp deadline some seconds from now, for swap `deadline` params.

```python
from propamm.common.helpers import deadline_in

deadline = deadline_in(300)  # now + 5 min
```

**Parameters:** `seconds: int`. **Returns** `int`.

## parse_ether / parse_units / format_ether / format_units

```python
def parse_ether(value: str) -> int
def parse_units(value: str, decimals: int) -> int
def format_ether(value: int) -> str
def format_units(value: int, decimals: int) -> str
```

Decimal/atomic-unit conversion.

```python
from propamm.common.helpers import format_units, parse_units

parse_units("1.5", 6)      # 1500000
format_units(1500000, 6)   # "1.5"
```

## parse_address

```python
def parse_address(value: str) -> str
```

Parse a 0x-prefixed (or bare) 20-byte hex string into a checksummed address;
raises `InvalidInputError` on bad length or hex.

## Constants

| Module | Exports |
|---|---|
| `common/tokens` | `ETH_SENTINEL` (signals native ETH), `USDC`, `USDT`, `WETH` |
| `common/pamms` | `FERMI`, `BEBOP`, `KIPSELI`, `PAMMS` (name → address) |
| `common/accounts` | `account_from_key`, `account_from_mnemonic` |
