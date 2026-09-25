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
        // The conversation they will land in, on your own origin.
        url = ?("https://chat.example.com/chats/" # Principal.toText(caller));
        // The same conversation, named: the next message from this sender
        // updates this notification instead of stacking another beside it.
        key = ?("chat-" # Principal.toText(caller));
        urgency = null;
        expiresAt = null;
      },
    )
  };
};
```

Two more calls, and that is the whole app-facing surface:

```motoko
notifications.dismiss(recipient, "chat-" # Principal.toText(sender));  // no longer needed
notifications.metrics();                         // the pipeline, hour by hour
```

Types come from their own module, since a mixin exports members rather than
types:

```motoko
import Types "mo:identity-notifications/Types";
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

## Development

```
mops install
mops test
```

See [CONTRIBUTING.md](CONTRIBUTING.md) and [Releasing.md](Releasing.md).
