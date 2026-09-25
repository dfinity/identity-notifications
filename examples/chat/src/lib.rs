//! A chat canister, to show what using the library looks like from outside:
//! one-to-one conversations and groups, and three calls into the library.

use candid::{CandidType, Principal};
use ic_cdk::api::{msg_caller, time};
use ic_cdk::{init, post_upgrade, query, update};
use ic_stable_structures::memory_manager::{MemoryId, MemoryManager, VirtualMemory};
use ic_stable_structures::storable::Bound;
use ic_stable_structures::{DefaultMemoryImpl, StableBTreeMap, Storable};
use identity_notifications as notifications;
use identity_notifications::{Memories, Metrics, Notification};
use serde::{Deserialize, Serialize};
use std::borrow::Cow;
use std::cell::RefCell;

type Memory = VirtualMemory<DefaultMemoryImpl>;

/// This app's conversations. The library's memories are named where it is
/// handed them, below.
const CHATS_MEMORY: MemoryId = MemoryId::new(0);

// The two endpoints Internet Identity calls. Nothing else to wire up.
notifications::endpoints!();

#[derive(Clone, CandidType, Serialize, Deserialize)]
struct Message {
    from: Principal,
    text: String,
    at: u64,
}

#[derive(Clone, Default, CandidType, Serialize, Deserialize)]
struct Conversation {
    members: Vec<Principal>,
    messages: Vec<Message>,
}

impl Storable for Conversation {
    const BOUND: Bound = Bound::Unbounded;

    fn to_bytes(&self) -> Cow<'_, [u8]> {
        Cow::Owned(candid::encode_one(self).expect("candid encoding"))
    }

    fn into_bytes(self) -> Vec<u8> {
        candid::encode_one(&self).expect("candid encoding")
    }

    fn from_bytes(bytes: Cow<[u8]>) -> Self {
        candid::decode_one(bytes.as_ref()).expect("candid decoding")
    }
}

thread_local! {
    static MEMORIES: RefCell<MemoryManager<DefaultMemoryImpl>> =
        RefCell::new(MemoryManager::init(DefaultMemoryImpl::default()));

    static CHATS: RefCell<StableBTreeMap<String, Conversation, Memory>> = RefCell::new(
        StableBTreeMap::init(MEMORIES.with_borrow(|manager| manager.get(CHATS_MEMORY))),
    );
}

/// One-to-one conversations are named by their two members, so both sides
/// arrive at the same one.
fn direct_id(a: Principal, b: Principal) -> String {
    let (first, second) = if a < b { (a, b) } else { (b, a) };
    format!("{first}|{second}")
}

#[update]
fn create_group(name: String, members: Vec<Principal>) -> String {
    let id = format!("group:{name}");
    let caller = msg_caller();
    let mut members = members;
    if !members.contains(&caller) {
        members.push(caller);
    }

    CHATS.with_borrow_mut(|chats| {
        chats.insert(
            id.clone(),
            Conversation {
                members,
                messages: Vec::new(),
            },
        )
    });
    id
}

#[update]
fn send_direct(to: Principal, text: String) {
    let caller = msg_caller();
    let id = direct_id(caller, to);

    CHATS.with_borrow_mut(|chats| {
        if !chats.contains_key(&id) {
            chats.insert(
                id.clone(),
                Conversation {
                    members: vec![caller, to],
                    messages: Vec::new(),
                },
            );
        }
    });

    post(&id, caller, text);
}

#[update]
fn send_to_group(id: String, text: String) {
    post(&id, msg_caller(), text);
}

/// Everyone in the conversation except the sender hears about it, and the
/// conversation is what the notification is about — so the next message
/// updates that notification rather than adding another beside it.
fn post(id: &str, from: Principal, text: String) {
    let members = CHATS.with_borrow_mut(|chats| {
        let Some(mut conversation) = chats.get(&id.to_string()) else {
            return Vec::new();
        };
        conversation.messages.push(Message {
            from,
            text: text.clone(),
            at: time(),
        });
        let members = conversation.members.clone();
        chats.insert(id.to_string(), conversation);
        members
    });

    for member in members.into_iter().filter(|member| *member != from) {
        notifications::send(
            member,
            Notification::new(title(id, from), text.clone())
                .url(format!("https://chat.example.com/c/{id}"))
                .key(id),
        );
    }
}

/// Read state is a marker: it moves forward as they read and back when they
/// mark something unread again. The notification is stale only once nothing in
/// the conversation is unread.
#[update]
fn mark_read(id: String, up_to: u64) {
    let caller = msg_caller();

    let newest = CHATS.with_borrow(|chats| {
        chats
            .get(&id)
            .and_then(|conversation| conversation.messages.last().map(|message| message.at))
    });

    if newest.is_some_and(|newest| up_to >= newest) {
        notifications::dismiss(caller, &id);
    }
}

#[query]
fn messages(id: String) -> Vec<Message> {
    CHATS.with_borrow(|chats| {
        chats
            .get(&id)
            .map(|conversation| conversation.messages)
            .unwrap_or_default()
    })
}

/// A month of hourly buckets in one reply — some 30KB, so a dashboard takes the
/// lot and slices it client-side.
#[query]
fn delivery_metrics() -> Metrics {
    notifications::metrics()
}

fn title(id: &str, from: Principal) -> String {
    if id.starts_with("group:") {
        format!("{id} · {from}")
    } else {
        from.to_string()
    }
}

#[init]
fn init() {
    open_notifications();
}

/// Nothing to save and nothing to restore: both this app's conversations and
/// the library's state are already in stable memory. All an upgrade needs is
/// the handle back.
#[post_upgrade]
fn post_upgrade() {
    open_notifications();
}

/// Which memory each part of the library gets. Ids 1 to 5 are its; this app
/// keeps out of them.
fn open_notifications() {
    MEMORIES.with_borrow(|manager| {
        notifications::init(
            manager,
            Memories {
                outbox: MemoryId::new(1),
                parked: MemoryId::new(2),
                content: MemoryId::new(3),
                metrics: MemoryId::new(4),
                counters: MemoryId::new(5),
            },
        )
    });
}

ic_cdk::export_candid!();

#[cfg(test)]
mod tests {
    /// Writes `chat.did` beside the crate, so the interface in the repo is the
    /// one the code exports rather than one somebody hand-edited.
    #[test]
    fn candid_is_up_to_date() {
        let exported = super::__export_service();
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("chat.did");

        if std::env::var("BLESS").is_ok() {
            std::fs::write(&path, &exported).expect("writing chat.did");
        }

        let committed = std::fs::read_to_string(&path).expect("chat.did should exist");
        assert_eq!(
            committed.trim(),
            exported.trim(),
            "chat.did is stale — rerun with BLESS=1"
        );
    }
}
