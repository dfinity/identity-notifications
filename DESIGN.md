# motoko-identity-notifications — design

A Motoko library for apps that notify their users through Internet Identity.
One call to send; the library owns everything else, including the canister
method Internet Identity's service worker calls to fetch the content.

Modelled on `dfinity/motoko-identity-attributes`: a `mixin` the app `include`s,
internals under `src/Internal/`, trust configured through canister environment
variables rather than code, published on mops. That library is the shape to
copy, not a dependency. The only shared dependency is `mo:core`.

## What the app writes

An `include` with nothing to configure, a `send`, a `dismiss`, and — where the
app wants to nudge someone — a question it can ask:

```motoko
import Notifications "mo:identity-notifications";
import Principal     "mo:core/Principal";
import List          "mo:core/List";
import Map           "mo:core/Map";
import Time          "mo:core/Time";

persistent actor {

  type Message = { from : Principal; text : Text; at : Time.Time };

  // One conversation per pair of people, keyed the same way from either side.
  let conversations = Map.empty<Text, List.List<Message>>();
  let latestAt      = Map.empty<Text, Time.Time>();          // newest message
  let readUpTo      = Map.empty<Text, Time.Time>();          // per reader

  func conversationId(a : Principal, b : Principal) : Text {
    let x = Principal.toText(a);
    let y = Principal.toText(b);
    if (x < y) x # "|" # y else y # "|" # x;
  };

  include Notifications<system>();

  public shared ({ caller }) func sendMessage(to : Principal, text : Text) : async () {
    let id = conversationId(caller, to);
    let messages = switch (conversations.get(id)) { case (?m) m; case null List.empty() };
    let at = Time.now();
    messages.add({ from = caller; text; at });
    conversations.add(id, messages);
    latestAt.add(id, at);

    notifications.send(to, {
      title     = Principal.toText(caller);
      body      = text;
      url       = ?("https://chat.example.com/chat/" # Principal.toText(caller));
      // The conversation is what this notification is about, so a second
      // message updates the first instead of stacking beside it.
      key       = ?id;
      urgency   = null;
      expiresAt = null;
    });
  };

  // Read state is a marker, not a flag: it moves forward as they read and back
  // when they mark something unread again.
  public shared ({ caller }) func markRead(peer : Principal, upTo : Time.Time) : async () {
    let id = conversationId(caller, peer);
    readUpTo.add(Principal.toText(caller) # "@" # id, upTo);

    // Stale only once nothing is left unread. Reading half a conversation
    // leaves the notification alone, which is what the user asked for by
    // stopping.
    let newest = switch (latestAt.get(id)) { case (?at) at; case null 0 };
    if (upTo >= newest) notifications.dismiss(caller, id);
  };

  // A month of hourly buckets in one reply — some 30KB, so a dashboard takes
  // the lot and slices it client-side.
  public query func deliveryMetrics() : async Notifications.Metrics {
    notifications.metrics();
  };
};
```

The conversation id is the whole integration: it is what the app already uses to
find the messages, what makes a second message replace the first notification
rather than stack, and what `dismiss` names once they have read all of it somewhere.
Reading the messages is a plain query with nothing from the library in it, so it
is left out of the example entirely.

Marking unread again is the case worth stating: nothing resurrects the
notification. The content is gone and the tray entry with it, and sending a
fresh one because someone flagged a message to come back to would be a
notification they did not ask for. Unread state belongs to the app's own badge
from that point on.
The same key from both sides is fine, because a notification id derives from
`(recipient, key)` and the recipients differ.

There are no handlers to implement and no library state for the app to keep.
Everything that can go wrong is either the library's to absorb — parking a
refused notification until its expiry, backing off a saturated origin — or
something the app reads when it wants it, from `metrics`.

### A refusal parks the notification until its expiry

Two refusals mean nothing will reach this account right now: `NoSuchRecipient`
(II holds no record for it, typically because the user has not signed in to the
app in long enough) and `NoChannel` (they have no channel enabled). Both are
fixed by the user — signing in, or turning notifications on — and neither is
fixed by trying again a second later.

So the entry is not dropped. Its next attempt is set to just before its own
expiry and it goes back in the queue, which already orders by expiry, so it
surfaces at the right moment with no timer and no bookkeeping of its own. The
user has the whole window to come back, and if they do, they get the
notification rather than nothing.

Every notification therefore gets at most two attempts: one when it is sent and
one near its expiry. If the second fails it is dropped and counted in the
bucket's `dropped`. Cost is bounded by what the app sends, not by how many dead
recipients it has.

The dormant group chat falls out of this for free. Each dead member holds one
parked entry per conversation key, and every later message for that key
*replaces* the parked entry instead of queueing another attempt — so the first
message to a group of ten thousand mostly-dead members costs ten thousand
refusals, and every message after it costs none.

There is no per-recipient state anywhere in this: no suppression table, no
backoff, no probes, and nothing for the app to call when a user comes back. An
earlier draft had all four, plus an `active(recipient)` the app was expected to
sprinkle through its own methods. Parking the entry it already holds does the
same work with none of it.

### One injected name

`include` injects the mixin's declarations into the actor, and bare names would
land in the app's own namespace — `send`, `delivery`, whatever came later —
where they collide with the app's functions and cannot be renamed by the app.
So the mixin injects exactly one:

```motoko
notifications.send(recipient, notification)      // send, or update by key
notifications.dismiss(recipient, key)            // no longer needs attention
notifications.metrics()                          // the delivery pipeline, hour by hour
```

It is `transient`: an object with methods is not a stable type, so it is
rebuilt by the mixin body on every install and upgrade, closing over the stable
fields that hold the actual state. Nothing is lost, because the object holds
nothing.

The two canister methods II calls carry the `_internet_identity_` prefix
instead, which keeps them out of the app's namespace and marks them as
not-the-app's to call.

### Why the state can stay inside the mixin

A mixin has its own stable fields — `--enhanced-migration` type-checks them
across upgrades like any other actor field — so the library keeps its state
where it belongs and the app never sees it. The one constraint is that the
fields must have *stable types*: plain records, `Map`, `List`, no class
instances and no function values. identity-attributes keeps its nonce store
`transient` because `Challenges.empty()` returns a class instance, not because
a mixin cannot persist; our state is plain data, so it persists.

This matters more here than it does there. A 5-minute nonce can be lost on
upgrade and the frontend simply retries. Notification content cannot: if it were
lost, the worker would pull and find nothing, the user would see a notification
whose body never loads, and Internet Identity would still be holding the entry.

### Configuration

```yaml
environment_variables:
  internet_identity:   "rdmx6-jaaaa-aaaaa-aaadq-cai"    # required
  notification_origin: "https://your-app.icp0.io"       # required
```

`internet_identity` is the principal whose pulls the canister answers. It has to
be configuration rather than a constant because the local replica, staging and
mainnet all have different ones.

`notification_origin` is the one origin this canister notifies for, and it is
always required. Reusing `frontend_origins` was tempting and wrong: it is a
comma-separated set, which suits attribute bundles where any listed origin is
acceptable, while `app_send_notification` takes exactly one. An app is normally
reachable on `<canister>.ic0.app`, `<canister>.icp0.io` and a custom domain, so
that set usually has several entries and nothing in it says which one to notify
for. II cannot infer it either — a canister may serve more than one origin.

Two details that follow from II's own handling:

- **Compare folded, not literal.** II folds a gateway twin to the legacy
  spelling before keying anything, so the origin in the sender info can differ
  from the configured string. The library folds its configured origin the same
  way once and compares that.
- **Wrong origin is not a runtime error the app can fix.** If the canister is
  not in that origin's published sender list, every send returns
  `NoSuchSender`. That is a deployment mistake, so it lands in
  `metrics().misconfigured` and the outbox parks rather than spinning.

## State

Declared by the mixin, invisible to the app:

```motoko
var nextId     : Nat64;                              // keyless ids, top bit clear
var pending    : Map.Map<(Principal, Nat64), Content>;
var outbox     : List.List<Queued>;
var batchLimit : ?{ value : Nat; learnedAt : Time.Time };
```

`pending` holds content a channel may still pull. `outbox` holds what II has
not accepted yet. `batchLimit` is what II last told us, and being stable it
survives upgrades.

### Keys map to ids without a map

There is no `(recipient, key) -> id` table. The id is derived:

```
keyed:    id = 1 ‖ lower 63 bits of sha256(recipient ‖ key)
keyless:  id = 0 ‖ nextId++
```

A table would have to be evicted or grow forever, and both are wrong: evicting
it turns the next update into a new tray entry instead of a replacement, while
keeping it means one entry per `(recipient, key)` the app has ever used. Deriving
the id has neither problem — the same key yields the same id after an upgrade,
after the content has expired and been swept, and after the app has forgotten
it ever sent anything.

The top bit separates the derived space from the counter so the two cannot
collide. Inside the derived space it is 63 bits per `(origin, recipient)`: a
recipient holding a thousand live notifications from one app collides with
probability around 5e-14. Ids being guessable costs nothing, because a pull is
authorised by the account in the sender info, not by knowing an id.

This costs a `sha2` dependency. `Prim.hashBlob` is 32 bits, which collides at
about one percent for the same thousand notifications — often enough that one
user's order update would silently overwrite another notification of theirs.

## Sending

`send` appends to the outbox and, if no flush is pending, arms one two
seconds out. Everything that arrives in the meantime rides along.

Two seconds is chosen against how the IC executes, not against how long a user
will wait. The floor is already a round: the timer callback is a message in the
canister's own queue, so it cannot run until the current message finishes and it
queues behind whatever else is pending, which means even `#seconds 0` batches
everything the canister executed that round. What the window buys is a few
rounds of accumulation, taking this canister's call rate against II to roughly
one call per two to four rounds — the number that matters once thousands of app
canisters are doing the same thing.

It also self-throttles. The flush competes with app messages in the same queue,
so under load it lands late, the batch grows, and the call rate falls exactly
when the canister is busiest. Load cannot increase the rate of calls at II.

Three things cut the wait short or hold it open:

- **A full batch flushes immediately.** A fan-out that fills the batch limit
  does not sit waiting for the window.
- **`urgency = #High` flushes immediately.** An app that says something is
  urgent should not have it held for two seconds by a library.
- **One flush is in flight at a time.** The next window is armed when the
  current call returns, so a slow or deferring II slows the library down
  instead of multiplying calls against it.

### Which notifications go first

A flush does not take the outbox in order. Notifications arrive with an urgency
and an expiry, and both matter: a chat message should not queue behind a
million-recipient campaign, and the campaign should not sit untouched until the
day it expires and then flood.

Four lanes, one per urgency, each ordered by soonest expiry. A batch is filled
by cycling the lanes with weights:

```
High 8 : Normal 4 : Low 2 : VeryLow 1
```

So a 1000-entry batch is roughly 533 / 267 / 133 / 67, and an empty lane donates
its turns — an app sending only campaigns still drains at full rate. Within a
lane the soonest to expire leads, so a campaign nearing its deadline at least
goes first among campaigns. Entries already past their expiry are discarded as
they are popped, not sent, because II would refuse them anyway.

Weighted lanes rather than earliest-deadline-first, deliberately. Deadline
ordering would let a week-old campaign preempt urgent traffic on the day it
expires, which inverts what urgency means. Lanes say the opposite and the
honest thing: under sustained pressure the work that expires undelivered is the
work the app itself labelled `#VeryLow`, while `#High` keeps flowing. That is
the design working rather than failing, and it is visible — the loss lands in
the bucket's `dropped`.

### The queue is its own module

The scheduler is the one piece of logic here with real edge cases — weights,
donated turns, expiry, fairness under a lane that never empties — so it lives in
`Internal/LaneQueue.mo`, generic over what it carries, and is tested without a
canister anywhere near it.

Motoko shapes the interface. State has to stay plain data to be stable, so the
queue cannot be a class holding closures over its items:

```motoko
module LaneQueue {
  public type State<T> = { lanes : [var List.List<T>] };   // plain data, stable

  public func push<T>(s : State<T>, item : T, lane : Nat, expiresAt : Time.Time) : ();
  public func take<T>(s : State<T>, weights : [Nat], count : Nat, now : Time.Time) : [T];
}
```

The lane and the deadline are passed in by the caller rather than derived by a
stored function, which is what keeps the state stable. `Outbox.mo` supplies them
from a notification's urgency and expiry, and nothing else in the library knows
how the ordering works.

### What the timer needs to hold

Four constraints from `mo:core/Timer`, all of them load-bearing:

- **Resolution is the block rate**, and the docs say to pick durations well
  above it. Two seconds is a couple of blocks, so a flush lands at two to four
  seconds in practice. That is within the point of coalescing, and `#High`
  skips the wait.
- **Timers do not survive upgrades**, so the window has to be re-established.
  The documented way is an actor initialization expression, which runs on
  install and on upgrade — and a mixin body is one. It re-arms a flush when the
  outbox came back non-empty, so no `postupgrade` hook is needed and nothing
  collides with the app's own.
- **Arming needs the `<system>` capability**, which is why the mixin body has it
  and why `<system>` has to appear on the `include`. That is the one token of
  ceremony the app cannot avoid.
- **A query cannot arm anything**, so the pull method never re-arms. Only
  `send` and the receipt method can, which is fine: an outbox that came back
  from an upgrade is armed by the initialization expression, not by traffic.

An app arming its own timers is not a problem, and most do: `Timer.setTimer`
and `recurringTimer` multiplex over the single `global_timer`, so the app and
any number of libraries coexist. Only the low-level override — declaring
`system func timer` and driving the global timer by hand — takes the mechanism
away, and that is not how apps are written. A README line, not a design
concern.

A flush chunks the outbox at the current batch limit and calls
`app_send_notification`. Because `await` splits the message — state committed
before it stays committed, and other messages run in between — entries are
marked in flight before the call and removed only once II has accepted them.
Removing them first would lose them on a failed call, and the asymmetry is
deliberate: a repeated id replaces rather than duplicates, so sending something
twice costs nothing while dropping it costs a notification. Holding to one
flush at a time also keeps the canister well clear of its outstanding-call and
queue limits.

The response drives everything:

- `Ok { not_accepted = [] }` — done, entries stay in `pending` until they expire.
- `NoSuchRecipient` / `NoChannel` — that user cannot be reached; drop the content
  and parks it until near its expiry for one more attempt.
- `Deferred { retry_after }` — keep the entry in the outbox and arm a timer for
  `retry_after`. No capacity is wasted retrying earlier.
- `Err(TooManyNotifications { limit })` — record `limit`, re-split, send again in
  the same flush. Nothing was enqueued, so the retry is safe, and because a
  repeated `(recipient, id)` replaces rather than duplicates, a retry that
  overlaps an earlier partial send is harmless.
- `Err(NoSuchSender)` — the canister is not in the origin's published sender
  list. Not retryable by the canister: recorded in `metrics().misconfigured`,
  logged once, and the outbox parks.
- `Err(InternalCanisterError)` — retry with backoff.

### The learned batch limit

A batch is whatever accumulated during the coalescing window. The limit only
matters on fan-out — notifying every member of a group, or a busy canister
whose window filled up — so these numbers decide how a 500-recipient send is
chopped up, not what a quiet app ever hits.

- **Default 1000.** II's cap is 1000 today, so the first batch of a fresh
  canister fits and costs no rejected call. A `Notification` is roughly 50
  bytes of candid, so 1000 of them is ~50KB against a 2MB argument limit: the
  wire is nowhere near the constraint, II's policy is the constraint.
- **Learned from the rejection.** `TooManyNotifications { limit }` carries the
  real number, so no version of the library hardcodes a cap that can go stale.
  Nothing was enqueued, so re-splitting and sending again is safe.
- **Probed upward once a window.** Learning only works downward: a batch that
  succeeded says nothing about whether a bigger one would have. So once per 24h
  the library tries double the learned limit, ceilinged at 10000 to keep
  building a batch from costing more than sending it. If the cap has not moved
  that is one rejected call a day, which enqueues nothing.

The limit lives in the mixin's stable state, so it survives upgrades and a
canister relearns at most once a day rather than once a deploy.

### Capacity

The library holds two things that grow: the outbox, until II accepts an entry,
and the pending content, until it expires or is dismissed. One ceiling covers
both, and it is a byte budget:

```yaml
notification_capacity_mb: "64"    # stored notifications, default 64
```

Bytes rather than a count of notifications, because bytes are what actually run
out and per-entry overhead is bytes too. Measured as stored, not capped per
field: how long a title or body may be is the app's decision, and truncating
someone's strings to fit a library's idea of a notification would be worse than
refusing to store it.

At the ceiling the oldest keyless entries go first, since keyed ones are
supersedable and more likely still wanted, and each drop is counted in the
bucket's `dropped`.

The number that matters is not the ceiling though: content stays pending until
it expires, so steady state is roughly II's retention window times the app's
send rate. A busy app sits near its ceiling permanently and should raise the
variable, which is exactly why it is one.

### One sender per origin

The id space is per `(origin, recipient)` and shared by every canister sending
for that origin, so exactly one canister may send for an origin. Deriving ids
from keys makes that sharper rather than softer, in both directions:

- **Keyed ids collide deterministically.** Two canisters sending for one origin
  derive the *same* id from the same `(recipient, key)`. If both apps use
  `"order-42"`, every notification from one replaces the other's, every time,
  not occasionally. The content each serves on pull differs too, so which text
  the user sees depends on which canister answered.
- **Keyless ids collide eventually.** Each canister counts from its own
  `nextId`, so both hand out 1, 2, 3.

It also means the pull cannot be served by whichever canister happens to
receive it: content lives in the canister that sent the notification, so a
second canister answering a pull for an id it did not send returns nothing.

So an app with a canister per entity — a canister per room, per game, per
document — funnels its notifications through one relay canister, which holds
the mixin and is the canister the origin publishes as its sender. The entity
canisters call the relay; the relay notifies and answers pulls.

### The two halves nothing checks together

Authorisation for sending is split across two canisters that cannot see each
other. The backend canister holds `notification_origin` and does the sending.
The frontend asset canister serves the origin and publishes which backend may
send for it. II is the only party that reads both, at the moment of a send.

So the library never reads the sender list, and could not usefully: it is
another canister's asset, and a backend fetching its own frontend over HTTP to
audit its own configuration would be a costly way to learn nothing. The
mismatch announces itself the only way it can — a send returns `NoSuchSender`.

There is nothing app code can do with that, since a canister cannot publish its
own frontend's asset, so it is not a callback. The library logs it and holds it
in `metrics().misconfigured` with the time it started, which is where an
operator is already looking and is enough to see that a deploy broke sending.

## Serving the pull

The mixin injects two methods, and Internet Identity picks by what the channel
needs:

```motoko
public shared query func _internet_identity_notification_content(id : Nat64) : async ?Content
public shared       func _internet_identity_notification_received(id : Nat64) : async ()
```

The query is the fast path: one round trip, nothing recorded, which is what a
worker wants with a user watching an empty notification. The update records that
the notification was delivered, and returns nothing — delivery happens after the
content has been fetched and shown, so a call that did both would be claiming
receipt for something not yet delivered. Every channel fetches, delivers, then
marks.

A receipt is also the only proof that a user has a working channel, which until now an app could only infer from a
click.

Marking is idempotent and does not evict. Several browsers can be subscribed
and each pulls independently, so a second mark records nothing new, and content
lives until it expires — dropping it on first receipt would blank the
notification on every other device the user has.

### Authorisation is the same for both

The IC has already verified the caller info before either runs; what is left is
deciding whether we trust who signed it. The library does that itself, in
`Internal/CallerInfo.mo`, rather than through `mo:core/CallerAttributes` — that
module hardcodes the `trusted_attribute_signers` env var, which is another
feature's vocabulary and another feature's trust list. The primitives
underneath it are two lines:

```motoko
import Prim "mo:⛔";

let signer = Prim.callerInfoSigner<system>();   // empty when the call carries none
let info   = Prim.callerInfoData<system>();     // II's sender_info blob
```

So both methods: read the signer, deny unless it equals the configured
`internet_identity` principal, decode the sender info, check the origin in it is
ours, and answer for `(account, id)`.

Denial is `null`, not a trap. A trap on an untrusted signer tells that caller
nothing it did not already know and turns a routine deny into a failed call; a
missing `internet_identity` variable does trap, because that is a deployment
error the operator has to see.

The caller principal is ignored entirely. It carries no authority; the account
in the sender info is the whole answer to "who is this for".

## Updating what was already sent

One way: send again with the same `key`.

```motoko
notifications.send(recipient, { title = "Order shipped"; body = "Arrives Tuesday";
                                  url = ?"https://shop.example.com/orders/42"; key = ?"order-42" });
```

The library maps `(recipient, key)` to a stable notification id, so the second
call rewrites the stored content and re-sends that id. II replaces the pending
entry, the channel replaces the tray entry, and the user sees one notification
that changed rather than two.

There is no handle and no second method. Returning a `Ref` for the app to keep
would put library state back in the app — the ceremony the mixin exists to
remove — and an app with something to update already has an id for it: the
order, the conversation, the invoice. `key` is that id, in the app's own
vocabulary. A notification about nothing in particular leaves it null, gets a
fresh id, and stands alone.

Whether the update re-alerts is the library's call, not a flag the app sets.
The condition is whether the library still holds a live, undelivered entry for
that id:

- **Live and undelivered** — rewrite the content and send nothing. The
  notification is still queued or still waiting to be delivered, so whenever a
  channel gets to it the pull returns the new text. Re-sending would be noise.
- **Anything else** — send. That covers the delivered case, where the user has
  already read the old version and needs telling that it changed; the expired
  case, where II dropped the notification and there is nothing left to update;
  and the swept case, where the content aged out of this canister. In all
  three, nothing exists to amend, so the update is a new notification under the
  same id and the same tray tag.

Sending replaces rather than stacks: II replaces a still-pending entry, and the
worker's `showNotification` under `origin:id` replaces a tray entry. So an
update the user has already seen becomes an update in place, and an update to
something long expired becomes a fresh notification — which is what it is.

Receipt is per notification, not per device. If one of a user's browsers marked
it received and another never pulled, the update is sent: the browser that saw
the old text gets the new one, and the one that never pulled gets the new text
whenever it does.

### Dismissing a notification

A notification often stops mattering before anyone reads it: the user replied
on their phone, so the copy on their laptop is stale. `dismiss` says so.

```motoko
notifications.dismiss(recipient, "conversation-42");
```

It is keyed only — a keyless notification has no name the app ever saw, so
there is nothing to address — and it does one of three things depending on how
far the notification got:

- **Still in the outbox.** Dropped outright: never sent, no push, nobody sees
  it. This is the case that matters most, because "read it on my phone two
  seconds later" is the common one, and it costs nothing.
- **Sent and pending at II.** Nothing can retract it, so the push still
  arrives. The content is gone, so the worker has nothing to show and falls
  back to generic text.
- **Delivered.** The content is gone, so the tray entry closes the next time
  the worker sweeps.

Dropping the content is the whole mechanism: a pull returns `null`, exactly as
it does for something expired. The worker needs no new vocabulary, because
"nothing to show" leads to the same action whatever the reason — fall back on
first display, close on a sweep. A failed call is a different thing entirely,
and the transport already distinguishes it from a `null` reply.

### What dismiss cannot do

It cannot clear a tray by itself. Notifications belong to II's service worker
registration, so only II's origin can enumerate or close them —
`getNotifications()` is per registration, and the app's own page has no access
to notifications shown for it. Nor is there a push that displays nothing: the
subscription is `userVisibleOnly`.

What it can do is arm a sweep. `dismiss` drops the content and asks for a send,
so II's worker wakes, closes every entry whose content has gone, and satisfies
the visibility obligation with the one it keeps. The user is left with one
notification instead of five.

### What the platforms actually do

This is where the design has to be careful, because `tag` does not behave the
way the spec describes on Apple platforms:

- **Chromium.** `tag` coalesces. Showing a notification with the tag of one
  already displayed replaces it, and does so without sound or vibration unless
  `renotify` is set. An update, and a sweep, are both silent.
- **Safari and iOS.** `tag` is not used for coalescing at all — WebKit bug
  258922, open since July 2023 and still reported failing on iOS 18.4 in July
  2026. A same-tag push produces a *second* notification. `getNotifications()`
  and `Notification.close()` were fixed, though, so the worker can do by hand
  what the tag was meant to do.

Two consequences, both for II's worker rather than this library, but both
load-bearing for what the library promises:

1. **Replacement must be explicit.** Fetch by tag, close what is there, then
   show. Relying on `tag` alone means iOS users accumulate a notification per
   update, which is the opposite of the replace semantics the send API offers.
2. **A sweep costs iOS users an alert.** Anything shown there alerts, so
   consolidating cannot be silent on iOS the way it is on Chromium. It is still
   worth doing — one alert that reduces five stale notifications to one beats
   five that sit there — but it is a real cost, and it argues for sweeping when
   there is something to consolidate rather than on every `dismiss`.

Sources: [web.dev on notification
behaviour](https://web.dev/articles/push-notifications-notification-behaviour),
[WebKit bug 258922](https://bugs.webkit.org/show_bug.cgi?id=258922),
[MDN `showNotification()`](https://developer.mozilla.org/en-US/docs/Web/API/ServiceWorkerRegistration/showNotification).

### There is no cancel

II's interface has one method, `app_send_notification`, and nothing withdraws a
pending notification, so `dismiss` is a statement about the app's own state
rather than a retraction. Retracting properly would need a method on II's side
and a channel-side signal to clear a delivered one.

## The payload

Internet Identity carries none of it. `Notification` is
`{ id; recipient; expires_at; urgency }` — a content-free signal. The app sends
that signal, II picks a channel for it, and the channel pulls the content back
out of the canister. So the content type is channel-neutral by construction:
the app says what happened, not how it should look.

```motoko
// What the app describes when it sends.
public type Notification = {
  title     : Text;        // one line, required
  body      : Text;        // a sentence or two, required
  url       : ?Text;       // where acting on it takes them, on a known origin
  key       : ?Text;       // the thing this is about; same key updates it
  urgency   : ?Urgency;    // null = Normal
  expiresAt : ?Time.Time;  // null = II's default retention
};

// What a channel pulls back out. The rest never leaves this canister.
public type Content = {
  title : Text;
  body  : Text;
  url   : ?Text;
};
```

A full URL rather than a path, because an app is reachable on several origins
and the user is on one of them specifically. A path would have to be resolved
against the origin the notification was sent for, which sends someone who uses
`myapp.com` to `<canister>.icp0.io` — a different origin, and usually a
different session.

What keeps that safe is a list II already fetches: an app's
`/.well-known/ii-alternative-origins`, used for sign-in. A notification's URL is
opened when its origin is the sending origin or one of that origin's
alternatives, and refused otherwise, so an app can reach any of its own domains
and none of anyone else's.

One function takes it — `notifications.send(recipient, notification)`. The
split between what a channel renders and what II schedules on is the library's
to make: `urgency` and `expiresAt` go into the send, `title`, `body` and `url`
are stored for the pull. An app that only sets `title` and `body`
writes two nulls less than it would with a separate options record, and nobody
has to learn which field belongs to which half.

Each field has to mean something to every channel, which is what keeps them in:

| field | Web Push | mail | in-app |
| --- | --- | --- | --- |
| `title`, `body` | notification text | subject, body | row title and preview |
| `url` | click target | link | row target |
| `key` | reuses the id, so the same `tag` | thread | grouped rows |

The app's name and logo are not fields. They are not the app's to repeat per
notification: the worker fetches `/.well-known/ii-app-metadata` from the origin
and caches it, so it already has a name and a logo for every app it shows a
notification for, and an app restating them per notification is only a way to
disagree with itself.

Nothing about the fetch argues against a per-notification `image`, and an
earlier draft of this document claimed otherwise. The worker is already
fetching from the app's origin at display time, so one more image reveals
nothing new, and it can harden an image the same way the sign-in page hardens
the logo — fetch it itself, cap the size, re-encode, and hand
`showNotification` a `blob:` URL rather than hotlinking.

What is left against `image` is smaller and honest: Safari ignores a
per-notification icon, only some channels have a per-item image at all, and it
is a field every app has to get right for a payoff only a chat-shaped app
feels. It stays out of v1 and is the first thing to add if apps ask.

`key` is the identity of the thing being notified about, and the only way to
update a notification. The library maps `(recipient, key)` to a stable id, so a
repeat supersedes the pending entry instead of joining it: ten messages in one
conversation are one tray entry showing the latest.

The cost is deliberate. Replacing drops the superseded content, since the
pending store is keyed by id, so an app that wants every message to stand alone
leaves `key` null and gets a fresh id per send.

Deliberately not supported:

- **`actions`** — Chromium-only, absent on Safari, and every button needs its
  own route back into the app from a worker running on the II origin. A real
  feature with its own design, not a field.
- **`badge`** — Chromium-only monochrome glyph, and app-level: it belongs to
  the origin, not to a notification.
- **`requireInteraction`, `silent`, `renotify`, `vibrate`** — Chromium-only
  presentation knobs. `urgency` already carries the intent in a form II can act
  on for any channel, including ones that have no tray at all.
- **`data`** — an arbitrary bag no channel can render, and an invitation to put
  content where only one channel will find it. The app has its own state keyed
  by the notification id.
- **`timestamp`, `dir`, `lang`** — II knows when it sent the notification, and
  direction and language follow from the text.

If a channel later needs something genuinely richer — a long body for mail — it
arrives as another optional field, which is backwards compatible for apps that
never set it.

## What the app is expected to do

Very little, and none of it about delivery:

- Pass a **recipient** that is the account principal the user authenticated to
  this origin with. Anything else is a principal II has never heard of.
- Pass a **key** when this notification supersedes an earlier one about the same
  thing, and leave it null when it stands alone.
- Treat `send` as **fire-and-forget**. It returns nothing, it never fails the
  call it is made from, and a notification is an aside to whatever the app was
  actually doing.
- Keep its own copy of anything it needs. The library's content store is not
  app state: entries are evicted on expiry and the app cannot read them back.
- Read `metrics` if it wants to watch delivery. Nothing else: whether a user
  has consented is II's question, asked by the frontend, and whether a
  particular recipient is worth sending to is the library's. Neither is required, and an
  app that treats notifications as best-effort calls neither.

## When things go wrong

### Nothing fails the app's own call

`send` does not trap, does not await, and does not report. A chat message must
not fail to send because notifications are misconfigured, so every failure is
absorbed by the library and visible afterwards in `metrics`.

That includes configuration. If `internet_identity` or `notification_origin` is
missing, the first `send` records it in `metrics().misconfigured`, logs it, and
drops the notification — it does not trap the way the pull path does, because
there the caller is II and a loud failure is the right answer.

### Nothing to implement

There are no handlers. Everything that used to be one is either library
behaviour or a question the app asks:

| what happens | where it goes |
| --- | --- |
| II holds no record for the account | parked until near its expiry, tried once more, then counted in `dropped` |
| the account has no channel | parked the same way; the user has the whole window to turn notifications on |
| accepted, expired with nobody receiving it | counted in `dropped` |
| deferred until expiry, drops, saturation | `metrics()` — `deferred` climbing, then `dropped` |
| misconfiguration | `metrics().misconfigured`, and a canister log line |

The division that survived every round of this: a callback has to be about one
user *and* tell the app something it cannot otherwise know *and* leave it
something to do. Only "this person has no notification channel" ever met all
three, and even that is better as state than as an event, because an event has
to be stored and cleared correctly by every app that handles it.

### Delivery metrics

What an app actually wants to know is whether its notifications are getting
through, over a window it can compare against yesterday — not a pile of
monotonic counters it has to difference itself:

```motoko
public type Bucket = {
  start    : Time.Time;   // instant the hour begins, ns since the epoch
  sent     : Nat;         // notifications handed to II during it
  accepted : Nat;         // II took them
  deferred : Nat;         // II was over capacity and asked for them later
  received : Nat;         // a channel delivered them and marked receipt
  dropped  : Nat;         // given up on: expired undelivered, or outbox full
};

public type Metrics = {
  hours         : [Bucket];            // up to 720, oldest first
  backlog       : Nat;                 // outbox depth right now
  misconfigured : ?{ why : Misconfigured; since : Time.Time };
};
```

Each bucket carries the instant its hour begins, so the series needs no anchor
and no arithmetic: a dashboard reads `start` as its x value and the three
counts as its y values. `Time.Time` is nanoseconds since the epoch, so the day,
month and year come with it. Days, weeks and months are sums over slices the caller picks, which
also means it picks its own day boundary and timezone rather than inheriting
the library's.

Carrying the timestamp also lets the ring roll over lazily. A canister that
sends nothing for a week does not need a timer ticking to keep 168 empty
buckets contiguous — the hours with no traffic are simply absent, and a chart
that wants zeroes fills them in. A single anchor would have forced the opposite:
every bucket contiguous, and something waking up hourly to make it so.

Read as a pipeline, the series says where notifications are being lost.
`accepted / sent` below one is the app's own problem: its origin is over
capacity, or it is not an authorised sender at all. `received / accepted`
falling means II took them and nobody got them, which the app cannot fix but
should see. `deferred` is the early warning — pressure shows up as deferral
long before anything is lost — and `dropped` is the loss itself. `backlog` is
the gauge, and a backlog that climbs means sends are failing faster than the
app notices.

There is no callback for any of this, and that is deliberate. An app that wants
to email an operator when sending stalls reads `metrics()` from a timer it
already has and applies its own threshold, so the policy — what counts as
stalled, who to tell, how often — stays with the app instead of the library
inventing a definition and a required handler to deliver it.

A bucket is a timestamp and five small numbers, so the whole ring encodes to
tens of kilobytes and `metrics()` returns all of it in one reply — there is
nothing to paginate against a 2MB limit, and a dashboard slices the window it
wants client-side.

The ring is a stable field of the mixin, like the outbox and the pending
content, so it survives upgrades rather than restarting empty at the worst
possible moment — a deploy is exactly when someone wants to see whether
delivery changed. 720 buckets is about 2160 naturals, some 17KB of stable
state and a similar reply size; the reason not to keep a year is the 14x on
both, not any difficulty. An app wanting longer history snapshots `metrics()`
on its own schedule and keeps what it needs.

Per-reason breakdowns are deliberately absent. The pipeline stages say where
notifications are lost, which is what an operator acts on; splitting `dropped`
by cause would add columns nobody charts, and the one cause an app can do
something about — no channel — is already a question it can ask per user.

Read it with `notifications.metrics()`. It is not a canister method: whether
this is public, admin-only, or folded into an existing `http_request` is the
app's decision, not the library's.

### Every outcome

| what happens | who sees it | what the library does |
| --- | --- | --- |
| `NoSuchRecipient` | the bucket's `dropped`, if the second attempt fails too | parks the entry until near its expiry and tries once more; II holds no record for the account, usually because the user has not signed in to the app in long enough |
| `NoChannel` | the bucket's `dropped`, if the second attempt fails too | parks the entry until near its expiry; only the user can fix it, by enabling notifications in II, and now they have the whole window to |
| `Deferred { retry_after }` | the bucket's `deferred` | keeps the entry, retries at `retry_after`, and keeps doing so until `expiresAt` |
| deferred past `expiresAt` | the bucket's `dropped`; no callback, since it is the origin being saturated rather than anything about the user | drops it; II would refuse it anyway |
| accepted, expired with no receipt | the bucket's `dropped` | sweeps the content; nobody was reachable before it aged out |
| `TooManyNotifications { limit }` | nobody | records the limit, re-splits, sends again in the same flush |
| `NoSuchSender` | `metrics().misconfigured` and a canister log line | parks the outbox and retries hourly, because the fix is publishing an asset, not a deploy |
| `InternalCanisterError`, call rejected, II unreachable | the backlog climbs, `accepted / sent` falls | retries with backoff |
| outbox over its cap | the bucket's `dropped`, and the backlog pinned at the cap | drops the oldest keyless entries first, since keyed ones are supersedable and likely still wanted |
| upgrade mid-flush | nobody | the in-flight batch is retried; entries leave the outbox only on acceptance, and a repeated id replaces rather than duplicates |
| pull with an untrusted signer, a foreign origin, or an unknown id | nobody | answers `null`; the channel falls back to whatever it shows without content |
| `received` for an unknown id | nobody | no-op |

### No app code runs inside the library

With the handlers gone, nothing of the app's executes during a flush, a pull or
a sweep — which removes a failure mode rather than merely documenting it. A
handler that trapped would have rolled back the whole message, including the
bookkeeping that recorded the send, so the entry would be retried, trap again,
and the outbox would wedge permanently. Motoko cannot catch a trap, so the old
design had to isolate handlers in their own scheduled message to contain it.

Now the app reads `metrics` when it wants it, in its own messages, and a bug in that code can only affect the query it is in.

## Dependency on Internet Identity

The library is inert until II's side pulls content: today a push shows fixed
text, and nothing calls the two methods the mixin injects. How a channel renders
what it pulls — tray tags, which channel a notification takes — is II's, not
this library's. All this design assumes is that something calls
`_internet_identity_notification_content` with a verified sender info naming the
origin and account, and calls `_internet_identity_notification_received` once
delivered.

One thing it does assume about rendering: a click opens `content.url` rather
than II's own root, which is where the Web Push worker sends it today, and that
II checks the URL's origin against the sending origin and its
`/.well-known/ii-alternative-origins` before opening it. That file is one II
already fetches for sign-in, so the check reuses machinery rather than adding
any.

## Decisions

1. **Sender info encoding — settled, no change.** The pull signs
   `notification-sender-info ‖ origin ‖ account`, while the attributes flow puts
   an ICRC-3 map in the same IC field. That is not a conflict: a call carries
   one sender info, and the method it arrives at fixes which flow produced it —
   the map at the sign-in method, this blob at the pull method. Neither has to
   detect a format, and the domain prefix already prevents a blob minted for one
   flow being accepted by the other. The library decodes the blob directly.

2. **Uncertified content — accepted.** The query is the only content path, so a
   single malicious replica can return any body for a notification. Certifying
   it would mean the app certifying content it generated on the fly, and an
   update per notification opened would put consensus on the path where a user
   is staring at an empty notification. A replica that can lie about a body can
   equally refuse to answer, so the exposure buys little; accepted knowingly.
3. **Method names — internal.** `_internet_identity_notification_content` and
   `_internet_identity_notification_received` are called by II's worker and
   implemented by II's library, so both sides have the same owner and change
   together. Nothing about them needs publishing as a contract; the
   `_internet_identity_*` prefix keeps them out of an app's own namespace and
   marks them as not-yours-to-call.
