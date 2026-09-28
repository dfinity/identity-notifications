import Array "mo:core/Array";
import Int "mo:core/Int";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat64 "mo:core/Nat64";
import Order "mo:core/Order";
import Principal "mo:core/Principal";
import Blob "mo:core/Blob";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Ids "Ids";
import LaneQueue "LaneQueue";
import Types "../Types";

/// What is waiting to be sent, and what a channel may still pull.
///
/// A notification is in one of three places: in a lane by urgency while it is
/// ready to go, parked while it waits for a later attempt, or accepted, where
/// only its content remains until it expires. `entries` says which, so a
/// repeat of a key finds it in one look.
module {

  public let LANES : Nat = 4;
  public let WEIGHTS : [Nat] = [8, 4, 2, 1];

  /// Where a notification is. `#nowhere` until it is first placed.
  public type Stage = { #nowhere; #waiting; #parked; #accepted };

  /// Every place it can be put, which is every stage but `#nowhere`.
  type Destination = { #waiting; #parked; #accepted };

  public type Entry = {
    id : Nat64;
    recipient : Principal;
    var lane : Nat;
    var expiresAt : Time.Time;
    var dueAt : Time.Time;
    var stage : Stage;
    /// Its one second attempt has been spent.
    var retried : Bool
  };

  /// Keyed by the time they come up, so the soonest is the first entry.
  type Schedule = Map.Map<(Time.Time, Nat64), Entry>;

  public type State = {
    ready : LaneQueue.State<Entry>;
    parked : Schedule;
    accepted : Schedule;
    content : Map.Map<Nat64, Types.Content>;
    entries : Map.Map<Nat64, Entry>;
    var counter : Nat64;
    var idSeed : Nat64;
    var bytes : Nat;
    var queued : Nat
  };

  public func empty() : State = {
    ready = LaneQueue.empty<Entry>(LANES);
    parked = Map.empty<(Time.Time, Nat64), Entry>();
    accepted = Map.empty<(Time.Time, Nat64), Entry>();
    content = Map.empty<Nat64, Types.Content>();
    entries = Map.empty<Nat64, Entry>();
    var counter = 0;
    var idSeed = 0;
    var bytes = 0;
    var queued = 0
  };

  public func lane(urgency : ?Types.Urgency) : Nat = switch urgency {
    case (?#high) 0;
    case (null or ?#normal) 1;
    case (?#low) 2;
    case (?#veryLow) 3
  };

  public func soonestExpiry(a : Entry, b : Entry) : Order.Order = Int.compare(a.expiresAt, b.expiresAt);

  /// Adds a notification, or replaces the one its key already names.
  public func add(
    self : State,
    recipient : Principal,
    notification : Types.Notification,
    defaultExpiry : Time.Time,
    capacityBytes : Nat,
    now : Time.Time
  ) : ?Nat64 {
    sweep(self, now);

    let id = switch (notification.key) {
      case (?key) Ids.keyed(recipient, key);
      case null {
        self.counter += 1;
        Ids.keyless(self.idSeed, self.counter)
      }
    };

    let content : Types.Content = {
      title = notification.title;
      body = notification.body;
      url = notification.url
    };
    let size = sizeOf(content);

    // Replacing a notification frees what the old one held, so an app that
    // updates one key forever occupies one notification's worth of room.
    switch (Map.get(self.content, Nat64.compare, id)) {
      case (?old) self.bytes -= sizeOf(old);
      case null {}
    };

    if (self.bytes + size > capacityBytes and not shed(self, capacityBytes, size)) {
      return null
    };

    Map.add(self.content, Nat64.compare, id, content);
    self.bytes += size;

    let expiresAt = switch (notification.expiresAt) {
      case (?at) at;
      case null defaultExpiry
    };

    switch (Map.get(self.entries, Nat64.compare, id)) {
      case (?entry) {
        // Still on its way out, so the entry stands: what this send brings is
        // content and, unless that entry has spent its second attempt, a window
        // of its own. An entry that was refused keeps the window it was refused
        // in, so a dormant recipient costs an app one round of refusals however
        // often it repeats the key. The lane it was queued in stands either way.
        if (entry.stage != #accepted) {
          if (not entry.retried) entry.expiresAt := expiresAt;
          return ?id
        };
        // Accepted, so Internet Identity holds a notification whose content
        // has just changed. Sending it again replaces that one.
        entry.lane := lane(notification.urgency);
        entry.expiresAt := expiresAt;
        entry.retried := false;
        place(self, entry, #waiting, now)
      };
      case null {
        let entry : Entry = {
          id;
          recipient;
          var lane = lane(notification.urgency);
          var expiresAt = expiresAt;
          var dueAt = now;
          var stage = #nowhere;
          var retried = false
        };
        Map.add(self.entries, Nat64.compare, id, entry);
        place(self, entry, #waiting, now)
      }
    };

    ?id
  };

  /// Internet Identity took it: nothing more to send, and its content waits
  /// there for a pull until it expires.
  public func settle(self : State, entry : Entry) {
    place(self, entry, #accepted, entry.expiresAt)
  };

  /// One more attempt, later in the notification's window. `false` when this
  /// was that attempt and the notification is now dropped.
  public func park(self : State, entry : Entry, now : Time.Time) : Bool {
    if (entry.retried) {
      forget(self, entry.id);
      return false
    };
    entry.retried := true;
    place(self, entry, #parked, retryAt(now, entry.expiresAt));
    true
  };

  /// Internet Identity asked for this one later. Not a refusal, so it does not
  /// spend the second attempt.
  public func defer(self : State, entry : Entry, retryAfter : Time.Time) {
    place(self, entry, #parked, retryAfter)
  };

  /// Nothing was enqueued; the entry goes back unchanged.
  public func requeue(self : State, entry : Entry, now : Time.Time) {
    place(self, entry, #waiting, now)
  };

  /// Returns parked entries to their lanes once they are due.
  public func promote(self : State, now : Time.Time) {
    for (entry in due(self.parked, now).values()) {
      place(self, entry, #waiting, now)
    }
  };

  /// When the outbox next has something to do: now, where anything is waiting,
  /// or the soonest parked entry's turn. Nothing queued, no answer.
  public func nextDue(self : State) : ?Time.Time {
    if (LaneQueue.size(self.ready) > 0) return ?0;
    for (((at, _), _) in Map.entries(self.parked)) return ?at;
    null
  };

  public func take(self : State, count : Nat) : [Entry] = LaneQueue.take<Entry>(self.ready, WEIGHTS, count, soonestExpiry);

  /// What a batch may still be sent: anything past its expiry would be refused
  /// by Internet Identity, and anything the app has since dismissed is no
  /// longer wanted. Only an expiry counts as a drop.
  public func sendable(self : State, batch : [Entry], now : Time.Time) : ([Entry], Nat) {
    let live = List.empty<Entry>();
    var expired = 0;

    for (entry in batch.values()) {
      if (entry.expiresAt <= now) {
        forget(self, entry.id);
        expired += 1
      } else if (holds(self, entry.id)) {
        List.add(live, entry)
      }
    };

    (List.toArray(live), expired)
  };

  /// Drops what an expired notification was still holding. Internet Identity
  /// will not pull content it can no longer deliver.
  public func sweep(self : State, now : Time.Time) {
    for (entry in due(self.accepted, now).values()) {
      forget(self, entry.id)
    }
  };

  /// The app says this no longer needs anyone's attention: it leaves the
  /// outbox, and its content goes so a pull finds nothing.
  public func dismiss(self : State, recipient : Principal, key : Text) {
    forget(self, Ids.keyed(recipient, key))
  };

  public func contentOf(self : State, id : Nat64) : ?Types.Content = Map.get(self.content, Nat64.compare, id);

  /// `false` when there is no such notification to have received.
  public func holds(self : State, id : Nat64) : Bool = switch (Map.get(self.content, Nat64.compare, id)) {
    case (?_) true;
    case null false
  };

  /// Notifications waiting for Internet Identity to accept them.
  public func backlog(self : State) : Nat = self.queued;

  /// Once only, from the first flush.
  public func seed(self : State, randomness : Blob) {
    if (self.idSeed == 0) self.idSeed := Ids.seedFrom(randomness)
  };

  /// When the second attempt a refusal earns is made: late enough to leave the
  /// user most of the window to sign in or turn notifications on, early enough
  /// that a five-minute notification still gets the attempt.
  func retryAt(now : Time.Time, expiresAt : Time.Time) : Time.Time {
    if (expiresAt <= now) return now;
    now + (expiresAt - now) * 2 / 3
  };

  /// Puts an entry in one of the three places and takes it out of the one it
  /// was in. A lane is left to `take`, which pops what it hands out.
  func place(self : State, entry : Entry, stage : Destination, at : Time.Time) {
    switch (entry.stage) {
      case (#parked) Map.remove(self.parked, byTime, (entry.dueAt, entry.id));
      case (#accepted) Map.remove(self.accepted, byTime, (entry.expiresAt, entry.id));
      case (#nowhere or #waiting) {}
    };

    let wasQueued = queued(entry.stage);
    entry.stage := stage;
    entry.dueAt := at;

    switch stage {
      case (#waiting) LaneQueue.push<Entry>(self.ready, entry.lane, entry, soonestExpiry);
      case (#parked) Map.add(self.parked, byTime, (at, entry.id), entry);
      case (#accepted) Map.add(self.accepted, byTime, (entry.expiresAt, entry.id), entry)
    };

    if (queued(stage) and not wasQueued) self.queued += 1;
    if (wasQueued and not queued(stage)) self.queued -= 1
  };

  /// Takes a notification out of every place it is in, content included.
  func forget(self : State, id : Nat64) {
    switch (Map.get(self.entries, Nat64.compare, id)) {
      case (?entry) {
        switch (entry.stage) {
          case (#parked) Map.remove(self.parked, byTime, (entry.dueAt, entry.id));
          case (#accepted) Map.remove(self.accepted, byTime, (entry.expiresAt, entry.id));
          case (#nowhere or #waiting) {}
        };
        if (queued(entry.stage)) self.queued -= 1;
        Map.remove(self.entries, Nat64.compare, id)
      };
      case null {}
    };
    release(self, id)
  };

  /// Everything in a schedule whose time has come, soonest first.
  func due(schedule : Schedule, now : Time.Time) : [Entry] {
    let ready = List.empty<Entry>();
    label scanning for (((at, _), entry) in Map.entries(schedule)) {
      if (at > now) break scanning;
      List.add(ready, entry)
    };
    List.toArray(ready)
  };

  func queued(stage : Stage) : Bool = stage == #waiting or stage == #parked;

  func byTime(a : (Time.Time, Nat64), b : (Time.Time, Nat64)) : Order.Order = switch (Int.compare(a.0, b.0)) {
    case (#equal) Nat64.compare(a.1, b.1);
    case (order) order
  };

  func release(self : State, id : Nat64) {
    switch (Map.get(self.content, Nat64.compare, id)) {
      case (?content) {
        self.bytes -= sizeOf(content);
        Map.remove(self.content, Nat64.compare, id)
      };
      case null {}
    }
  };

  /// Nothing accepted is ever shed: Internet Identity may still deliver it and
  /// a pull has to find content. What goes is the outbox, lowest lane first.
  func shed(self : State, capacityBytes : Nat, needed : Nat) : Bool {
    var lane = LANES;
    while (lane > 0) {
      lane -= 1;
      label shedding loop {
        if (self.bytes + needed <= capacityBytes) return true;
        if (LaneQueue.laneSize(self.ready, lane) == 0) break shedding;

        let victims = LaneQueue.take<Entry>(self.ready, laneOnly(lane), 1, soonestExpiry);
        if (victims.size() == 0) break shedding;
        forget(self, victims[0].id)
      }
    };
    self.bytes + needed <= capacityBytes
  };

  func laneOnly(only : Nat) : [Nat] = Array.tabulate<Nat>(LANES, func(lane) = if (lane == only) 1 else 0);

  func sizeOf(content : Types.Content) : Nat = Text.size(content.title) + Text.size(content.body) + (
    switch (content.url) { case (?u) Text.size(u); case null 0 }
  ) + 64
}
