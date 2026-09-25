import Outbox "../src/Internal/Outbox";
import Principal "mo:core/Principal";

let alice = Principal.fromText("un4fu-tqaaa-aaaab-qadjq-cai");
let HOUR = 3_600_000_000_000;

func note(title : Text, key : ?Text, urgency : ?{ #veryLow; #low; #normal; #high }) : {
  title : Text;
  body : Text;
  url : ?Text;
  key : ?Text;
  urgency : ?{ #veryLow; #low; #normal; #high };
  expiresAt : ?Int
} = { title; body = "b"; url = null; key; urgency; expiresAt = null };

// The same key is the same notification: the second send replaces the first.
do {
  let o = Outbox.empty();
  let first = Outbox.add(o, alice, note("one", ?"k", null), HOUR, 1_000_000, 0);
  let second = Outbox.add(o, alice, note("two", ?"k", null), HOUR, 1_000_000, 0);

  assert first == second;
  switch (Outbox.contentOf(o, switch first { case (?id) id; case null (0 : Nat64) })) {
    case (?content) assert content.title == "two";
    case null assert false
  }
};

// Urgency decides the lane, so a high-urgency notification leads a batch.
do {
  let o = Outbox.empty();
  ignore Outbox.add(o, alice, note("campaign", ?"c", ?#veryLow), HOUR, 1_000_000, 0);
  ignore Outbox.add(o, alice, note("urgent", ?"u", ?#high), HOUR, 1_000_000, 0);

  let batch = Outbox.take(o, 2);
  assert batch.size() == 2;
  assert batch[0].lane == 0
};

// A refusal parks the entry later in its window, and a second refusal drops
// it along with its content.
do {
  let o = Outbox.empty();
  let id = switch (Outbox.add(o, alice, note("x", ?"k", null), 10 * HOUR, 1_000_000, 0)) {
    case (?i) i;
    case null (0 : Nat64)
  };

  let first = Outbox.take(o, 10);
  assert first.size() == 1;
  assert Outbox.park(o, first[0], 0);

  // Not due yet, so a flush sees nothing.
  Outbox.promote(o, HOUR);
  assert Outbox.take(o, 10).size() == 0;

  // Due inside its window, so it comes back exactly once.
  Outbox.promote(o, 7 * HOUR);
  let second = Outbox.take(o, 10);
  assert second.size() == 1;
  assert second[0].dueAt < second[0].expiresAt;
  assert not Outbox.park(o, second[0], 7 * HOUR);
  switch (Outbox.contentOf(o, id)) { case null {}; case (?_) assert false };
  assert Outbox.backlog(o) == 0
};

// Deferral is not a refusal: the entry comes back when II asked for it.
do {
  let o = Outbox.empty();
  ignore Outbox.add(o, alice, note("x", ?"k", null), 10 * HOUR, 1_000_000, 0);

  let batch = Outbox.take(o, 10);
  Outbox.defer(o, batch[0], 2 * HOUR);

  Outbox.promote(o, HOUR);
  assert Outbox.take(o, 10).size() == 0;
  Outbox.promote(o, 2 * HOUR);
  assert Outbox.take(o, 10).size() == 1
};

// At the ceiling the campaign tail goes and the urgent notification stays.
do {
  let o = Outbox.empty();
  let room = 1_000;

  var i = 0;
  while (i < 8) {
    ignore Outbox.add(o, alice, note("campaign", ?("c" # debug_show i), ?#veryLow), HOUR, room, 0);
    i += 1
  };
  let urgent = Outbox.add(o, alice, note("urgent", ?"u", ?#high), HOUR, room, 0);

  assert urgent != null;
  switch (urgent) {
    case (?id) switch (Outbox.contentOf(o, id)) {
      case (?_) {};
      case null assert false
    };
    case null assert false
  }
};

// Accepted content is there for a pull until the notification expires, and
// gone once nothing can pull it.
do {
  let o = Outbox.empty();
  let id = switch (Outbox.add(o, alice, note("x", ?"k", null), HOUR, 1_000_000, 0)) {
    case (?i) i;
    case null (0 : Nat64)
  };

  let batch = Outbox.take(o, 10);
  Outbox.settle(o, batch[0]);
  assert Outbox.backlog(o) == 0;

  Outbox.sweep(o, HOUR - 1);
  assert Outbox.holds(o, id);

  Outbox.sweep(o, HOUR);
  assert not Outbox.holds(o, id)
};

// A dismissed notification leaves the outbox rather than being sent without
// content, and an expired one counts as a drop.
do {
  let o = Outbox.empty();
  ignore Outbox.add(o, alice, note("x", ?"k", null), HOUR, 1_000_000, 0);
  Outbox.dismiss(o, alice, "k");
  assert Outbox.backlog(o) == 0;

  let (live, expired) = Outbox.sendable(o, Outbox.take(o, 10), 0);
  assert live.size() == 0;
  assert expired == 0;

  ignore Outbox.add(o, alice, note("y", ?"j", null), HOUR, 1_000_000, 0);
  let (none, one) = Outbox.sendable(o, Outbox.take(o, 10), HOUR);
  assert none.size() == 0;
  assert one == 1;
  assert Outbox.backlog(o) == 0
}
