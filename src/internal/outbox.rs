//! What is waiting to be sent, and what a channel may still pull.
//!
//! Entries live in lanes by urgency while they are ready to go, and in a
//! parking queue while they wait for the second attempt a refusal earns them.

use super::ids;
use super::lane_queue::{LaneQueue, Laned};
use crate::types::{Content, Notification, NotificationId, Urgency};
use candid::{CandidType, Principal};
use serde::{Deserialize, Serialize};
use std::collections::{BinaryHeap, HashMap, HashSet};

pub const WEIGHTS: [usize; 4] = [8, 4, 2, 1];

/// How long before a notification expires its second attempt is made. Long
/// enough that a user has the window to come back, early enough that the
/// attempt itself is not refused for being past the expiry.
const RETRY_LEAD: u64 = 300_000_000_000;

#[derive(CandidType, Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub id: NotificationId,
    pub recipient: Principal,
    pub lane: usize,
    pub expires_at: u64,
    pub due_at: u64,
    pub parked: bool,
}

impl Laned for Entry {
    fn lane(&self) -> usize {
        self.lane
    }

    fn order(&self) -> u64 {
        self.expires_at
    }
}

/// Parked entries wait on when they are next due, not on when they expire.
#[derive(Debug, PartialEq, Eq)]
struct Parked(Entry);

impl Ord for Parked {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        other.0.due_at.cmp(&self.0.due_at)
    }
}

impl PartialOrd for Parked {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

#[derive(Debug)]
pub struct Outbox {
    ready: LaneQueue<Entry>,
    parked: BinaryHeap<Parked>,
    content: HashMap<NotificationId, Content>,
    received: HashSet<NotificationId>,
    /// Everything waiting to be accepted, so a repeat of a key updates what is
    /// queued instead of queueing a second attempt.
    waiting: HashSet<NotificationId>,
    counter: u64,
    id_seed: u64,
    bytes: usize,
}

impl Default for Outbox {
    fn default() -> Self {
        Self {
            ready: LaneQueue::new(&WEIGHTS),
            parked: BinaryHeap::new(),
            content: HashMap::new(),
            received: HashSet::new(),
            waiting: HashSet::new(),
            counter: 0,
            id_seed: 0,
            bytes: 0,
        }
    }
}

pub fn lane_of(urgency: Option<Urgency>) -> usize {
    match urgency.unwrap_or_default() {
        Urgency::High => 0,
        Urgency::Normal => 1,
        Urgency::Low => 2,
        Urgency::VeryLow => 3,
    }
}

impl Outbox {
    /// Adds a notification, or replaces the one its key already names.
    /// `None` when the capacity ceiling refused it.
    pub fn add(
        &mut self,
        recipient: Principal,
        notification: Notification,
        default_expiry: u64,
        capacity_bytes: usize,
        now: u64,
    ) -> Option<NotificationId> {
        let id = match notification.key.as_deref() {
            Some(key) => ids::keyed(recipient, key),
            None => {
                self.counter += 1;
                ids::keyless(self.id_seed, self.counter)
            }
        };

        let content = Content {
            title: notification.title,
            body: notification.body,
            url: notification.url,
        };
        let size = size_of_content(&content);

        // Replacing frees what the old one held, so an app that updates the
        // same key forever occupies one notification's worth of room.
        if let Some(old) = self.content.get(&id) {
            self.bytes -= size_of_content(old);
        }

        if self.bytes + size > capacity_bytes && !self.shed(capacity_bytes, size) {
            return None;
        }

        self.content.insert(id, content);
        self.bytes += size;

        // Already waiting — queued, parked or deferred. Its content has just
        // been replaced, so the entry itself stands: queueing a second one
        // would attempt the same notification twice.
        if self.waiting.contains(&id) {
            return Some(id);
        }

        let lane = lane_of(notification.urgency);
        self.waiting.insert(id);
        self.ready.push(Entry {
            id,
            recipient,
            lane,
            expires_at: notification.expires_at.unwrap_or(default_expiry),
            due_at: now,
            parked: false,
        });

        Some(id)
    }

    /// Moves parked entries back into their lanes once they are due, so a
    /// flush only ever sees what it may send now.
    pub fn promote(&mut self, now: u64) {
        while self.parked.peek().is_some_and(|p| p.0.due_at <= now) {
            let Parked(entry) = self.parked.pop().expect("just peeked");
            self.ready.push(entry);
        }
    }

    pub fn take(&mut self, count: usize) -> Vec<Entry> {
        self.ready.take(count)
    }

    /// Internet Identity took it. Nothing more to send, so the entry goes; its
    /// content stays until a channel has had its chance to pull it.
    pub fn settle(&mut self, entry: &Entry) {
        self.waiting.remove(&entry.id);
    }

    /// A refusal earns one more attempt, just before the notification expires,
    /// which is the whole window the user has to sign in or turn notifications
    /// on. A second refusal drops it. `false` when it was dropped.
    pub fn park(&mut self, mut entry: Entry) -> bool {
        if entry.parked {
            self.waiting.remove(&entry.id);
            self.release(entry.id);
            return false;
        }

        entry.parked = true;
        entry.due_at = entry.expires_at.saturating_sub(RETRY_LEAD);
        self.parked.push(Parked(entry));
        true
    }

    /// Deferral is Internet Identity asking for the same entry later, not a
    /// refusal, so the entry waits and comes back unchanged.
    pub fn defer(&mut self, mut entry: Entry, retry_after: u64) {
        entry.due_at = retry_after;
        self.parked.push(Parked(entry));
    }

    /// Nothing was enqueued, so the entry goes back where it came from.
    pub fn requeue(&mut self, mut entry: Entry, now: u64) {
        entry.due_at = now;
        self.ready.push(entry);
    }

    /// The app says this no longer needs anyone's attention. The content goes,
    /// so a pull finds nothing and a channel that sweeps can close it.
    pub fn dismiss(&mut self, recipient: Principal, key: &str) {
        self.release(ids::keyed(recipient, key));
    }

    /// A channel delivered it. Recorded rather than acted on: other devices may
    /// still pull the same notification, so content stays until it expires.
    pub fn mark_received(&mut self, id: NotificationId) {
        if self.content.contains_key(&id) {
            self.received.insert(id);
        }
    }

    pub fn was_received(&self, id: NotificationId) -> bool {
        self.received.contains(&id)
    }

    pub fn content_of(&self, id: NotificationId) -> Option<&Content> {
        self.content.get(&id)
    }

    pub fn backlog(&self) -> usize {
        self.ready.len() + self.parked.len()
    }

    pub fn seed(&mut self, randomness: &[u8]) {
        if self.id_seed == 0 {
            self.id_seed = ids::seed_from(randomness);
        }
    }

    pub fn is_seeded(&self) -> bool {
        self.id_seed != 0
    }

    /// Anything past its expiry is discarded rather than sent, since Internet
    /// Identity would refuse it anyway.
    pub fn drop_expired(&mut self, entries: Vec<Entry>, now: u64) -> (Vec<Entry>, usize) {
        let before = entries.len();
        let live: Vec<Entry> = entries
            .into_iter()
            .filter(|entry| {
                let live = entry.expires_at > now;
                if !live {
                    self.waiting.remove(&entry.id);
                    self.release(entry.id);
                }
                live
            })
            .collect();

        let dropped = before - live.len();
        (live, dropped)
    }

    fn release(&mut self, id: NotificationId) {
        if let Some(content) = self.content.remove(&id) {
            self.bytes -= size_of_content(&content);
        }
        self.received.remove(&id);
    }

    /// Nothing accepted is ever shed: Internet Identity may still deliver it
    /// and a pull has to find content. What goes is the outbox, and the lowest
    /// lane first — a campaign's entries before the notification behind them.
    fn shed(&mut self, capacity_bytes: usize, needed: usize) -> bool {
        for lane in (0..WEIGHTS.len()).rev() {
            while self.bytes + needed > capacity_bytes {
                match self.ready.pop_lane(lane) {
                    Some(entry) => {
                        self.waiting.remove(&entry.id);
                        self.release(entry.id);
                    }
                    None => break,
                }
            }
        }

        self.bytes + needed <= capacity_bytes
    }
}

/// Everything the outbox holds, in a shape an app can persist. The heaps are
/// rebuilt on the way back in, since their order is derived rather than data.
#[derive(CandidType, Serialize, Deserialize, Clone, Debug, Default)]
pub struct OutboxSnapshot {
    pub ready: Vec<Entry>,
    pub parked: Vec<Entry>,
    pub content: Vec<(NotificationId, Content)>,
    pub received: Vec<NotificationId>,
    pub counter: u64,
    pub id_seed: u64,
}

/// Everything the library holds.
#[derive(CandidType, Serialize, Deserialize, Clone, Debug, Default)]
pub struct Snapshot {
    pub outbox: OutboxSnapshot,
    pub pipeline: super::metrics::Pipeline,
    pub batch_limit: usize,
    pub misconfigured: Option<crate::types::MisconfiguredSince>,
}

impl Outbox {
    pub fn export(&self) -> OutboxSnapshot {
        OutboxSnapshot {
            ready: self.ready.drain_clone(),
            parked: self.parked.iter().map(|p| p.0.clone()).collect(),
            content: self
                .content
                .iter()
                .map(|(id, c)| (*id, c.clone()))
                .collect(),
            received: self.received.iter().copied().collect(),
            counter: self.counter,
            id_seed: self.id_seed,
        }
    }

    pub fn import(snapshot: OutboxSnapshot) -> Self {
        let mut outbox = Self {
            counter: snapshot.counter,
            id_seed: snapshot.id_seed,
            ..Self::default()
        };

        for entry in snapshot.ready {
            outbox.waiting.insert(entry.id);
            outbox.ready.push(entry);
        }
        for entry in snapshot.parked {
            outbox.waiting.insert(entry.id);
            outbox.parked.push(Parked(entry));
        }
        for (id, content) in snapshot.content {
            outbox.bytes += size_of_content(&content);
            outbox.content.insert(id, content);
        }
        outbox.received = snapshot.received.into_iter().collect();

        outbox
    }
}

fn size_of_content(content: &Content) -> usize {
    content.title.len() + content.body.len() + content.url.as_ref().map_or(0, String::len) + 64
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOUR: u64 = 3_600_000_000_000;
    const ROOMY: usize = 1_000_000;

    fn alice() -> Principal {
        Principal::from_text("un4fu-tqaaa-aaaab-qadjq-cai").unwrap()
    }

    fn note(title: &str, key: Option<&str>, urgency: Option<Urgency>) -> Notification {
        let mut notification = Notification::new(title, "body");
        notification.key = key.map(str::to_string);
        notification.urgency = urgency;
        notification
    }

    #[test]
    fn the_same_key_replaces_rather_than_adds() {
        let mut outbox = Outbox::default();
        let first = outbox.add(alice(), note("one", Some("k"), None), HOUR, ROOMY, 0);
        let second = outbox.add(alice(), note("two", Some("k"), None), HOUR, ROOMY, 0);

        assert_eq!(first, second);
        assert_eq!(outbox.content_of(first.unwrap()).unwrap().title, "two");
        assert_eq!(outbox.take(10).len(), 1, "one entry, not two");
    }

    #[test]
    fn urgency_decides_the_lane() {
        let mut outbox = Outbox::default();
        outbox.add(
            alice(),
            note("c", Some("c"), Some(Urgency::VeryLow)),
            HOUR,
            ROOMY,
            0,
        );
        outbox.add(
            alice(),
            note("u", Some("u"), Some(Urgency::High)),
            HOUR,
            ROOMY,
            0,
        );

        let batch = outbox.take(2);
        assert_eq!(batch[0].lane, 0);
    }

    #[test]
    fn a_refusal_parks_until_expiry_and_a_second_one_drops_it() {
        let mut outbox = Outbox::default();
        let id = outbox
            .add(alice(), note("x", Some("k"), None), 10 * HOUR, ROOMY, 0)
            .unwrap();

        let first = outbox.take(10);
        assert!(outbox.park(first[0].clone()));

        outbox.promote(HOUR);
        assert!(outbox.take(10).is_empty(), "not due yet");

        outbox.promote(10 * HOUR);
        let second = outbox.take(10);
        assert_eq!(second.len(), 1);
        assert!(!outbox.park(second[0].clone()), "second refusal drops it");
        assert!(outbox.content_of(id).is_none());
        assert_eq!(outbox.backlog(), 0);
    }

    #[test]
    fn deferral_comes_back_when_asked_for() {
        let mut outbox = Outbox::default();
        outbox.add(alice(), note("x", Some("k"), None), 10 * HOUR, ROOMY, 0);

        let batch = outbox.take(10);
        outbox.defer(batch[0].clone(), 2 * HOUR);

        outbox.promote(HOUR);
        assert!(outbox.take(10).is_empty());
        outbox.promote(2 * HOUR);
        assert_eq!(outbox.take(10).len(), 1);
    }

    #[test]
    fn the_ceiling_sheds_the_campaign_and_keeps_the_urgent() {
        let mut outbox = Outbox::default();
        let tiny = 900;

        for i in 0..20 {
            outbox.add(
                alice(),
                note("campaign", Some(&format!("c{i}")), Some(Urgency::VeryLow)),
                HOUR,
                tiny,
                0,
            );
        }
        let urgent = outbox.add(
            alice(),
            note("urgent", Some("u"), Some(Urgency::High)),
            HOUR,
            tiny,
            0,
        );

        assert!(urgent.is_some());
        assert!(outbox.content_of(urgent.unwrap()).is_some());
    }

    #[test]
    fn expired_entries_are_discarded_rather_than_sent() {
        let mut outbox = Outbox::default();
        outbox.add(alice(), note("gone", Some("g"), None), HOUR, ROOMY, 0);

        let batch = outbox.take(10);
        let (live, dropped) = outbox.drop_expired(batch, 2 * HOUR);
        assert!(live.is_empty());
        assert_eq!(dropped, 1);
        assert!(outbox.content_of(ids::keyed(alice(), "g")).is_none());
    }

    #[test]
    fn dismissing_releases_the_content() {
        let mut outbox = Outbox::default();
        let id = outbox
            .add(alice(), note("x", Some("k"), None), HOUR, ROOMY, 0)
            .unwrap();

        outbox.dismiss(alice(), "k");
        assert!(outbox.content_of(id).is_none());
    }
}
