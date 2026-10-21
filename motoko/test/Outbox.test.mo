import List "mo:core/List";
import Nat64 "mo:core/Nat64";
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
  expiresAt : ?Int;
  funnel : ?Text
} = {
  title;
  body = "b";
  url = null;
  key;
  urgency;
  expiresAt = null;
  funnel = null
};

// The same key is the same notification: the second send replaces the first.
do {
  let o = Outbox.empty();
  let first = o.add(alice, note("one", ?"k", null), HOUR, 1_000_000, 0);
  let second = o.add(alice, note("two", ?"k", null), HOUR, 1_000_000, 0);

  assert first == second;
  switch (o.contentOf(switch first { case (?id) id; case null (0 : Nat64) })) {
    case (?content) assert content.title == "two";
    case null assert false
  }
};

// Urgency decides the lane, so a high-urgency notification leads a batch.
do {
  let o = Outbox.empty();
  ignore o.add(alice, note("campaign", ?"c", ?#veryLow), HOUR, 1_000_000, 0);
  ignore o.add(alice, note("urgent", ?"u", ?#high), HOUR, 1_000_000, 0);

  let batch = o.take(2);
  assert batch.size() == 2;
  assert batch[0].lane == 0
};

// A refusal parks the entry later in its window, and a second refusal drops
// it along with its content.
do {
  let o = Outbox.empty();
  let id = switch (o.add(alice, note("x", ?"k", null), 10 * HOUR, 1_000_000, 0)) {
    case (?i) i;
    case null (0 : Nat64)
  };

  let first = o.take(10);
  assert first.size() == 1;
  assert o.park(first[0], 0);

  // Not due yet, so a flush sees nothing.
  o.promote(HOUR);
  assert o.take(10).size() == 0;

  // Due inside its window, so it comes back exactly once.
  o.promote(7 * HOUR);
  let second = o.take(10);
  assert second.size() == 1;
  assert second[0].dueAt < second[0].expiresAt;
  assert not o.park(second[0], 7 * HOUR);
  switch (o.contentOf(id)) { case null {}; case (?_) assert false };
  assert o.backlog() == 0
};

// Deferral is not a refusal: the entry comes back when II asked for it.
do {
  let o = Outbox.empty();
  ignore o.add(alice, note("x", ?"k", null), 10 * HOUR, 1_000_000, 0);

  let batch = o.take(10);
  o.defer(batch[0], 2 * HOUR);

  o.promote(HOUR);
  assert o.take(10).size() == 0;
  o.promote(2 * HOUR);
  assert o.take(10).size() == 1
};

// At the ceiling the campaign tail goes and the urgent notification stays.
do {
  let o = Outbox.empty();
  let room = 1_000;

  let campaign = List.empty<Nat64>();
  var i = 0;
  while (i < 20) {
    switch (o.add(alice, note("campaign", ?("c" # debug_show i), ?#veryLow), HOUR, room, 0)) {
      case (?id) campaign.add(id);
      case null {}
    };
    i += 1
  };
  let urgent = o.add(alice, note("urgent", ?"u", ?#high), HOUR, room, 0);

  var kept = 0;
  for (id in campaign.values()) {
    if (o.holds(id)) kept += 1
  };
  assert kept < campaign.size();
  assert o.backlog() == kept + 1;

  switch (urgent) {
    case (?id) assert o.holds(id);
    case null assert false
  }
};

// Accepted content is never shed, so a canister at its ceiling has to wait for
// an expiry rather than lose what a channel may still pull.
do {
  let o = Outbox.empty();
  // Room for one notification and no more.
  let room = 100;

  let filler = switch (o.add(alice, note("filler", ?"f", null), HOUR, room, 0)) {
    case (?id) id;
    case null (0 : Nat64)
  };
  let batch = o.take(10);
  o.settle(batch[0]);

  assert o.add(alice, note("x", ?"x", null), HOUR, room, 0) == null;

  // Past the filler's expiry there is room again, because a send sweeps.
  assert o.add(alice, note("x", ?"x", null), 2 * HOUR, room, HOUR) != null;
  assert not o.holds(filler)
};

// A deferral is not a refusal, so it does not spend the second attempt.
do {
  let o = Outbox.empty();
  ignore o.add(alice, note("x", ?"k", null), 30 * HOUR, 1_000_000, 0);

  let first = o.take(10);
  o.defer(first[0], 2 * HOUR);
  o.promote(2 * HOUR);

  let deferred = o.take(10);
  assert deferred.size() == 1;
  assert o.park(deferred[0], 2 * HOUR);

  o.promote(30 * HOUR);
  let last = o.take(10);
  assert not o.park(last[0], 25 * HOUR)
};

// Accepted content is there for a pull until the notification expires, and
// gone once nothing can pull it.
do {
  let o = Outbox.empty();
  let id = switch (o.add(alice, note("x", ?"k", null), HOUR, 1_000_000, 0)) {
    case (?i) i;
    case null (0 : Nat64)
  };

  let batch = o.take(10);
  o.settle(batch[0]);
  assert o.backlog() == 0;

  ignore o.sweep(HOUR - 1);
  assert o.holds(id);

  ignore o.sweep(HOUR);
  assert not o.holds(id)
};

// A dismissed notification leaves the outbox rather than being sent without
// content, and an expired one counts as a drop.
do {
  let o = Outbox.empty();
  ignore o.add(alice, note("x", ?"k", null), HOUR, 1_000_000, 0);
  o.dismiss(alice, "k");
  assert o.backlog() == 0;

  let (live, expired) = o.sendable(o.take(10), 0);
  assert live.size() == 0;
  assert expired.size() == 0;

  ignore o.add(alice, note("y", ?"j", null), HOUR, 1_000_000, 0);
  let (none, one) = o.sendable(o.take(10), HOUR);
  assert none.size() == 0;
  assert one.size() == 1;
  assert o.backlog() == 0
};

let MINUTE = 60_000_000_000;

// Nothing refused a deferred notification, so a repeat of its key is given the
// window it asks for rather than being stuck with the first send's.
do {
  let o = Outbox.empty();
  let id = o.add(alice, note("one", ?"k", null), MINUTE, 1_000_000, 0);
  let batch = o.take(1);
  o.defer(batch[0], 2 * MINUTE);

  ignore o.add(alice, note("two", ?"k", null), 5 * MINUTE, 1_000_000, MINUTE);
  assert o.nextDue() == ?(2 * MINUTE);

  o.promote(2 * MINUTE);
  let (live, expired) = o.sendable(o.take(1), 2 * MINUTE);
  assert expired.size() == 0;
  assert live.size() == 1;
  switch (o.contentOf(switch id { case (?id) id; case null (0 : Nat64) })) {
    case (?content) assert content.title == "two";
    case null assert false
  }
};

// A refusal spends the second attempt, so a repeat keeps the window it was
// refused in: a dormant recipient costs an app one round of refusals.
do {
  let o = Outbox.empty();
  ignore o.add(alice, note("one", ?"k", null), MINUTE, 1_000_000, 0);
  let batch = o.take(1);
  assert o.park(batch[0], 0);

  ignore o.add(alice, note("two", ?"k", null), 5 * MINUTE, 1_000_000, MINUTE);
  o.promote(MINUTE);

  let (live, expired) = o.sendable(o.take(1), MINUTE + 1);
  assert live.size() == 0;
  assert expired.size() == 1
};

// An empty outbox is nothing to wake for; anything waiting is due now, and a
// deferred notification is due when Internet Identity asked.
do {
  let o = Outbox.empty();
  assert o.nextDue() == null;

  ignore o.add(alice, note("one", ?"k", null), MINUTE, 1_000_000, 0);
  assert o.nextDue() == ?0;

  let batch = o.take(1);
  o.defer(batch[0], 3 * MINUTE);
  assert o.nextDue() == ?(3 * MINUTE)
}
