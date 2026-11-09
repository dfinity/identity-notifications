# Changelog

## Next

* A notification an app sets no `expires_at` on is now kept for an hour instead
  of five minutes, matching Internet Identity's own default. The five minutes
  was the window Internet Identity has to post a wake-up, which is not how long
  the notification is worth showing: a browser that is woken later still finds
  the content to show. A deadline past the day Internet Identity keeps one for
  is cut to that.

## 0.1.1

* The README links the Motoko package instead of documents that are no longer
  in the repository.

## 0.1.0

* First release. `send` notifies Internet Identity users from a Rust canister;
  the library assigns notification ids, batches and retries delivery, serves
  the content Internet Identity pulls back as a query, and keeps delivery
  metrics in stable memory. Requires `ic-cdk` 0.20.1 or later.
