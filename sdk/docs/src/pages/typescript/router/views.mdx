# Views

Read-only router state. All views work on read-only clients.

## fallbackSwapRouter

```ts
fallbackSwapRouter(): Promise<Address>
```

The Uniswap fallback "venue" address — dynamic router configuration, which
is why it isn't in the static `PAMMS` mapping.

```ts
const fallback = await router.fallbackSwapRouter();
```

**Returns** `Address`

## fallbackQuoter

```ts
fallbackQuoter(): Promise<Address>
```

The quoter contract used to price the fallback route.

**Returns** `Address`

## fallbackFee

```ts
fallbackFee(): Promise<number>
```

The global fallback fee tier, in hundredths of a bip (e.g. `3000` = 0.30%).

**Returns** `number`

## getPairFee

```ts
getPairFee(tokenA: Address, tokenB: Address): Promise<number>
```

The raw per-pair fee tier override — `0` means unset. Order-independent:
`getPairFee(a, b) === getPairFee(b, a)`.

```ts
await router.getPairFee(USDC, WETH);
```

**Returns** `number`

## resolvedFee

```ts
resolvedFee(tokenIn: Address, tokenOut: Address): Promise<number>
```

The effective Uniswap V3 tier for a pair: the per-pair override if set,
otherwise the global `fallbackFee`.

**Returns** `number`

## isWhitelistedVenue

```ts
isWhitelistedVenue(venue: Address): Promise<boolean>
```

Whether an address is a whitelisted pAMM. The Uniswap fallback is usable as
a venue without being whitelisted, so this returns `false` for it.

**Returns** `boolean`

## getWhitelistedVenues

```ts
getWhitelistedVenues(): Promise<Address[]>
```

Every whitelisted pAMM venue (excludes the Uniswap fallback). Order is not
guaranteed.

```ts
const venues = await router.getWhitelistedVenues();
```

**Returns** `Address[]`

## paused

```ts
paused(): Promise<boolean>
```

Whether swaps are paused. Quote functions remain callable while paused.

**Returns** `boolean`
