# Changelog

## Next

* `dismiss` no longer drops a notification Internet Identity already took or
  is taking. Its content stays until it expires, marked by the new `dismissed`
  field of `Types.Content`, so a device woken for it pulls it and leaves it
  alone instead of showing a stand-in. `_internet_identity_notification_content`
  answers a dismissed notification only to the recipient calling as
  themselves, as the app's own service worker does, and Internet Identity finds
  none. One still waiting in the outbox leaves it as before, and one dismissed
  while it waits for a second attempt is never sent and not counted as
  dropped. Sending again under its key makes it live again. An upgrade from an
  earlier version carries content over as not dismissed.
* A notification can carry `metadata`, app-defined text for the app's own
  service worker, such as the id of the user who sent a message so it can draw
  their avatar. It is stored with the content and returned by
  `_internet_identity_notification_content` in the new `metadata` field of
  `Types.Content`, so only the recipient reads it, and Internet Identity never
  shows it. It counts toward `notification_capacity_mb` like the title, body
  and url. An upgrade from an earlier version carries the outbox over, its
  content without metadata.
* Breaking change: `Types.Notification` has a new field, `metadata`, and a
  Motoko record has no defaults, so every notification an app builds needs
  `metadata = null` where it sets none.
* An app's own service worker can now read a notification's content and
  report it received and opened, as the recipient. `@icp-sdk/auth` calls these
  endpoints as the signed-in user, without Internet Identity's caller info,
  where an installed web app delivers its own notifications. Every other caller
  is still refused.
* Breaking change: `Types.Misconfigured` has a new case, `#notListedFrontend`,
  so a `switch` over it that names every case needs one more.
* A frontend that signs in with a `derivationOrigin`, such as one frontend of a
  suite, can now send notifications to the users of the application at that
  origin. Set the optional `notification_derivation_origin` variable to it: a
  send names it as the application the notifications are for, and a pull is
  answered when Internet Identity's caller info names it, since that is the
  origin it mints the pull for. Unset, nothing changes. An application that does
  not list the frontend among its alternative origins is reported as
  `#notListedFrontend` under `misconfigured`, and its notifications wait in the
  outbox, as they do for an unlisted sender.
* A batch refused for an unlisted sender or an unlisted frontend is tried
  again a minute later, instead of at the next two-second flush, and still
  without spending the notification's second attempt. Only the application's
  operator can fix either, so the calls in between spent cycles on the same
  answer.
* `misconfigured` is cleared once Internet Identity accepts a batch, so
  `metrics()` stops reporting a misconfiguration the operator has fixed.

## 0.3.2

* Security fix: the three endpoints Internet Identity calls now check the
  account its signed caller info names against the notification's recipient.
  Internet Identity gives each consenting browser a pull delegation for its own
  account, so until now any user of an app could read, receipt and open every
  other user's notifications from that app. An id is derived from the recipient
  and the key, so naming someone else's notification took no guessing.
* A notification an app sets no `expiresAt` on is now kept for an hour instead
  of five minutes, matching Internet Identity's own default. The five minutes
  was the window Internet Identity has to post a wake-up, which is not how long
  the notification is worth showing: a browser that is woken later still finds
  the content to show. A deadline past the day Internet Identity keeps one for
  is cut to that.
* An upgraded canister reads its environment variables again, so a changed
  `notification_sender`, `notification_origin` or `notification_capacity_mb`
  takes effect on upgrade rather than keeping what the installing version read.

## 0.3.1

* The README links the Rust crate instead of documents that are no longer in
  the repository.

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
