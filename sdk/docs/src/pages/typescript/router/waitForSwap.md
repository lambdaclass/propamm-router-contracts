# waitForSwap

Wait until a swap transaction is mined and decode its outcome from the
router's swap event (`Swapped`, `SwappedViaVenue` or `SwappedViaSelectedVenues`,
by entrypoint) and, when present, `FrontendFeeCharged`.

```ts
waitForSwap(hash: Hash): Promise<SwapResult>
```

## Usage

```ts
const hash = await router.swap(params);
await router.waitForSwap(hash);
```

## Returns

[`SwapResult`](/typescript/types#swapresult)

The decoded swap outcome.

Throws if the transaction reverted or emitted no swap event.

## Parameters

### hash

- **Type:** `Hash`

Hash returned by any swap method.
