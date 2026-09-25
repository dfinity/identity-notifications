//! What an app passes in and reads back. Everything else is internal.

use candid::{CandidType, Principal};
use serde::{Deserialize, Serialize};

/// How Internet Identity should schedule a notification against the origin's
/// other traffic. Not a rendering hint: channels without a tray honour it too.
#[derive(CandidType, Serialize, Deserialize, Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Urgency {
    VeryLow,
    Low,
    #[default]
    Normal,
    High,
}

/// What the app describes when it sends.
///
/// Build it with [`Notification::new`] and the setters, which spares you the
/// fields you do not care about:
///
/// ```
/// use identity_notifications::{Notification, Urgency};
///
/// let notification = Notification::new("New message", "See you at six")
///     .url("https://chat.example.com/chats/alice")
///     .key("chat-alice")
///     .urgency(Urgency::High);
/// ```
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Notification {
    pub title: String,
    pub body: String,
    /// Where acting on it takes them. Must be on the sending origin or one of
    /// its alternative origins; Internet Identity refuses anything else.
    pub url: Option<String>,
    /// What this notification is about. Sending again with the same key
    /// updates that notification rather than adding another, and it is what
    /// [`crate::dismiss`] names. Derive it from data the sender cannot choose.
    pub key: Option<String>,
    pub urgency: Option<Urgency>,
    /// `None` is Internet Identity's default retention, which is also its
    /// ceiling. Nanoseconds since the epoch.
    pub expires_at: Option<u64>,
}

impl Notification {
    pub fn new(title: impl Into<String>, body: impl Into<String>) -> Self {
        Self {
            title: title.into(),
            body: body.into(),
            url: None,
            key: None,
            urgency: None,
            expires_at: None,
        }
    }

    pub fn url(mut self, url: impl Into<String>) -> Self {
        self.url = Some(url.into());
        self
    }

    pub fn key(mut self, key: impl Into<String>) -> Self {
        self.key = Some(key.into());
        self
    }

    pub fn urgency(mut self, urgency: Urgency) -> Self {
        self.urgency = Some(urgency);
        self
    }

    pub fn expires_at(mut self, expires_at: u64) -> Self {
        self.expires_at = Some(expires_at);
        self
    }
}

/// What a channel pulls back. The rest of a [`Notification`] never leaves this
/// canister.
#[derive(CandidType, Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct Content {
    pub title: String,
    pub body: String,
    pub url: Option<String>,
}

/// One hour of the delivery pipeline.
#[derive(CandidType, Serialize, Deserialize, Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Bucket {
    /// The instant the hour begins, nanoseconds since the epoch.
    pub start: u64,
    pub sent: u64,
    pub accepted: u64,
    pub deferred: u64,
    pub received: u64,
    pub dropped: u64,
}

#[derive(CandidType, Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub enum Misconfigured {
    /// `notification_origin` is unset or empty.
    Origin,
    /// `internet_identity` is unset or not a principal.
    InternetIdentity,
    /// The origin does not publish this canister as one of its senders.
    NotAuthorizedSender,
}

#[derive(CandidType, Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub struct MisconfiguredSince {
    pub why: Misconfigured,
    pub since: u64,
}

#[derive(CandidType, Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct Metrics {
    /// Up to 720 buckets, oldest first. Hours with no traffic are absent.
    pub hours: Vec<Bucket>,
    /// Notifications waiting for Internet Identity to accept them.
    pub backlog: u64,
    pub misconfigured: Option<MisconfiguredSince>,
}

/// Internet Identity scopes notification ids to `(origin, recipient)`.
pub type NotificationId = u64;

/// Who a pull is for, as Internet Identity signed it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SenderInfo {
    pub origin: String,
    pub account: Principal,
}
