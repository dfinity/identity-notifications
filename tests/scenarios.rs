//! A chat app and an Internet Identity, both fake, so scenarios can be run
//! without a replica. The library's canister layer is a batch, a call and
//! `flush::apply`; everything worth checking is on this side of the await.

use candid::Principal;
use ic_stable_structures::memory_manager::MemoryManager;
use ic_stable_structures::DefaultMemoryImpl;
use identity_notifications::internal::flush::{self, Outcome};
use identity_notifications::internal::ii;
use identity_notifications::internal::store::{Event, Store};
use identity_notifications::{Notification, Urgency};
use std::collections::HashMap;

const HOUR: u64 = 3_600_000_000_000;
const CAPACITY: u64 = 1_073_741_824;

/// Whether Internet Identity knows a recipient, and whether they have a
/// channel.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Known {
    Reachable,
    NoChannel,
}

struct World {
    store: Store,
    known: HashMap<Principal, Known>,
    room_per_flush: usize,
    batch_limit: usize,
}

struct Flushed {
    sent: usize,
    accepted: usize,
}

impl World {
    fn new(room_per_flush: usize) -> Self {
        // Off-canister, `DefaultMemoryImpl` is a plain vector, so the stable
        // maps run in a test without a replica.
        let manager = Box::leak(Box::new(MemoryManager::init(DefaultMemoryImpl::default())));
        Self {
            store: Store::new(manager, 0),
            known: HashMap::new(),
            room_per_flush,
            batch_limit: 1_000,
        }
    }

    fn reachable(&mut self, who: Principal) {
        self.known.insert(who, Known::Reachable);
    }

    fn no_channel(&mut self, who: Principal) {
        self.known.insert(who, Known::NoChannel);
    }

    fn send(&mut self, to: Principal, notification: Notification, now: u64) {
        self.store
            .add(to, notification, now + 24 * HOUR, CAPACITY, now);
    }

    /// One flush: what Internet Identity would answer, applied the way the
    /// canister layer applies it.
    fn flush(&mut self, now: u64) -> Flushed {
        self.store.promote(now);
        let batch = self.store.take(self.batch_limit);
        let (batch, _) = self.store.drop_expired(batch, now);
        if batch.is_empty() {
            return Flushed {
                sent: 0,
                accepted: 0,
            };
        }

        let mut not_accepted: Vec<ii::NotAccepted> = batch
            .iter()
            .filter_map(|entry| {
                let reason = match self.known.get(&entry.recipient) {
                    None => ii::NotAcceptedReason::NoSuchRecipient,
                    Some(Known::NoChannel) => ii::NotAcceptedReason::NoChannel,
                    Some(Known::Reachable) => return None,
                };
                Some(ii::NotAccepted {
                    id: entry.id,
                    recipient: entry.recipient,
                    reason,
                })
            })
            .collect();

        // Capacity: anything beyond the origin's room this flush is deferred.
        let taken = batch.len() - not_accepted.len();
        let deferrals = taken.saturating_sub(self.room_per_flush);
        for entry in batch.iter().rev().take(deferrals) {
            not_accepted.push(ii::NotAccepted {
                id: entry.id,
                recipient: entry.recipient,
                reason: ii::NotAcceptedReason::Deferred {
                    retry_after: now + HOUR,
                },
            });
        }

        let flushed = Flushed {
            sent: batch.len(),
            accepted: batch.len() - not_accepted.len(),
        };
        flush::apply(&mut self.store, batch, Outcome::Answered(not_accepted), now);
        flushed
    }

    fn dropped(&self) -> u64 {
        self.store.hours().iter().map(|bucket| bucket.dropped).sum()
    }
}

fn user(n: u64) -> Principal {
    Principal::from_slice(&n.to_be_bytes())
}

fn message(key: &str, urgency: Option<Urgency>) -> Notification {
    let mut notification = Notification::new("New message", "hello").key(key);
    notification.urgency = urgency;
    notification
}

#[test]
fn a_small_group_of_active_people_is_one_call() {
    let mut world = World::new(1_000);
    for i in 0..5 {
        world.reachable(user(i));
    }

    for i in 1..5 {
        world.send(user(i), message("chat-room", None), HOUR);
    }

    let flushed = world.flush(HOUR);
    assert_eq!((flushed.sent, flushed.accepted), (4, 4));
    assert_eq!(world.store.backlog(), 0);
}

#[test]
fn a_dormant_group_costs_refusals_once() {
    let mut world = World::new(10_000);
    for i in 0..50 {
        world.reachable(user(i));
    }

    for i in 0..1_000 {
        world.send(user(i), message("chat-big", None), HOUR);
    }
    let first = world.flush(HOUR);
    assert_eq!((first.sent, first.accepted), (1_000, 50));

    // Second message, same conversation, while 950 entries sit parked: the
    // repeat updates them rather than queueing another attempt.
    for i in 0..1_000 {
        world.send(user(i), message("chat-big", None), 2 * HOUR);
    }
    let second = world.flush(2 * HOUR);
    assert_eq!((second.sent, second.accepted), (50, 50));
}

#[test]
fn a_campaign_and_the_chat_share_every_batch() {
    let mut world = World::new(10_000);
    for i in 0..200 {
        world.reachable(user(i));
    }

    for i in 0..100 {
        world.send(
            user(i),
            message(&format!("campaign-{i}"), Some(Urgency::VeryLow)),
            HOUR,
        );
    }
    for i in 100..200 {
        world.send(
            user(i),
            message(&format!("chat-{i}"), Some(Urgency::High)),
            HOUR,
        );
    }

    world.store.promote(HOUR);
    let batch = world.store.take(15);
    let urgent = batch.iter().filter(|entry| entry.lane == 0).count();

    // Weights are 8 : 4 : 2 : 1, so a fifteen-entry batch is mostly urgent —
    // and the campaign still moves.
    assert_eq!((urgent, batch.len() - urgent), (14, 1));
}

#[test]
fn deferral_is_not_refusal() {
    let mut world = World::new(2);
    for i in 0..5 {
        world.reachable(user(i));
    }
    for i in 0..5 {
        world.send(user(i), message(&format!("m-{i}"), None), HOUR);
    }

    assert_eq!(world.flush(HOUR).accepted, 2);
    assert_eq!(world.store.backlog(), 3);
    assert_eq!(world.flush(HOUR + 60).sent, 0, "not due yet");

    world.room_per_flush = 10;
    let second = world.flush(2 * HOUR);
    assert_eq!((second.sent, second.accepted), (3, 3));
    assert_eq!(world.store.backlog(), 0);
}

#[test]
fn a_second_refusal_drops_the_notification_and_its_content() {
    let mut world = World::new(10);
    world.no_channel(user(0));

    let mut notification = message("m", None);
    notification.expires_at = Some(2 * HOUR);
    world.send(user(0), notification, HOUR);

    assert_eq!(world.flush(HOUR).accepted, 0);
    assert_eq!(world.store.backlog(), 1);

    let second = world.flush(2 * HOUR - 1);
    assert_eq!((second.sent, second.accepted), (1, 0));
    assert_eq!(world.store.backlog(), 0);
    assert_eq!(world.dropped(), 1);
}

#[test]
fn accepted_content_is_kept_until_it_expires() {
    let mut world = World::new(10);
    world.reachable(user(0));
    world.send(user(0), message("kept", None), HOUR);
    world.flush(HOUR);

    let id = identity_notifications::internal::ids::keyed(user(0), "kept");
    assert_eq!(
        world.store.content_of(id).map(|content| content.title),
        Some("New message".to_string())
    );
}

#[test]
fn a_batch_refused_as_too_large_is_not_lost() {
    let mut world = World::new(10_000);
    for i in 0..10 {
        world.reachable(user(i));
        world.send(user(i), message(&format!("m-{i}"), None), HOUR);
    }

    world.store.promote(HOUR);
    let batch = world.store.take(10);
    flush::apply(&mut world.store, batch, Outcome::TooMany(4), HOUR);
    assert_eq!(world.store.backlog(), 10);

    world.batch_limit = 4;
    let first = world.flush(HOUR);
    assert_eq!((first.sent, first.accepted), (4, 4));
    assert_eq!(world.store.backlog(), 6);
}

#[test]
fn a_call_that_never_lands_keeps_the_notification() {
    let mut world = World::new(10);
    world.reachable(user(0));

    let mut notification = message("m", None);
    notification.expires_at = Some(3 * HOUR);
    world.send(user(0), notification, HOUR);

    world.store.promote(HOUR);
    let batch = world.store.take(10);
    flush::apply(&mut world.store, batch, Outcome::Unreachable, HOUR);

    assert_eq!(world.store.backlog(), 1);
    assert_eq!(world.flush(HOUR + 60).sent, 0);
    assert_eq!(world.flush(3 * HOUR - 1).accepted, 1);
}

#[test]
fn an_upgrade_serialises_nothing_and_loses_nothing() {
    let manager = Box::leak(Box::new(MemoryManager::init(DefaultMemoryImpl::default())));
    let id = identity_notifications::internal::ids::keyed(user(0), "pending");

    {
        let mut store = Store::new(manager, 0);
        store.add(
            user(0),
            message("pending", None),
            HOUR + 24 * HOUR,
            CAPACITY,
            HOUR,
        );
        store.record(HOUR, Event::Sent, 1);
    }

    // The same memories, a fresh handle: what a post_upgrade does.
    let reopened = Store::new(manager, 0);
    assert!(reopened.content_of(id).is_some(), "content survives");
    assert_eq!(reopened.backlog(), 1, "the outbox survives");
    assert_eq!(reopened.hours().len(), 1, "metrics survive");
}
