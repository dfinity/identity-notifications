# Changelog

## Next

* An app's own service worker can now read a notification's content and
  report it received and opened, as the recipient. `@icp-sdk/auth` calls these
  endpoints as the signed-in user, without Internet Identity's caller info,
  where an installed web app delivers its own notifications. Every other caller
  is still refused.
* Breaking change: `Misconfigured` has a new variant, `NotListedFrontend`, so
  a `match` over it that names every variant needs one more.
* A frontend that signs in with a `derivationOrigin`, such as one frontend of a
  suite, can now send notifications to the users of the application at that
  origin. Set the optional `notification_derivation_origin` variable to it: a
  send names it as the application the notifications are for, and a pull is
  answered when Internet Identity's caller info names it, since that is the
  origin it mints the pull for. Unset, nothing changes. An application that does
  not list the frontend among its alternative origins is reported as
  `NotListedFrontend` under `misconfigured`, and its notifications wait in the
  outbox, as they do for an unlisted sender.
* A batch refused for an unlisted sender or an unlisted frontend is tried
  again a minute later, instead of at the next two-second flush, and still
  without spending the notification's second attempt. Only the application's
  operator can fix either, so the calls in between spent cycles on the same
  answer.
* `misconfigured` is cleared once Internet Identity accepts a batch, so
  `metrics()` stops reporting a misconfiguration the operator has fixed.

## 0.1.2

* A receipt, and a drop after Internet Identity was unreachable twice, count
  in the hour the notification was sent and in its funnel, like every other
  step. Funnels report `received`, and an hour no longer shows more received
  than accepted.
* Security fix: the three endpoints Internet Identity calls now check the
  account its signed caller info names against the notification's recipient.
  Internet Identity gives each consenting browser a pull delegation for its own
  account, so until now any user of an app could read, receipt and open every
  other user's notifications from that app. An id is derived from the recipient
  and the key, so naming someone else's notification took no guessing.
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
