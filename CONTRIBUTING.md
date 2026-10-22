# Contributing to identity-notifications

Thank you for your interest in contributing ❤️

## Contributing code changes

If you want to contribute a feature or bug fix, please **reach out to us first** so we can discuss feasibility and implementation strategies. You can reach out to us:

* on the [forum](https://forum.dfinity.org/c/internet-identity/32), or
* during our monthly community calls — see [Identity & Authentication WG](https://forum.dfinity.org/t/working-group-identity-authentication/11902).

Make sure to read the [LICENSE](LICENSE) first.

External contributions are accepted under the DFINITY [CLA](https://github.com/dfinity/cla/blob/main/CLA.md). The org-wide CLA workflow will guide you through signing on your first PR.

## Development

```
cd motoko
mops install
mops test
npm install && npm run format:check

cd ../rust
cargo test
cargo clippy --all-targets -- -D warnings
cargo build --release --target wasm32-unknown-unknown -p chat-example
```

A PR that changes `motoko/src` or `rust/src` adds an entry under `## Next` in
that package's `Changelog.md`; CI checks for it. A change with nothing to tell
users, such as a refactor or a test, carries the `no-changelog` label instead.

The two libraries are meant to stay in step, so a change to how either behaves
belongs in both, along with the same test on each side.

`motoko/src/Internal/` and `rust/src/internal/` hold the parts worth testing on
their own — the lane queue, id derivation, the metrics ring, the outbox and the
flush decisions. Nothing in there calls the system API, so the unit tests run
without a replica; `motoko/test/Chat.test.mo` and `rust/tests/scenarios.rs`
drive the whole pipeline against a fake Internet Identity the same way.
