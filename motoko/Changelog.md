# Changelog

## Next

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
  [DESIGN.md](https://github.com/dfinity/identity-notifications/blob/main/DESIGN.md) is the design it follows.
