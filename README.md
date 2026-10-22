# identity-notifications

Notify Internet Identity users from your canister. One call to send; the
library handles the ids, the batching, the retries, the content Internet
Identity pulls back, and the delivery metrics.

Motoko:

```motoko
notifications.send<system>(
  recipient,
  {
    title = "New message";
    body = text;
    url = ?("https://chat.example.com/chats/" # caller.toText());
    key = ?("chat-" # caller.toText());
    urgency = null;
    expiresAt = null;
    funnel = null;
  },
);
```

Rust:

```rust
notifications::send(
    recipient,
    Notification {
        title: "New message".into(),
        body: text,
        url: Some(format!("https://chat.example.com/chats/{from}")),
        key: Some(format!("chat-{from}")),
        ..Default::default()
    },
);
```

- **[motoko/](motoko/README.md)** — the Mops package, for a Motoko canister.
- **[rust/](rust/README.md)** — the crate, for a Rust canister.

Same surface, same behaviour. See [CONTRIBUTING.md](CONTRIBUTING.md) and
[Releasing.md](Releasing.md).
