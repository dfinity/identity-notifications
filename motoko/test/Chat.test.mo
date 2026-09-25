import Array "mo:core/Array";
import Map "mo:core/Map";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Flush "../src/Internal/Flush";
import Ids "../src/Internal/Ids";
import II "../src/Internal/II";
import Metrics "../src/Internal/Metrics";
import Outbox "../src/Internal/Outbox";
import Types "../src/Types";

// A chat app and an Internet Identity, both fake, so scenarios can be run
// without a replica. The library's async shell is a batch, a call and
// `Flush.apply`; everything worth checking is on this side of the await.

let HOUR = 3_600_000_000_000;
let MINUTE = 60_000_000_000;
/// Internet Identity's default, as the library mirrors it.
let RETENTION = 5 * MINUTE;
let CAPACITY = 1_073_741_824;

type World = {
  outbox : Outbox.State;
  pipeline : Metrics.State;
  /// Who Internet Identity knows, and whether they have a channel.
  known : Map.Map<Principal, Bool>;
  /// How many notifications the origin may have in flight before II defers.
  var roomPerFlush : Nat;
  var batchLimit : Nat
};

func world(roomPerFlush : Nat) : World = {
  outbox = Outbox.empty();
  pipeline = Metrics.empty();
  known = Map.empty<Principal, Bool>();
  var roomPerFlush = roomPerFlush;
  var batchLimit = 1_000
};

func user(n : Nat) : Principal = Principal.fromBlob(Text.encodeUtf8("user-" # Nat.toText(n)));

func reachable(w : World, p : Principal) = Map.add(w.known, Principal.compare, p, true);
func noChannel(w : World, p : Principal) = Map.add(w.known, Principal.compare, p, false);

func message(key : Text, urgency : ?Types.Urgency, expiresAt : ?Int) : Types.Notification = {
  title = "New message";
  body = "hello";
  url = null;
  key = ?key;
  urgency;
  expiresAt
};

func send(w : World, to : Principal, note : Types.Notification, now : Int) {
  ignore Outbox.add(w.outbox, to, note, now + RETENTION, CAPACITY, now)
};

/// One flush: what Internet Identity would answer, applied the way the mixin
/// applies it.
func flush(w : World, now : Int) : { sent : Nat; accepted : Nat } {
  Outbox.sweep(w.outbox, now);
  Outbox.promote(w.outbox, now);
  let (batch, _) = Outbox.sendable(w.outbox, Outbox.take(w.outbox, w.batchLimit), now);
  if (batch.size() == 0) return { sent = 0; accepted = 0 };

  let refused = Array.filterMap<Outbox.Entry, II.NotAccepted>(
    batch,
    func(entry) {
      switch (Map.get(w.known, Principal.compare, entry.recipient)) {
        case null ?{
          id = entry.id;
          recipient = entry.recipient;
          reason = #NoSuchRecipient
        };
        case (?false) ?{
          id = entry.id;
          recipient = entry.recipient;
          reason = #NoChannel
        };
        case (?true) null
      }
    }
  );

  // Capacity: anything beyond the origin's room this flush is deferred.
  let taken = batch.size() - refused.size();
  let deferred = if (taken > w.roomPerFlush) taken - w.roomPerFlush else 0;
  let deferrals = Array.tabulate<II.NotAccepted>(
    deferred,
    func(i) {
      let entry = batch[batch.size() - 1 - i];
      {
        id = entry.id;
        recipient = entry.recipient;
        reason = #Deferred { retry_after = Nat64.fromNat(Int.abs(now + MINUTE)) }
      }
    }
  );

  let notAccepted = Array.concat(refused, deferrals);
  Flush.apply(w.outbox, w.pipeline, batch, #answered(notAccepted), now);
  { sent = batch.size(); accepted = batch.size() - notAccepted.size() }
};

func totals(w : World) : {
  sent : Nat;
  accepted : Nat;
  dropped : Nat;
  deferred : Nat
} {
  var sent = 0;
  var accepted = 0;
  var dropped = 0;
  var deferred = 0;
  for (bucket in Metrics.snapshot(w.pipeline).values()) {
    sent += bucket.sent;
    accepted += bucket.accepted;
    dropped += bucket.dropped;
    deferred += bucket.deferred
  };
  { sent; accepted; dropped; deferred }
};

// A small group of active people: every message reaches everyone, in one call.
do {
  let w = world(1_000);
  for (i in Nat.range(0, 5)) reachable(w, user(i));

  for (i in Nat.range(1, 5)) {
    send(w, user(i), message("chat-room", null, null), HOUR)
  };

  let result = flush(w, HOUR);
  assert result.sent == 4;
  assert result.accepted == 4;
  assert Outbox.backlog(w.outbox) == 0
};

// A large group of mostly dormant people: the first message costs a refusal
// each, and later messages for the same conversation cost nothing, because a
// repeated key updates the entry that is already parked.
do {
  let w = world(10_000);
  for (i in Nat.range(0, 1_000)) {
    if (i < 50) reachable(w, user(i)) else {}
  };

  for (i in Nat.range(0, 1_000)) {
    send(w, user(i), message("chat-big", null, null), HOUR)
  };
  let first = flush(w, HOUR);
  assert first.sent == 1_000;
  assert first.accepted == 50;

  // Second message, same conversation, while 950 entries sit parked.
  for (i in Nat.range(0, 1_000)) {
    send(w, user(i), message("chat-big", null, null), 2 * HOUR)
  };
  let second = flush(w, 2 * HOUR);
  assert second.sent == 50;
  assert second.accepted == 50
};

// A campaign must not starve the chat, and the chat must not starve the
// campaign: lanes give the urgent traffic most of a batch and the campaign
// the rest, every batch.
do {
  let w = world(10_000);
  for (i in Nat.range(0, 200)) reachable(w, user(i));

  for (i in Nat.range(0, 100)) {
    send(w, user(i), message("campaign-" # Nat.toText(i), ?#veryLow, null), HOUR)
  };
  for (i in Nat.range(100, 200)) {
    send(w, user(i), message("chat-" # Nat.toText(i), ?#high, null), HOUR)
  };

  Outbox.promote(w.outbox, HOUR);
  let batch = Outbox.take(w.outbox, 15);

  var urgent = 0;
  var campaign = 0;
  for (entry in batch.values()) {
    if (entry.lane == 0) urgent += 1 else campaign += 1
  };

  // Weights are 8 : 4 : 2 : 1, so a fifteen-entry batch is mostly urgent —
  // and the campaign still moves.
  assert urgent == 14 and campaign == 1
};

// Deferral is not refusal: the entry comes back when Internet Identity asked
// for it, and what fits is accepted then.
do {
  let w = world(2);
  for (i in Nat.range(0, 5)) reachable(w, user(i));
  for (i in Nat.range(0, 5)) {
    send(w, user(i), message("m-" # Nat.toText(i), null, null), HOUR)
  };

  let first = flush(w, HOUR);
  assert first.accepted == 2;
  assert Outbox.backlog(w.outbox) == 3;

  // Not yet due, so nothing moves.
  assert flush(w, HOUR + 60).sent == 0;

  w.roomPerFlush := 10;
  let second = flush(w, HOUR + MINUTE);
  assert second.sent == 3 and second.accepted == 3;
  assert Outbox.backlog(w.outbox) == 0
};

// A notification whose second attempt also fails is dropped, once, and its
// content goes with it.
do {
  let w = world(10);
  noChannel(w, user(0));
  send(w, user(0), message("m", null, ?(2 * HOUR)), HOUR);

  assert flush(w, HOUR).accepted == 0;
  assert Outbox.backlog(w.outbox) == 1;

  // The second attempt falls inside the window it is for.
  let second = flush(w, 2 * HOUR - 1);
  assert second.sent == 1 and second.accepted == 0;
  assert Outbox.backlog(w.outbox) == 0;
  switch (Outbox.contentOf(w.outbox, Ids.keyed(user(0), "m"))) {
    case null {};
    case (?_) assert false
  };
  assert totals(w).dropped == 1
};

// Everything accepted is kept until it expires, because a pull has to find
// content — and no longer, because nothing will pull it after that.
do {
  let w = world(10);
  reachable(w, user(0));
  send(w, user(0), message("kept", null, null), HOUR);
  ignore flush(w, HOUR);

  switch (Outbox.contentOf(w.outbox, Ids.keyed(user(0), "kept"))) {
    case (?content) assert content.title == "New message";
    case null assert false
  };

  ignore flush(w, HOUR + RETENTION);
  switch (Outbox.contentOf(w.outbox, Ids.keyed(user(0), "kept"))) {
    case null {};
    case (?_) assert false
  }
};

// A campaign nobody opens does not accumulate: each round's content goes when
// that round expires, so the canister holds one round rather than every one.
do {
  let w = world(10_000);
  for (i in Nat.range(0, 500)) reachable(w, user(i));

  for (round in Nat.range(0, 4)) {
    let at = HOUR + round * 2 * RETENTION;
    for (i in Nat.range(0, 500)) {
      send(
        w,
        user(i),
        message("campaign-" # Nat.toText(round) # "-" # Nat.toText(i), ?#veryLow, null),
        at
      )
    };
    assert flush(w, at).accepted == 500
  };

  switch (Outbox.contentOf(w.outbox, Ids.keyed(user(0), "campaign-0-0"))) {
    case null {};
    case (?_) assert false
  };
  switch (Outbox.contentOf(w.outbox, Ids.keyed(user(0), "campaign-3-0"))) {
    case (?_) {};
    case null assert false
  }
};

// At the ceiling the campaign's entries go and the urgent one still gets in,
// and anything already accepted keeps its content.
do {
  let w = world(1);
  reachable(w, user(0));

  // One accepted notification, whose content must survive whatever follows.
  send(w, user(0), message("kept", null, null), HOUR);
  ignore flush(w, HOUR);

  // Now fill a tiny budget with campaign entries, then send something urgent.
  let tiny = 900;
  var i = 0;
  while (i < 20) {
    ignore Outbox.add(
      w.outbox,
      user(0),
      message("camp-" # Nat.toText(i), ?#veryLow, null),
      HOUR + RETENTION,
      tiny,
      HOUR
    );
    i += 1
  };
  let urgent = Outbox.add(
    w.outbox,
    user(0),
    message("urgent", ?#high, null),
    HOUR + RETENTION,
    tiny,
    HOUR
  );

  var shed = 0;
  for (i in Nat.range(0, 20)) {
    if (not Outbox.holds(w.outbox, Ids.keyed(user(0), "camp-" # Nat.toText(i)))) shed += 1
  };
  assert shed > 0;

  switch urgent {
    case (?id) switch (Outbox.contentOf(w.outbox, id)) {
      case (?_) {};
      case null assert false
    };
    case null assert false
  };
  switch (Outbox.contentOf(w.outbox, Ids.keyed(user(0), "kept"))) {
    case (?_) {};
    case null assert false
  }
};

// A batch Internet Identity says is too large is not lost: nothing was
// enqueued, so the entries go back and the limit is remembered.
do {
  let w = world(10_000);
  for (i in Nat.range(0, 10)) reachable(w, user(i));
  for (i in Nat.range(0, 10)) {
    send(w, user(i), message("m-" # Nat.toText(i), null, null), HOUR)
  };

  Outbox.promote(w.outbox, HOUR);
  let batch = Outbox.take(w.outbox, 10);
  Flush.apply(w.outbox, w.pipeline, batch, #tooMany(4), HOUR);

  assert Outbox.backlog(w.outbox) == 10;

  w.batchLimit := 4;
  let first = flush(w, HOUR);
  assert first.sent == 4 and first.accepted == 4;
  assert Outbox.backlog(w.outbox) == 6
};

// A call that never lands leaves the notification for its second attempt
// rather than dropping it.
do {
  let w = world(10);
  reachable(w, user(0));
  send(w, user(0), message("m", null, ?(3 * HOUR)), HOUR);

  Outbox.promote(w.outbox, HOUR);
  let batch = Outbox.take(w.outbox, 10);
  Flush.apply(w.outbox, w.pipeline, batch, #unreachable, HOUR);

  assert Outbox.backlog(w.outbox) == 1;
  assert flush(w, HOUR + 60).sent == 0;
  assert flush(w, 3 * HOUR - 1).accepted == 1
}
