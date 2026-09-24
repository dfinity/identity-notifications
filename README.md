# identity-notifications

Notify Internet Identity users from a Motoko canister. One call to send; the
library handles ids, batching, retries, the content Internet Identity pulls
back, and the delivery metrics.

**Status: design, no implementation yet.** [DESIGN.md](DESIGN.md) is the
current design and is where discussion happens.

## What it will look like

```motoko
import Notifications "mo:identity-notifications";

persistent actor {
  include Notifications<system>();

  public shared func ping(recipient : Principal) : async () {
    notifications.send(recipient, {
      title = "Ping"; body = "Someone pinged you";
      url = null; key = null; urgency = null; expiresAt = null;
    });
  };
};
```

Two environment variables configure it, and nothing else:

```yaml
canisters:
  - name: backend
    settings:
      environment_variables:
        internet_identity:        "rdmx6-jaaaa-aaaaa-aaadq-cai"
        notification_origin:      "https://your-app.icp0.io"
        notification_capacity_mb: "64"
```

## Development

```
mops install
mops test
```

See [CONTRIBUTING.md](CONTRIBUTING.md) and [Releasing.md](Releasing.md).
