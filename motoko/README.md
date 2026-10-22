# identity-notifications

Notify Internet Identity users from a Motoko canister. One call to send; the
library handles ids, batching, retries, the content Internet Identity pulls
back, and the delivery metrics. For Rust, see
[identity-notifications on crates.io](https://crates.io/crates/identity-notifications).

## Using it

Requires moc 2.0.0 or later.

```motoko
import Notifications "mo:identity-notifications";
import Principal "mo:core/Principal";

actor {
  include Notifications<system>();

  public shared ({ caller }) func sendMessage(to : Principal, text : Text) : async () {
    // ... store the message ...

    notifications.send<system>(
      to,
      {
        title = "New message";
        body = text;
        url = ?("https://chat.example.com/chats/" # caller.toText());
        key = ?("chat-" # caller.toText());
        urgency = null;
        expiresAt = null;
        funnel = null;
      },
    )
  };
};
```

The `url` opens the conversation and the `key` names it, so the next message
from that sender replaces the notification instead of stacking another beside
it.

Two more calls complete the surface:

```motoko
notifications.dismiss(recipient, "chat-" # sender.toText());  // no longer needed
notifications.metrics();                         // the pipeline, hour by hour
```

Types come from their own module:

```motoko
import Types "mo:identity-notifications/Types";
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

Nothing to do. The library's state is stable — the outbox, the content a
channel may still pull, the hourly metrics and the learned batch limit — and
the mixin arms its own flush again on the way back up, since no Motoko timer
survives an upgrade.

## Development

```
mops install
mops test
```

See [CONTRIBUTING.md](https://github.com/dfinity/identity-notifications/blob/main/CONTRIBUTING.md) and [Releasing.md](https://github.com/dfinity/identity-notifications/blob/main/Releasing.md).
`demo/chat` is a chat canister with one-to-one and group conversations.
