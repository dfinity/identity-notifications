# Changelog

## Next

## 0.3.0

* Breaking change: depends on `core` 2.6.2, so an app resolves `core` 2.6.2 or
  later. 0.2.0 did not compile against `core` 2.6, which Mops picks for the
  library when the app depends on it: `field fromBlob does not exist in type
  Blob`.
* Uses `core`'s `toX` conversions in place of the `fromX` ones it deprecates,
  so the library compiles without warnings against `core` 2.6.2.

## 0.2.0

* Breaking change: requires moc 2.0.0 or later.
  `_internet_identity_notification_content` is a query, which is how Internet
  Identity calls it, so content pulls now succeed: 0.1.0 declared it an update,
  and Internet Identity's query calls to it were rejected.
* The chat demo compiles again: its notification sets `funnel`.
* The library compiles without warnings on moc 2.0.0, so an app that includes
  it no longer sees its dot-notation suggestions.

## 0.1.0

* First release. `send` notifies Internet Identity users from a Motoko canister;
  the library assigns notification ids, batches and retries delivery, serves
  the content Internet Identity pulls back, and keeps delivery metrics.
