# Contributing to rust-identity-notifications

Thank you for your interest in contributing ❤️

## Contributing code changes

If you want to contribute a feature or bug fix, please **reach out to us first** so we can discuss feasibility and implementation strategies. You can reach out to us:

* on the [forum](https://forum.dfinity.org/c/internet-identity/32), or
* during our monthly community calls — see [Identity & Authentication WG](https://forum.dfinity.org/t/working-group-identity-authentication/11902).

Make sure to read the [LICENSE](LICENSE) first.

External contributions are accepted under the DFINITY [CLA](https://github.com/dfinity/cla/blob/main/CLA.md). The org-wide CLA workflow will guide you through signing on your first PR.

## Development

```
cargo test
cargo clippy --all-targets -- -D warnings
cargo build --release --target wasm32-unknown-unknown -p chat-example
```

`src/internal/` holds the parts worth testing on their own — the lane queue, id
derivation, the metrics ring, the outbox and the flush decisions. Nothing in
there calls the system API, so `cargo test` runs it without a replica;
`tests/scenarios.rs` drives the whole pipeline against a fake Internet Identity
the same way.
