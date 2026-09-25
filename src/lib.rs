//! Notify Internet Identity users from a Rust canister.
//!
//! One call to send; the library owns the ids, the batching, the retries, the
//! content Internet Identity pulls back, and the delivery metrics.
//!
//! ```ignore
//! use identity_notifications as notifications;
//! use notifications::Notification;
//!
//! notifications::endpoints!();
//!
//! #[ic_cdk::update]
//! fn send_message(to: candid::Principal, text: String) {
//!     // ... store the message ...
//!     notifications::send(
//!         to,
//!         Notification::new("New message", text)
//!             .url("https://chat.example.com/chats")
//!             .key("chat-alice"),
//!     );
//! }
//! ```
//!
//! Configured by environment variables — `internet_identity`,
//! `notification_origin`, and optionally `notification_capacity_mb` — so
//! nothing about a deployment is compiled in.

pub mod internal;
pub mod types;

use candid::Principal;
use internal::config::{self, Config};
use internal::flush::{self, Outcome};
use internal::ii;
use internal::metrics::{Event, Pipeline};
pub use internal::outbox::Snapshot;
use internal::outbox::{Entry, Outbox};
use std::cell::RefCell;
use std::time::Duration;
pub use types::{
    Bucket, Content, Metrics, Misconfigured, MisconfiguredSince, Notification, NotificationId,
    SenderInfo, Urgency,
};

/// Long enough that a busy canister batches instead of calling per message,
/// short enough that nobody notices. Everything waits for it, urgency
/// included: urgency decides which lane drains first, not whether a call
/// happens now, and an app that marked everything urgent would otherwise lose
/// the batching altogether.
const COALESCE: Duration = Duration::from_secs(2);

/// What Internet Identity accepts in one call today. It corrects us with
/// `TooManyNotifications`, and we believe it from then on.
const BATCH_GUESS: usize = 1_000;

const DEFAULT_RETENTION: u64 = 86_400_000_000_000;

#[derive(Default)]
struct State {
    outbox: Outbox,
    pipeline: Pipeline,
    batch_limit: usize,
    misconfigured: Option<MisconfiguredSince>,
    flush_armed: bool,
    flushing: bool,
}

thread_local! {
    static STATE: RefCell<State> = RefCell::new(State {
        batch_limit: BATCH_GUESS,
        ..State::default()
    });
}

/// Sends a notification, or updates the one this recipient's `key` already
/// names.
///
/// Never traps and never awaits: a notification is an aside to whatever the
/// app was actually doing, so a failure here must not fail that. Everything
/// that goes wrong afterwards is absorbed by the library and visible in
/// [`metrics`].
pub fn send(recipient: Principal, notification: Notification) {
    let now = ic_cdk::api::time();

    let config = match configured() {
        Ok(config) => config,
        Err(why) => {
            note(why, now);
            STATE.with_borrow_mut(|state| state.pipeline.record(now, Event::Dropped, 1));
            return;
        }
    };

    let added = STATE.with_borrow_mut(|state| {
        state.outbox.add(
            recipient,
            notification,
            now + DEFAULT_RETENTION,
            config.capacity_bytes,
            now,
        )
    });

    match added {
        Some(_) => arm(),
        None => STATE.with_borrow_mut(|state| state.pipeline.record(now, Event::Dropped, 1)),
    }
}

/// This notification no longer needs anyone's attention. Its content goes, so
/// a pull finds nothing and a channel that sweeps can close it.
pub fn dismiss(recipient: Principal, key: &str) {
    STATE.with_borrow_mut(|state| state.outbox.dismiss(recipient, key));
}

/// The delivery pipeline, hour by hour, for whatever the app already uses to
/// watch itself.
pub fn metrics() -> Metrics {
    STATE.with_borrow(|state| Metrics {
        hours: state.pipeline.snapshot(),
        backlog: state.outbox.backlog() as u64,
        misconfigured: state.misconfigured,
    })
}

/// Answers Internet Identity's content pull. Call this from the endpoint
/// [`endpoints!`] generates, or from your own if you would rather name it.
pub fn notification_content(id: NotificationId) -> Option<Content> {
    sender_info()?;
    STATE.with_borrow(|state| state.outbox.content_of(id).cloned())
}

/// Records Internet Identity's receipt. Content stays until it expires: other
/// devices may still pull the same notification.
pub fn notification_received(id: NotificationId) {
    if sender_info().is_none() {
        return;
    }
    let now = ic_cdk::api::time();
    STATE.with_borrow_mut(|state| {
        state.outbox.mark_received(id);
        state.pipeline.record(now, Event::Received, 1);
    });
}

/// The two endpoints Internet Identity calls.
///
/// The content pull is a `query`: the replica serves caller info to queries, so
/// a channel with a user waiting does not pay for consensus to read a
/// notification's text. The receipt is an `update`, because it records
/// something.
#[macro_export]
macro_rules! endpoints {
    () => {
        // The type is imported rather than named in the signature, and
        // `ic_cdk` is left unqualified, because `ic_cdk::export_candid!`
        // re-parses these signatures and chokes on a leading `::` — which is
        // exactly what `$crate` expands to.
        use $crate::types::Content as IiNotificationContent;

        #[ic_cdk::query]
        fn _internet_identity_notification_content(id: u64) -> Option<IiNotificationContent> {
            $crate::notification_content(id)
        }

        #[ic_cdk::update]
        fn _internet_identity_notification_received(id: u64) {
            $crate::notification_received(id)
        }
    };
}

/// Everything the library holds, for an app to carry across an upgrade in its
/// own `pre_upgrade`/`post_upgrade`.
pub fn snapshot() -> Snapshot {
    STATE.with_borrow(|state| Snapshot {
        outbox: state.outbox.export(),
        pipeline: state.pipeline.clone(),
        batch_limit: state.batch_limit,
        misconfigured: state.misconfigured,
    })
}

/// Restores a [`snapshot`]. Anything not restored simply starts empty, which
/// costs pending notifications their content, so do restore it.
pub fn restore(snapshot: Snapshot) {
    STATE.with_borrow_mut(|state| {
        state.outbox = Outbox::import(snapshot.outbox);
        state.pipeline = snapshot.pipeline;
        state.batch_limit = snapshot.batch_limit;
        state.misconfigured = snapshot.misconfigured;
    });
    arm();
}

fn configured() -> Result<Config, Misconfigured> {
    config::read()
}

fn note(why: Misconfigured, now: u64) {
    STATE.with_borrow_mut(|state| {
        if state.misconfigured.map(|m| m.why) != Some(why) {
            state.misconfigured = Some(MisconfiguredSince { why, since: now });
        }
    });
}

/// Internet Identity signed this call's caller info, and it names our own
/// origin. Anything else is not ours to answer.
fn sender_info() -> Option<SenderInfo> {
    let config = configured().ok()?;
    if ic_cdk::api::msg_caller_info_signer()? != config.internet_identity {
        return None;
    }

    let info = internal::caller_info::decode(&ic_cdk::api::msg_caller_info_data())?;
    (info.origin == config.origin).then_some(info)
}

fn arm() {
    let arm = STATE.with_borrow_mut(|state| {
        if state.flush_armed || state.flushing {
            return false;
        }
        state.flush_armed = true;
        true
    });

    if arm {
        ic_cdk_timers::set_timer(COALESCE, flush_once());
    }
}

async fn flush_once() {
    STATE.with_borrow_mut(|state| state.flush_armed = false);

    let config = match configured() {
        Ok(config) => config,
        Err(why) => {
            note(why, ic_cdk::api::time());
            return;
        }
    };

    if !STATE.with_borrow(|state| state.outbox.is_seeded()) {
        seed_ids().await;
    }

    let now = ic_cdk::api::time();
    let batch = STATE.with_borrow_mut(|state| {
        state.outbox.promote(now);
        let batch = state.outbox.take(state.batch_limit);
        let (live, expired) = state.outbox.drop_expired(batch, now);
        if expired > 0 {
            state.pipeline.record(now, Event::Dropped, expired as u64);
        }
        live
    });

    if batch.is_empty() {
        return;
    }

    STATE.with_borrow_mut(|state| state.flushing = true);
    let outcome = send_batch(&config, &batch).await;
    STATE.with_borrow_mut(|state| state.flushing = false);

    match &outcome {
        Outcome::TooMany(limit) => {
            STATE.with_borrow_mut(|state| state.batch_limit = (*limit).max(1));
        }
        Outcome::NotAuthorized => note(Misconfigured::NotAuthorizedSender, now),
        _ => {}
    }

    STATE.with_borrow_mut(|state| {
        flush::apply(&mut state.outbox, &mut state.pipeline, batch, outcome, now);
    });

    if STATE.with_borrow(|state| state.outbox.backlog() > 0) {
        arm();
    }
}

async fn send_batch(config: &Config, batch: &[Entry]) -> Outcome {
    let arg = flush::arg(&config.origin, batch);

    let response =
        ic_cdk::call::Call::unbounded_wait(config.internet_identity, "app_send_notification")
            .with_arg(&arg)
            .await;

    match response.map(|reply| reply.candid::<ii::SendNotificationResult>()) {
        Ok(Ok(ii::SendNotificationResult::Ok(response))) => {
            Outcome::Answered(response.not_accepted)
        }
        Ok(Ok(ii::SendNotificationResult::Err(error))) => match error {
            ii::SendNotificationError::TooManyNotifications { limit } => {
                Outcome::TooMany(limit as usize)
            }
            ii::SendNotificationError::NoSuchSender => Outcome::NotAuthorized,
            ii::SendNotificationError::InternalCanisterError(_) => Outcome::Unreachable,
        },
        // A reply we cannot read is no more actionable than no reply at all.
        Ok(Err(_)) | Err(_) => Outcome::Unreachable,
    }
}

/// Counter ids start from a random offset, so two canisters sending for one
/// origin do not both hand out the same low numbers.
async fn seed_ids() {
    let reply =
        ic_cdk::call::Call::unbounded_wait(Principal::management_canister(), "raw_rand").await;

    if let Ok(Ok(bytes)) = reply.map(|reply| reply.candid::<Vec<u8>>()) {
        STATE.with_borrow_mut(|state| state.outbox.seed(&bytes));
    }
}
