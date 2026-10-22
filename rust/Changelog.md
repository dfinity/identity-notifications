# Changelog

## Next

## 0.1.1

* The README links the Motoko package instead of documents that are no longer
  in the repository.

## 0.1.0

* First release. `send` notifies Internet Identity users from a Rust canister;
  the library assigns notification ids, batches and retries delivery, serves
  the content Internet Identity pulls back as a query, and keeps delivery
  metrics in stable memory. Requires `ic-cdk` 0.20.1 or later.
