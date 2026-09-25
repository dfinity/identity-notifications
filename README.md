# identity-notifications

Notify Internet Identity users from a Rust canister. One call to send; the
library handles ids, batching, retries, the content Internet Identity pulls
back, and the delivery metrics.

**Status: implemented, not yet released.** [DESIGN.md](DESIGN.md) is the design
it follows. The Motoko sibling lives in
[motoko-identity-notifications](https://github.com/dfinity/motoko-identity-notifications).

## Using it

```toml
[dependencies]
identity-notifications = "0.1"
```

```rust
use candid::Principal;
use ic_cdk::api::msg_caller;
use ic_cdk::{init, post_upgrade, update};
use ic_stable_structures::memory_manager::{MemoryId, MemoryManager};
use ic_stable_structures::DefaultMemoryImpl;
use identity_notifications as notifications;
use identity_notifications::{Memories, Notification};
use std::cell::RefCell;

// The two endpoints Internet Identity calls. Nothing else to wire up.
notifications::endpoints!();

thread_local! {
    static MEMORIES: RefCell<MemoryManager<DefaultMemoryImpl>> =
        RefCell::new(MemoryManager::init(DefaultMemoryImpl::default()));
}

#[init]
#[post_upgrade]
fn init() {
    // Which memory each part of the library gets. Named rather than counted,
    // so what you are handing over is right here — and a version that needs
    // another memory adds a field, which stops this compiling instead of
    // quietly taking an id you were already using.
    MEMORIES.with_borrow(|manager| {
        notifications::init(
            manager,
            Memories {
                entries: MemoryId::new(10),
                content: MemoryId::new(11),
                metrics: MemoryId::new(12),
            },
        )
    });
}

#[update]
fn send_message(to: Principal, text: String) {
    let from = msg_caller();
    // ... store the message ...

    notifications::send(
        to,
        Notification {
            title: "New message".into(),
            body: text,
            // The conversation they will land in, on your own origin.
            url: Some(format!("https://chat.example.com/chats/{from}")),
            // The same conversation, named: the next message from `from`
            // updates this notification instead of stacking another beside it.
            key: Some(format!("chat-{from}")),
            ..Default::default()
        },
    );
}
```

Two more calls, and that is the whole app-facing surface:

```rust
notifications::dismiss(recipient, &format!("chat-{from}")); // no longer needs attention
notifications::metrics();                        // the pipeline, hour by hour
```

Configuration is three environment variables, one of them optional:

```yaml
canisters:
  - name: backend
    settings:
      environment_variables:
        internet_identity:        "rdmx6-jaaaa-aaaaa-aaadq-cai"
        notification_origin:      "https://your-app.icp0.io"
        notification_capacity_mb: "1024"   # optional
```

## Upgrades

Nothing to do beyond calling `init` again. Everything the library keeps —
the outbox, the content a channel may still pull, the hourly metrics, the
learned batch limit — lives in the stable memories you handed it, so an upgrade
neither serialises nor restores any of it. A canister holding a campaign's
worth of pending notifications upgrades as fast as an idle one, and
`pre_upgrade` has nothing to run out of instructions doing.

## What it does for you

Coalesces two seconds of sends into one call, and skips the wait for
`Urgency::High`. Drains four lanes by urgency in weighted cycles, so a
million-recipient campaign cannot starve a chat and the chat cannot starve the
campaign. Learns Internet Identity's batch limit from its refusal rather than
hardcoding one. Parks a refused notification until just before it expires and
tries once more, which gives the user the whole window to sign in or turn
notifications on. Keeps a month of hourly delivery buckets. Sheds the outbox
rather than anything Internet Identity has already accepted, because a pull has
to find content.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md). `examples/chat` is a chat canister with
one-to-one and group conversations, built as part of CI.
