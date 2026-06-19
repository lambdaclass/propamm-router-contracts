# Installation

The Rust SDK is the `propamm-sdk` crate, built entirely on
[rex](https://github.com/lambdaclass/rex) /
[ethrex](https://github.com/lambdaclass/ethrex): `EthClient` transport,
signing, `eth_call` overrides, and ABI encoding/decoding via ethrex's
calldata codec.

```sh
cargo add propamm-sdk --git https://github.com/lambdaclass/propamm-router-contracts
```

Or add it to `Cargo.toml`:

```toml
[dependencies]
propamm-sdk = { git = "https://github.com/lambdaclass/propamm-router-contracts" }
```

Cargo resolves the crate from the repo's `sdk/rust` directory automatically.
Pin to a `branch`, `tag`, or `rev` for a reproducible build.

The SDK is async — pair it with a [Tokio](https://tokio.rs) runtime.
