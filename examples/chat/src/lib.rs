//! A chat canister, to show what using the library looks like from outside:
//! one-to-one conversations and groups, and three calls into the library.

use candid::{CandidType, Principal};
use ic_cdk::{init, post_upgrade, pre_upgrade, query, update};
use identity_notifications as notifications;
use identity_notifications::{Metrics, Notification};
use serde::{Deserialize, Serialize};
use std::cell::RefCell;
use std::collections::HashMap;

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

thread_local! {
    static CHATS: RefCell<HashMap<String, Conversation>> = RefCell::default();
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
    let caller = ic_cdk::api::msg_caller();
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
    let caller = ic_cdk::api::msg_caller();
    let id = direct_id(caller, to);

    CHATS.with_borrow_mut(|chats| {
        chats.entry(id.clone()).or_insert_with(|| Conversation {
            members: vec![caller, to],
            messages: Vec::new(),
        });
    });

    post(&id, caller, text);
}

#[update]
fn send_to_group(id: String, text: String) {
    post(&id, ic_cdk::api::msg_caller(), text);
}

/// Everyone in the conversation except the sender hears about it, and the
/// conversation is what the notification is about — so the next message
/// updates that notification rather than adding another beside it.
fn post(id: &str, from: Principal, text: String) {
    let members = CHATS.with_borrow_mut(|chats| {
        let Some(conversation) = chats.get_mut(id) else {
            return Vec::new();
        };
        conversation.messages.push(Message {
            from,
            text: text.clone(),
            at: ic_cdk::api::time(),
        });
        conversation.members.clone()
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
    let caller = ic_cdk::api::msg_caller();

    let newest = CHATS.with_borrow(|chats| {
        chats
            .get(&id)
            .and_then(|conversation| conversation.messages.last())
            .map(|message| message.at)
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
            .map(|conversation| conversation.messages.clone())
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
fn init() {}

/// The app's own state and the library's, saved together. Skipping the
/// library's half would leave pending notifications without content, so a
/// channel would pull and find nothing.
type Saved = (Vec<(String, Conversation)>, notifications::Snapshot);

#[pre_upgrade]
fn pre_upgrade() {
    let chats = CHATS.with_borrow(|chats| {
        chats
            .iter()
            .map(|(id, conversation)| (id.clone(), conversation.clone()))
            .collect::<Vec<_>>()
    });
    ic_cdk::storage::stable_save((chats, notifications::snapshot()))
        .expect("stable_save should fit");
}

#[post_upgrade]
fn post_upgrade() {
    if let Ok((chats, snapshot)) = ic_cdk::storage::stable_restore::<Saved>() {
        CHATS.with_borrow_mut(|store| store.extend(chats));
        notifications::restore(snapshot);
    }
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
