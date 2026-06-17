# Views

Read-only router state. All views work on read-only clients.

## fallback_swap_router

```python
async def fallback_swap_router(self) -> str
```

The Uniswap fallback "venue" address — dynamic router configuration, which is
why it isn't in the static `PAMMS` mapping.

```python
fallback = await router.fallback_swap_router()
```

**Returns** `str`

## fallback_quoter

```python
async def fallback_quoter(self) -> str
```

The quoter contract used to price the fallback route.

**Returns** `str`

## fallback_fee

```python
async def fallback_fee(self) -> int
```

The global fallback fee tier, in hundredths of a bip (e.g. `3000` = 0.30%).

**Returns** `int`

## get_pair_fee

```python
async def get_pair_fee(self, token_a: str, token_b: str) -> int
```

The raw per-pair fee tier override — `0` means unset. Order-independent:
`get_pair_fee(a, b) == get_pair_fee(b, a)`.

```python
await router.get_pair_fee(USDC, WETH)
```

**Returns** `int`

## resolved_fee

```python
async def resolved_fee(self, token_in: str, token_out: str) -> int
```

The effective Uniswap V3 tier for a pair: the per-pair override if set,
otherwise the global `fallback_fee`.

**Returns** `int`

## is_whitelisted_venue

```python
async def is_whitelisted_venue(self, venue: str) -> bool
```

Whether an address is a whitelisted pAMM. The Uniswap fallback is usable as a
venue without being whitelisted, so this returns `False` for it.

**Returns** `bool`

## get_whitelisted_venues

```python
async def get_whitelisted_venues(self) -> list[str]
```

Every whitelisted pAMM venue (excludes the Uniswap fallback). Order is not
guaranteed.

```python
venues = await router.get_whitelisted_venues()
```

**Returns** `list[str]`

## paused

```python
async def paused(self) -> bool
```

Whether swaps are paused. Quote functions remain callable while paused.

**Returns** `bool`
