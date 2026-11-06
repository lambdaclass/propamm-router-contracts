# wait_for_swap

Wait until a swap transaction is mined and decode its outcome from the
router's swap event (`Swapped`, `SwappedViaVenue` or `SwappedViaSelectedVenues`,
by entrypoint) and, when present, `FrontendFeeCharged`.

```rust
pub async fn wait_for_swap(&self, hash: H256) -> Result<SwapResult>
```

## Usage

```rust
let hash = router.swap(&params).await?;
let result: SwapResult = router.wait_for_swap(hash).await?;
```

## Returns

[`Result<SwapResult>`](/rust/types#swapresult)

The decoded swap outcome.

Fails if the transaction reverted or emitted no swap event.

## Parameters

### hash

- **Type:** `H256`

Hash returned by any swap method.
