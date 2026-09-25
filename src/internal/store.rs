//! Everything the library holds, in stable memory.
//!
//! Nothing lives in the heap, so nothing is serialised on upgrade: a canister
//! with a campaign's worth of pending content upgrades in the same time as an
//! idle one, and `pre_upgrade` has nothing to run out of instructions doing.
//!
//! The maps are ordered by their keys' bytes, which is what replaces the
//! heaps an in-memory version would need: taking a batch is a range scan per
//! lane, and the order survives an upgrade because it was never stored.

use super::ids;
use super::keys::{ParkedKey, ReadyKey};
use crate::types::{
    Bucket, Content, Misconfigured, MisconfiguredSince, Notification, NotificationId,
};
use candid::{CandidType, Decode, Encode, Principal};
use ic_stable_structures::memory_manager::{MemoryId, MemoryManager, VirtualMemory};
use ic_stable_structures::storable::{Bound, Storable};
use ic_stable_structures::{BTreeMap, Cell, DefaultMemoryImpl};
use serde::{Deserialize, Serialize};
use std::borrow::Cow;

pub type Memory = VirtualMemory<DefaultMemoryImpl>;

/// How many stable memories the library keeps its state in. The app names
/// every one of them, so this number is visible at the call site and a change
/// to it is a compile error rather than a collision with the app's own ids.
pub const MEMORIES: usize = 5;

pub const WEIGHTS: [usize; 4] = [8, 4, 2, 1];
const LANES: u8 = 4;

/// How long before a notification expires its second attempt is made. Long
/// enough that a user has the window to come back, early enough that the
/// attempt itself is not refused for being past the expiry.
const RETRY_LEAD: u64 = 300_000_000_000;

const HOUR: u64 = 3_600_000_000_000;
const KEEP_HOURS: usize = 720;

#[derive(CandidType, Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub struct Entry {
    pub id: NotificationId,
    pub recipient: Principal,
    pub lane: u8,
    pub expires_at: u64,
    pub due_at: u64,
    pub parked: bool,
}

impl Entry {
    fn ready_key(&self) -> ReadyKey {
        ReadyKey {
            lane: self.lane,
            expires_at: self.expires_at,
            id: self.id,
        }
    }

    fn parked_key(&self) -> ParkedKey {
        ParkedKey {
            due_at: self.due_at,
            id: self.id,
        }
    }
}

impl Storable for Entry {
    const BOUND: Bound = Bound::Bounded {
        max_size: 64,
        is_fixed_size: false,
    };

    fn to_bytes(&self) -> Cow<'_, [u8]> {
        let who = self.recipient.as_slice();
        let mut bytes = Vec::with_capacity(27 + who.len());
        bytes.extend_from_slice(&self.id.to_be_bytes());
        bytes.extend_from_slice(&self.expires_at.to_be_bytes());
        bytes.extend_from_slice(&self.due_at.to_be_bytes());
        bytes.push(self.lane);
        bytes.push(u8::from(self.parked));
        bytes.push(who.len() as u8);
        bytes.extend_from_slice(who);
        Cow::Owned(bytes)
    }

    fn into_bytes(self) -> Vec<u8> {
        self.to_bytes().into_owned()
    }

    fn from_bytes(bytes: Cow<[u8]>) -> Self {
        let length = usize::from(bytes[26]);
        Self {
            id: u64::from_be_bytes(bytes[..8].try_into().expect("bounded")),
            expires_at: u64::from_be_bytes(bytes[8..16].try_into().expect("bounded")),
            due_at: u64::from_be_bytes(bytes[16..24].try_into().expect("bounded")),
            lane: bytes[24],
            parked: bytes[25] == 1,
            recipient: Principal::from_slice(&bytes[27..27 + length]),
        }
    }
}

/// Candid for the two structures whose shape may grow: the content an app
/// wrote, and the counters the library keeps.
macro_rules! candid_storable {
    ($type:ty, $max:expr) => {
        impl Storable for $type {
            const BOUND: Bound = Bound::Bounded {
                max_size: $max,
                is_fixed_size: false,
            };

            fn to_bytes(&self) -> Cow<'_, [u8]> {
                Cow::Owned(Encode!(self).expect("candid encoding"))
            }

            fn into_bytes(self) -> Vec<u8> {
                Encode!(&self).expect("candid encoding")
            }

            fn from_bytes(bytes: Cow<[u8]>) -> Self {
                Decode!(bytes.as_ref(), Self).expect("candid decoding")
            }
        }
    };
}

/// A notification an app wrote. Bounded so the map can index it, and generous
/// enough that no realistic notification is refused for length.
#[derive(CandidType, Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct StoredContent(pub Content);
candid_storable!(StoredContent, 8_192);

#[derive(CandidType, Serialize, Deserialize, Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Meta {
    pub counter: u64,
    pub id_seed: u64,
    pub bytes: u64,
    pub batch_limit: u64,
    pub misconfigured: Option<MisconfiguredSince>,
}
candid_storable!(Meta, 256);
candid_storable!(Bucket, 128);

pub struct Store {
    ready: BTreeMap<ReadyKey, Entry, Memory>,
    parked: BTreeMap<ParkedKey, Entry, Memory>,
    content: BTreeMap<NotificationId, StoredContent, Memory>,
    hours: BTreeMap<u64, Bucket, Memory>,
    meta: Cell<Meta, Memory>,
}

#[derive(Clone, Copy, Debug)]
pub enum Event {
    Sent,
    Accepted,
    Deferred,
    Received,
    Dropped,
}

impl Store {
    /// Opens the store over the memories the app named. In order: the outbox,
    /// the entries parked for a second attempt, the content a channel may
    /// pull, the hourly metrics, and the counters.
    pub fn new(manager: &MemoryManager<DefaultMemoryImpl>, memories: [MemoryId; MEMORIES]) -> Self {
        Self {
            ready: BTreeMap::init(manager.get(memories[0])),
            parked: BTreeMap::init(manager.get(memories[1])),
            content: BTreeMap::init(manager.get(memories[2])),
            hours: BTreeMap::init(manager.get(memories[3])),
            meta: Cell::init(manager.get(memories[4]), Meta::default()),
        }
    }

    /// Adds a notification, or replaces the one its key already names.
    /// `None` when the capacity ceiling refused it.
    pub fn add(
        &mut self,
        recipient: Principal,
        notification: Notification,
        default_expiry: u64,
        capacity_bytes: u64,
        now: u64,
    ) -> Option<NotificationId> {
        let mut meta = *self.meta.get();

        let id = match notification.key.as_deref() {
            Some(key) => ids::keyed(recipient, key),
            None => {
                meta.counter += 1;
                ids::keyless(meta.id_seed, meta.counter)
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
        if let Some(StoredContent(old)) = self.content.get(&id) {
            meta.bytes = meta.bytes.saturating_sub(size_of_content(&old));
        }

        if meta.bytes + size > capacity_bytes {
            meta.bytes = self.shed(meta.bytes, capacity_bytes, size);
            if meta.bytes + size > capacity_bytes {
                self.meta.set(meta);
                return None;
            }
        }

        self.content.insert(id, StoredContent(content));
        meta.bytes += size;
        self.meta.set(meta);

        // Already waiting — queued, parked or deferred. Its content has just
        // been replaced, so the entry itself stands: queueing a second one
        // would attempt the same notification twice.
        if self.is_waiting(id) {
            return Some(id);
        }

        let entry = Entry {
            id,
            recipient,
            lane: lane_of(notification.urgency) as u8,
            expires_at: notification.expires_at.unwrap_or(default_expiry),
            due_at: now,
            parked: false,
        };
        self.ready.insert(entry.ready_key(), entry);

        Some(id)
    }

    /// Moves parked entries back into their lanes once they are due, so a
    /// flush only ever sees what it may send now.
    pub fn promote(&mut self, now: u64) {
        let due: Vec<(ParkedKey, Entry)> = self
            .parked
            .range(
                ..=ParkedKey {
                    due_at: now,
                    id: u64::MAX,
                },
            )
            .map(|entry| entry.into_pair())
            .collect();

        for (key, entry) in due {
            self.parked.remove(&key);
            self.ready.insert(entry.ready_key(), entry);
        }
    }

    /// A batch, drained from the lanes in weighted cycles: `WEIGHTS[lane]`
    /// from each per cycle, an empty lane donating its turns, and the soonest
    /// expiry leading its lane.
    pub fn take(&mut self, count: usize) -> Vec<Entry> {
        let mut taken = Vec::new();
        let mut cursors: Vec<Option<ReadyKey>> = (0..LANES)
            .map(|lane| Some(ReadyKey::lane_start(lane)))
            .collect();

        while taken.len() < count {
            let mut progressed = false;

            for (lane, &weight) in WEIGHTS.iter().enumerate() {
                for _ in 0..weight {
                    if taken.len() >= count {
                        break;
                    }
                    let Some(from) = cursors[lane] else { break };

                    match self
                        .ready
                        .range(from..=ReadyKey::lane_end(lane as u8))
                        .next()
                        .map(|entry| entry.into_pair())
                    {
                        Some((key, entry)) => {
                            self.ready.remove(&key);
                            taken.push(entry);
                            progressed = true;
                        }
                        None => {
                            cursors[lane] = None;
                            break;
                        }
                    }
                }
            }

            if !progressed {
                break;
            }
        }

        taken
    }

    /// Internet Identity took it. Nothing more to send; its content stays
    /// until a channel has had its chance to pull it.
    pub fn settle(&mut self, _entry: &Entry) {}

    /// A refusal earns one more attempt, just before the notification expires,
    /// which is the whole window the user has to sign in or turn notifications
    /// on. A second refusal drops it. `false` when it was dropped.
    pub fn park(&mut self, mut entry: Entry) -> bool {
        if entry.parked {
            self.release(entry.id);
            return false;
        }

        entry.parked = true;
        entry.due_at = entry.expires_at.saturating_sub(RETRY_LEAD);
        self.parked.insert(entry.parked_key(), entry);
        true
    }

    /// Deferral is Internet Identity asking for the same entry later, not a
    /// refusal, so it waits and comes back unchanged.
    pub fn defer(&mut self, mut entry: Entry, retry_after: u64) {
        entry.due_at = retry_after;
        self.parked.insert(entry.parked_key(), entry);
    }

    /// Nothing was enqueued, so the entry goes back where it came from.
    pub fn requeue(&mut self, mut entry: Entry, now: u64) {
        entry.due_at = now;
        self.ready.insert(entry.ready_key(), entry);
    }

    /// Anything past its expiry is discarded rather than sent, since Internet
    /// Identity would refuse it anyway.
    pub fn drop_expired(&mut self, batch: Vec<Entry>, now: u64) -> (Vec<Entry>, usize) {
        let before = batch.len();
        let live: Vec<Entry> = batch
            .into_iter()
            .filter(|entry| {
                let live = entry.expires_at > now;
                if !live {
                    self.release(entry.id);
                }
                live
            })
            .collect();

        let dropped = before - live.len();
        (live, dropped)
    }

    /// The app says this no longer needs anyone's attention. The content goes,
    /// so a pull finds nothing and a channel that sweeps can close it.
    pub fn dismiss(&mut self, recipient: Principal, key: &str) {
        self.release(ids::keyed(recipient, key));
    }

    pub fn content_of(&self, id: NotificationId) -> Option<Content> {
        self.content.get(&id).map(|StoredContent(content)| content)
    }

    pub fn backlog(&self) -> u64 {
        self.ready.len() + self.parked.len()
    }

    pub fn batch_limit(&self) -> usize {
        self.meta.get().batch_limit.max(1) as usize
    }

    pub fn set_batch_limit(&mut self, limit: usize) {
        let mut meta = *self.meta.get();
        meta.batch_limit = limit as u64;
        self.meta.set(meta);
    }

    pub fn misconfigured(&self) -> Option<MisconfiguredSince> {
        self.meta.get().misconfigured
    }

    pub fn note(&mut self, why: Misconfigured, now: u64) {
        let mut meta = *self.meta.get();
        if meta.misconfigured.map(|m| m.why) != Some(why) {
            meta.misconfigured = Some(MisconfiguredSince { why, since: now });
            self.meta.set(meta);
        }
    }

    pub fn is_seeded(&self) -> bool {
        self.meta.get().id_seed != 0
    }

    pub fn seed(&mut self, randomness: &[u8]) {
        let mut meta = *self.meta.get();
        if meta.id_seed == 0 {
            meta.id_seed = ids::seed_from(randomness);
            self.meta.set(meta);
        }
    }

    pub fn record(&mut self, now: u64, event: Event, count: u64) {
        let start = now - (now % HOUR);
        let mut bucket = self.hours.get(&start).unwrap_or(Bucket {
            start,
            ..Bucket::default()
        });

        match event {
            Event::Sent => bucket.sent += count,
            Event::Accepted => bucket.accepted += count,
            Event::Deferred => bucket.deferred += count,
            Event::Received => bucket.received += count,
            Event::Dropped => bucket.dropped += count,
        }

        self.hours.insert(start, bucket);

        while self.hours.len() as usize > KEEP_HOURS {
            if let Some((oldest, _)) = self.hours.first_key_value() {
                self.hours.remove(&oldest);
            } else {
                break;
            }
        }
    }

    pub fn hours(&self) -> Vec<Bucket> {
        self.hours.values().collect()
    }

    /// A receipt is recorded only while the content is still there; content
    /// stays until it expires, because other devices may still pull it.
    pub fn mark_received(&mut self, id: NotificationId) -> bool {
        self.content.contains_key(&id)
    }

    fn is_waiting(&self, id: NotificationId) -> bool {
        self.ready.range(..).any(|entry| entry.key().id == id)
            || self.parked.range(..).any(|entry| entry.key().id == id)
    }

    fn release(&mut self, id: NotificationId) {
        if let Some(StoredContent(content)) = self.content.remove(&id) {
            let mut meta = *self.meta.get();
            meta.bytes = meta.bytes.saturating_sub(size_of_content(&content));
            self.meta.set(meta);
        }
    }

    /// Nothing accepted is ever shed: Internet Identity may still deliver it
    /// and a pull has to find content. What goes is the outbox, and the lowest
    /// lane first — a campaign's entries before the notification behind them.
    fn shed(&mut self, mut bytes: u64, capacity_bytes: u64, needed: u64) -> u64 {
        for lane in (0..LANES).rev() {
            while bytes + needed > capacity_bytes {
                let Some((key, entry)) = self
                    .ready
                    .range(ReadyKey::lane_start(lane)..=ReadyKey::lane_end(lane))
                    .next()
                    .map(|entry| entry.into_pair())
                else {
                    break;
                };

                self.ready.remove(&key);
                if let Some(StoredContent(content)) = self.content.remove(&entry.id) {
                    bytes = bytes.saturating_sub(size_of_content(&content));
                }
            }
        }

        bytes
    }
}

pub fn lane_of(urgency: Option<crate::types::Urgency>) -> usize {
    use crate::types::Urgency;
    match urgency.unwrap_or_default() {
        Urgency::High => 0,
        Urgency::Normal => 1,
        Urgency::Low => 2,
        Urgency::VeryLow => 3,
    }
}

fn size_of_content(content: &Content) -> u64 {
    (content.title.len() + content.body.len() + content.url.as_ref().map_or(0, String::len) + 64)
        as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Urgency;

    const HOUR: u64 = 3_600_000_000_000;
    const ROOMY: u64 = 1_000_000;
    const MEMORY_IDS: [MemoryId; MEMORIES] = [
        MemoryId::new(0),
        MemoryId::new(1),
        MemoryId::new(2),
        MemoryId::new(3),
        MemoryId::new(4),
    ];

    /// Off-canister, `DefaultMemoryImpl` is a plain vector, so the whole store
    /// runs in a test without a replica.
    fn store() -> Store {
        let manager = Box::leak(Box::new(MemoryManager::init(DefaultMemoryImpl::default())));
        Store::new(manager, MEMORY_IDS)
    }

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
        let mut store = store();
        let first = store.add(alice(), note("one", Some("k"), None), HOUR, ROOMY, 0);
        let second = store.add(alice(), note("two", Some("k"), None), HOUR, ROOMY, 0);

        assert_eq!(first, second);
        assert_eq!(store.content_of(first.unwrap()).unwrap().title, "two");
        assert_eq!(store.take(10).len(), 1, "one entry, not two");
    }

    #[test]
    fn a_batch_comes_out_by_lane_weight_and_then_by_expiry() {
        let mut store = store();
        for i in 0..20 {
            store.add(
                alice(),
                note("campaign", Some(&format!("c{i}")), Some(Urgency::VeryLow)),
                HOUR + i,
                ROOMY,
                0,
            );
            store.add(
                alice(),
                note("urgent", Some(&format!("u{i}")), Some(Urgency::High)),
                HOUR + i,
                ROOMY,
                0,
            );
        }

        let batch = store.take(9);
        let urgent = batch.iter().filter(|entry| entry.lane == 0).count();
        assert_eq!((urgent, batch.len() - urgent), (8, 1), "weights are 8 : 1");

        let urgent_expiries: Vec<u64> = batch
            .iter()
            .filter(|entry| entry.lane == 0)
            .map(|entry| entry.expires_at)
            .collect();
        let mut sorted = urgent_expiries.clone();
        sorted.sort_unstable();
        assert_eq!(urgent_expiries, sorted, "soonest expiry leads its lane");
    }

    #[test]
    fn a_refusal_parks_until_expiry_and_a_second_one_drops_it() {
        let mut store = store();
        let id = store
            .add(alice(), note("x", Some("k"), None), 10 * HOUR, ROOMY, 0)
            .unwrap();

        let first = store.take(10);
        assert!(store.park(first[0]));

        store.promote(HOUR);
        assert!(store.take(10).is_empty(), "not due yet");

        store.promote(10 * HOUR);
        let second = store.take(10);
        assert_eq!(second.len(), 1);
        assert!(!store.park(second[0]), "second refusal drops it");
        assert!(store.content_of(id).is_none());
        assert_eq!(store.backlog(), 0);
    }

    #[test]
    fn the_ceiling_sheds_the_campaign_and_keeps_the_urgent() {
        let mut store = store();
        let tiny = 900;

        for i in 0..20 {
            store.add(
                alice(),
                note("campaign", Some(&format!("c{i}")), Some(Urgency::VeryLow)),
                HOUR,
                tiny,
                0,
            );
        }
        let urgent = store.add(
            alice(),
            note("urgent", Some("u"), Some(Urgency::High)),
            HOUR,
            tiny,
            0,
        );

        assert!(urgent.is_some());
        assert!(store.content_of(urgent.unwrap()).is_some());
    }

    #[test]
    fn hours_accumulate_and_the_ring_keeps_a_month() {
        let mut store = store();
        store.record(5 * HOUR + 1, Event::Sent, 3);
        store.record(5 * HOUR + 2_000, Event::Accepted, 2);

        let hours = store.hours();
        assert_eq!(hours.len(), 1);
        assert_eq!((hours[0].sent, hours[0].accepted), (3, 2));
        assert_eq!(hours[0].start, 5 * HOUR);

        for hour in 0..800u64 {
            store.record(hour * HOUR, Event::Sent, 1);
        }
        assert_eq!(store.hours().len(), KEEP_HOURS);
    }

    #[test]
    fn a_receipt_is_only_recorded_while_the_content_is_there() {
        let mut store = store();
        let id = store
            .add(alice(), note("x", Some("k"), None), HOUR, ROOMY, 0)
            .unwrap();

        assert!(store.mark_received(id));
        store.dismiss(alice(), "k");
        assert!(!store.mark_received(id), "nothing left to have received");
    }

    #[test]
    fn nothing_is_lost_across_a_reopen() {
        let manager = Box::leak(Box::new(MemoryManager::init(DefaultMemoryImpl::default())));
        let id = {
            let mut store = Store::new(manager, MEMORY_IDS);
            store.add(alice(), note("pending", Some("k"), None), HOUR, ROOMY, 0);
            store.record(HOUR, Event::Sent, 1);
            store.set_batch_limit(17);
            ids::keyed(alice(), "k")
        };

        // What an upgrade does: the same memories, a fresh handle, nothing
        // serialised in between.
        let reopened = Store::new(manager, MEMORY_IDS);
        assert!(reopened.content_of(id).is_some(), "content survives");
        assert_eq!(reopened.backlog(), 1, "the outbox survives");
        assert_eq!(reopened.hours().len(), 1, "metrics survive");
        assert_eq!(reopened.batch_limit(), 17, "the learned limit survives");
    }
}
