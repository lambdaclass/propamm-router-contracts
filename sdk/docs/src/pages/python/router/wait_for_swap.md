# wait_for_swap

Wait until a swap transaction is mined and decode its outcome from the
router's swap event (`Swapped`, `SwappedViaVenue` or `SwappedViaSelectedVenues`,
by entrypoint) and, when present, `FrontendFeeCharged`.

```python
async def wait_for_swap(self, tx_hash: str) -> SwapResult
```

## Usage

```python
tx_hash = await router.swap(params)
await router.wait_for_swap(tx_hash)
```

## Returns

[`SwapResult`](/python/types#swapresult)

The decoded swap outcome.

Raises if the transaction reverted or emitted no swap event.

## Parameters

### tx_hash

- **Type:** `str`

Hash returned by any swap method.
