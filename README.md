# identity-notifications

Notify Internet Identity users from a Motoko canister. One call to send; the
library handles ids, batching, retries, the content Internet Identity pulls
back, and the delivery metrics.

**Status: implemented, not yet released.** [DESIGN.md](DESIGN.md) is the design
it follows. The Rust sibling lives in
[rust-identity-notifications](https://github.com/dfinity/rust-identity-notifications).

## Using it

```motoko
import Notifications "mo:identity-notifications";
import Principal "mo:core/Principal";

persistent actor {
  include Notifications<system>();

  public shared ({ caller }) func sendMessage(to : Principal, text : Text) : async () {
    // ... store the message ...

    notifications.send<system>(
      to,
      {
        title = "New message";
        body = text;
        url = ?("https://chat.example.com/chats/" # Principal.toText(caller));
        key = ?("chat-" # Principal.toText(caller));
        urgency = null;
        expiresAt = null;
      },
    )
  };
};
```

The `url` opens the conversation and the `key` names it, so the next message
from that sender replaces the notification instead of stacking another beside
it.

The rest of the surface:

```motoko
notifications.dismiss(recipient, "chat-" # Principal.toText(sender));  // no longer needed
notifications.metrics();                         // the pipeline, hour by hour
notifications.resume<system>();                  // after an upgrade, see below
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

The library's state is stable: the outbox, the content a channel may still
pull, the hourly metrics and the learned batch limit all survive. Its timer
does not, because no Motoko timer does, so an actor that may be upgraded with
notifications still waiting calls `resume`:

```motoko
system func postupgrade() {
  notifications.resume<system>()
};
```

Without it a waiting outbox goes out with the next `send` instead.

## Development

```
mops install
mops test
```

See [CONTRIBUTING.md](CONTRIBUTING.md) and [Releasing.md](Releasing.md).
`demo/chat` is a chat canister with one-to-one and group conversations.
