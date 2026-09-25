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
            url: Some(format!("https://chat.example.com/chats/{from}")),
            key: Some(format!("chat-{from}")),
            ..Default::default()
        },
    );
}
```

The `url` opens the conversation and the `key` names it, so the next message
from `from` replaces that notification instead of stacking another beside it.

Two more calls complete the surface:

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
        notification_sender:      "rdmx6-jaaaa-aaaaa-aaadq-cai"   # Internet Identity
        notification_origin:      "https://your-app.icp0.io"
        notification_capacity_mb: "1024"   # optional
```

## Upgrades

Nothing to do beyond calling `init` again. The outbox, the content a channel
may still pull, the hourly metrics and the learned batch limit live in the
stable memories you hand over, so an upgrade neither serialises nor restores
any of it — and `init` arms a flush again if anything was still waiting, since
timers do not survive an upgrade either.

## Development

```
cargo test
```

See [CONTRIBUTING.md](CONTRIBUTING.md). `examples/chat` is a chat canister with
one-to-one and group conversations, built as part of CI.
