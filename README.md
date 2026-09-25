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
use ic_cdk::{init, post_upgrade, update};
use ic_stable_structures::memory_manager::{MemoryId, MemoryManager};
use ic_stable_structures::DefaultMemoryImpl;
use identity_notifications as notifications;
use identity_notifications::Notification;

// The two endpoints Internet Identity calls. Nothing else to wire up.
notifications::endpoints!();

thread_local! {
    static MEMORIES: RefCell<MemoryManager<DefaultMemoryImpl>> =
        RefCell::new(MemoryManager::init(DefaultMemoryImpl::default()));
}

// The library's memories, named one by one: what it costs you is visible, and
// a version that needs another one will not compile against this.
const NOTIFICATION_MEMORIES: [MemoryId; notifications::MEMORIES] =
    [MemoryId::new(10), MemoryId::new(11), MemoryId::new(12), MemoryId::new(13), MemoryId::new(14)];

#[init]
#[post_upgrade]
fn init() {
    MEMORIES.with_borrow(|manager| notifications::init(manager, NOTIFICATION_MEMORIES));
}

#[update]
fn send_message(to: candid::Principal, text: String) {
    // ... store the message ...

    notifications::send(
        to,
        Notification::new("New message", text)
            .url("https://chat.example.com/chats")
            // Names what this is about, so the next message updates this
            // notification instead of stacking another one beside it.
            .key("chat-alice"),
    );
}
```

Two more calls, and that is the whole surface:

```rust
notifications::dismiss(recipient, "chat-alice"); // no longer needs attention
notifications::metrics();                        // the pipeline, hour by hour
```

Two environment variables configure it, and nothing else:

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
