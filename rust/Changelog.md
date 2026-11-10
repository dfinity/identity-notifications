# Changelog

## Next

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

## 0.1.1

* The README links the Motoko package instead of documents that are no longer
  in the repository.

## 0.1.0

* First release. `send` notifies Internet Identity users from a Rust canister;
  the library assigns notification ids, batches and retries delivery, serves
  the content Internet Identity pulls back as a query, and keeps delivery
  metrics in stable memory. Requires `ic-cdk` 0.20.1 or later.
