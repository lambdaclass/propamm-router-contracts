# Installation

The Rust SDK is the `propamm` crate, built entirely on
[rex](https://github.com/lambdaclass/rex) /
[ethrex](https://github.com/lambdaclass/ethrex): `EthClient` transport,
signing, `eth_call` overrides, and ABI encoding/decoding via ethrex's
calldata codec.

```sh
cargo add propamm
```

Or add it to `Cargo.toml`:

```toml
[dependencies]
propamm = "1.0"
```

The SDK is async — pair it with a [Tokio](https://tokio.rs) runtime.
