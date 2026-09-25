//! Notify Internet Identity users from a Rust canister.
//!
//! One call to send; the library owns the ids, the batching, the retries, the
//! content Internet Identity pulls back, and the delivery metrics.
//!
//! ```ignore
//! use ic_cdk::update;
//! use identity_notifications as notifications;
//! use notifications::Notification;
//!
//! notifications::endpoints!();
//!
//! #[update]
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
use ic_cdk::api::{msg_caller_info_data, msg_caller_info_signer, time};
use ic_cdk::call::Call;
use ic_cdk_timers::set_timer;
use ic_stable_structures::memory_manager::MemoryManager;
use ic_stable_structures::DefaultMemoryImpl;
use internal::config::{self, Config};
use internal::flush::{self, Outcome};
use internal::ii;
pub use internal::store::Memories;
use internal::store::{Entry, Event, Store};
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

thread_local! {
    /// Everything durable lives in stable memory; what is here is the handle
    /// to it, plus two flags that only matter within one execution round.
    static STORE: RefCell<Option<Store>> = const { RefCell::new(None) };
    static FLUSH_ARMED: RefCell<bool> = const { RefCell::new(false) };
    static FLUSHING: RefCell<bool> = const { RefCell::new(false) };
}

/// Hands the library the stable memories it keeps everything in. Every one is
/// named, so what the library is taking is written at the call site rather
/// than hidden behind a count — and a version that needs another memory adds a
/// field, which stops this compiling instead of quietly taking an id you were
/// already using.
///
/// Call it from `#[init]` **and** `#[post_upgrade]`. Nothing is serialised on
/// upgrade and nothing is restored: the maps are already where they were.
///
/// ```ignore
/// use ic_cdk::{init, post_upgrade};
/// use ic_stable_structures::memory_manager::MemoryManager;
///
/// thread_local! {
///     static MEMORIES: RefCell<MemoryManager<DefaultMemoryImpl>> =
///         RefCell::new(MemoryManager::init(DefaultMemoryImpl::default()));
/// }
///
/// #[init]
/// #[post_upgrade]
/// fn init() {
///     MEMORIES.with_borrow(|manager| {
///         notifications::init(
///             manager,
///             Memories {
///                 outbox: MemoryId::new(10),
///                 parked: MemoryId::new(11),
///                 content: MemoryId::new(12),
///                 metrics: MemoryId::new(13),
///                 counters: MemoryId::new(14),
///             },
///         )
///     });
/// }
/// ```
pub fn init(manager: &MemoryManager<DefaultMemoryImpl>, memories: Memories) {
    let mut store = Store::new(manager, memories);
    if store.batch_limit() <= 1 {
        store.set_batch_limit(BATCH_GUESS);
    }

    STORE.set(Some(store));
    arm();
}

fn with_store<T>(f: impl FnOnce(&mut Store) -> T) -> Option<T> {
    STORE.with_borrow_mut(|store| store.as_mut().map(f))
}

/// Sends a notification, or updates the one this recipient's `key` already
/// names.
///
/// Never traps and never awaits: a notification is an aside to whatever the
/// app was actually doing, so a failure here must not fail that. Everything
/// that goes wrong afterwards is absorbed by the library and visible in
/// [`metrics`].
pub fn send(recipient: Principal, notification: Notification) {
    let now = time();

    let config = match configured() {
        Ok(config) => config,
        Err(why) => {
            note(why, now);
            with_store(|store| store.record(now, Event::Dropped, 1));
            return;
        }
    };

    let added = with_store(|store| {
        store.add(
            recipient,
            notification,
            now + DEFAULT_RETENTION,
            config.capacity_bytes as u64,
            now,
        )
    });

    match added {
        Some(Some(_)) => arm(),
        // Refused by the ceiling, or `init` was never called.
        Some(None) | None => {
            with_store(|store| store.record(now, Event::Dropped, 1));
        }
    }
}

/// This notification no longer needs anyone's attention. Its content goes, so
/// a pull finds nothing and a channel that sweeps can close it.
pub fn dismiss(recipient: Principal, key: &str) {
    with_store(|store| store.dismiss(recipient, key));
}

/// The delivery pipeline, hour by hour, for whatever the app already uses to
/// watch itself.
pub fn metrics() -> Metrics {
    with_store(|store| Metrics {
        hours: store.hours(),
        backlog: store.backlog(),
        misconfigured: store.misconfigured(),
    })
    .unwrap_or(Metrics {
        hours: Vec::new(),
        backlog: 0,
        misconfigured: None,
    })
}

/// Answers Internet Identity's content pull. Call this from the endpoint
/// [`endpoints!`] generates, or from your own if you would rather name it.
pub fn notification_content(id: NotificationId) -> Option<Content> {
    sender_info()?;
    with_store(|store| store.content_of(id)).flatten()
}

/// Records Internet Identity's receipt. Content stays until it expires: other
/// devices may still pull the same notification.
pub fn notification_received(id: NotificationId) {
    if sender_info().is_none() {
        return;
    }
    let now = time();
    with_store(|store| {
        if store.mark_received(id) {
            store.record(now, Event::Received, 1);
        }
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

fn configured() -> Result<Config, Misconfigured> {
    config::read()
}

fn note(why: Misconfigured, now: u64) {
    with_store(|store| store.note(why, now));
}

/// Internet Identity signed this call's caller info, and it names our own
/// origin. Anything else is not ours to answer.
fn sender_info() -> Option<SenderInfo> {
    let config = configured().ok()?;
    if msg_caller_info_signer()? != config.internet_identity {
        return None;
    }

    let info = internal::caller_info::decode(&msg_caller_info_data())?;
    (info.origin == config.origin).then_some(info)
}

fn arm() {
    let arm = FLUSH_ARMED.with_borrow_mut(|armed| {
        if *armed || FLUSHING.with_borrow(|flushing| *flushing) {
            return false;
        }
        *armed = true;
        true
    });

    if arm {
        set_timer(COALESCE, flush_once());
    }
}

async fn flush_once() {
    FLUSH_ARMED.set(false);

    let config = match configured() {
        Ok(config) => config,
        Err(why) => {
            note(why, time());
            return;
        }
    };

    if with_store(|store| store.is_seeded()) == Some(false) {
        seed_ids().await;
    }

    let now = time();
    let batch = with_store(|store| {
        store.promote(now);
        let batch = store.take(store.batch_limit());
        let (live, expired) = store.drop_expired(batch, now);
        if expired > 0 {
            store.record(now, Event::Dropped, expired as u64);
        }
        live
    })
    .unwrap_or_default();

    if batch.is_empty() {
        return;
    }

    FLUSHING.set(true);
    let outcome = send_batch(&config, &batch).await;
    FLUSHING.set(false);

    match &outcome {
        Outcome::TooMany(limit) => {
            with_store(|store| store.set_batch_limit((*limit).max(1)));
        }
        Outcome::NotAuthorized => note(Misconfigured::NotAuthorizedSender, now),
        _ => {}
    }

    with_store(|store| flush::apply(store, batch, outcome, now));

    if with_store(|store| store.backlog() > 0) == Some(true) {
        arm();
    }
}

async fn send_batch(config: &Config, batch: &[Entry]) -> Outcome {
    let arg = flush::arg(&config.origin, batch);

    let response = Call::unbounded_wait(config.internet_identity, "app_send_notification")
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
    let reply = Call::unbounded_wait(Principal::management_canister(), "raw_rand").await;

    if let Ok(Ok(bytes)) = reply.map(|reply| reply.candid::<Vec<u8>>()) {
        with_store(|store| store.seed(&bytes));
    }
}
