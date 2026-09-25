import Int "mo:core/Int";
import Map "mo:core/Map";
import Nat64 "mo:core/Nat64";
import Order "mo:core/Order";
import Principal "mo:core/Principal";
import PriorityQueue "mo:core/PriorityQueue";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Ids "Ids";
import LaneQueue "LaneQueue";
import Types "../Types";

/// What is waiting to be sent, and what a channel may still pull.
///
/// Entries live in lanes by urgency while they are ready to go, and in a
/// parking queue while they wait for the second attempt a refusal earns them.
module {

  public let LANES : Nat = 4;
  public let WEIGHTS : [Nat] = [8, 4, 2, 1];

  /// How long before a notification expires its second attempt is made. Long
  /// enough that a user has the window to come back, early enough that the
  /// attempt itself is not refused for being past the expiry.
  let RETRY_LEAD : Int = 300_000_000_000;

  public type Entry = {
    id : Nat64;
    recipient : Principal;
    lane : Nat;
    expiresAt : Time.Time;
    var dueAt : Time.Time;
    var parked : Bool
  };

  public type State = {
    ready : LaneQueue.State<Entry>;
    parked : PriorityQueue.PriorityQueue<Entry>;
    content : Map.Map<Nat64, Types.Content>;
    received : Map.Map<Nat64, Bool>;
    /// Every notification waiting to be accepted, by id, so a repeat of a key
    /// updates what is already queued instead of queueing a second attempt.
    entries : Map.Map<Nat64, Entry>;
    var counter : Nat64;
    var bytes : Nat
  };

  public func empty() : State = {
    ready = LaneQueue.empty<Entry>(LANES);
    parked = PriorityQueue.empty<Entry>();
    content = Map.empty<Nat64, Types.Content>();
    received = Map.empty<Nat64, Bool>();
    entries = Map.empty<Nat64, Entry>();
    var counter = 0;
    var bytes = 0
  };

  public func lane(urgency : ?Types.Urgency) : Nat = switch urgency {
    case (?#high) 0;
    case (null or ?#normal) 1;
    case (?#low) 2;
    case (?#veryLow) 3
  };

  public func soonestExpiry(a : Entry, b : Entry) : Order.Order = Int.compare(a.expiresAt, b.expiresAt);

  public func soonestDue(a : Entry, b : Entry) : Order.Order = Int.compare(a.dueAt, b.dueAt);

  /// Adds a notification, or replaces the one its key already names.
  public func add(
    self : State,
    recipient : Principal,
    notification : Types.Notification,
    defaultExpiry : Time.Time,
    capacityBytes : Nat,
    now : Time.Time
  ) : ?Nat64 {
    let id = switch (notification.key) {
      case (?key) Ids.keyed(recipient, key);
      case null {
        self.counter += 1;
        Ids.keyless(self.counter)
      }
    };

    let content : Types.Content = {
      title = notification.title;
      body = notification.body;
      url = notification.url
    };
    let size = sizeOf(content);

    // Replacing a notification frees what the old one held, so an app that
    // updates the same key forever occupies one notification's worth of room.
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

    // Already waiting — queued, parked or deferred. Its content has just been
    // replaced, so the entry itself stands: queueing a second one would
    // attempt the same notification twice.
    switch (Map.get(self.entries, Nat64.compare, id)) {
      case (?_) return ?id;
      case null {}
    };

    let entry : Entry = {
      id;
      recipient;
      lane = lane(notification.urgency);
      expiresAt;
      var dueAt = now;
      var parked = false
    };
    Map.add(self.entries, Nat64.compare, id, entry);
    LaneQueue.push<Entry>(self.ready, entry.lane, entry, soonestExpiry);
    ?id
  };

  /// Internet Identity took it. Nothing more to send, so the entry goes; its
  /// content stays until a channel has had its chance to pull it.
  public func settle(self : State, entry : Entry) {
    Map.remove(self.entries, Nat64.compare, entry.id)
  };

  /// Moves parked entries back into their lanes once their second attempt is
  /// due, so a flush only ever sees what it may send now.
  public func promote(self : State, now : Time.Time) {
    label promoting loop {
      switch (PriorityQueue.peek(self.parked)) {
        case (?entry) {
          if (entry.dueAt > now) break promoting;
          ignore PriorityQueue.pop(self.parked, furthestDue);
          LaneQueue.push<Entry>(self.ready, entry.lane, entry, soonestExpiry)
        };
        case null break promoting
      }
    }
  };

  public func take(self : State, count : Nat) : [Entry] = LaneQueue.take<Entry>(self.ready, WEIGHTS, count, soonestExpiry);

  /// A refusal earns one more attempt, just before the notification expires,
  /// which is the whole window the user has to sign in or turn notifications
  /// on. A second refusal drops it.
  public func park(self : State, entry : Entry) : Bool {
    if (entry.parked) {
      Map.remove(self.entries, Nat64.compare, entry.id);
      release(self, entry.id);
      return false
    };
    entry.parked := true;
    entry.dueAt := entry.expiresAt - RETRY_LEAD;
    PriorityQueue.push(self.parked, furthestDue, entry);
    true
  };

  /// Deferral is Internet Identity asking for the same entry later, not a
  /// refusal, so the entry goes back to its lane with a new due time.
  public func defer(self : State, entry : Entry, retryAfter : Time.Time) {
    entry.dueAt := retryAfter;
    PriorityQueue.push(self.parked, furthestDue, entry)
  };

  /// Puts an entry back in its lane unchanged, for when nothing was enqueued
  /// and the send simply has to happen again.
  public func requeue(self : State, entry : Entry) {
    LaneQueue.push<Entry>(self.ready, entry.lane, entry, soonestExpiry)
  };

  /// The app says this no longer needs anyone's attention. The content goes,
  /// so a pull finds nothing and a channel that sweeps can close it.
  public func dismiss(self : State, recipient : Principal, key : Text) {
    release(self, Ids.keyed(recipient, key))
  };

  /// A channel delivered it. Recorded rather than acted on: other devices may
  /// still pull the same notification, so content stays until it expires.
  public func markReceived(self : State, id : Nat64) {
    Map.add(self.received, Nat64.compare, id, true)
  };

  public func wasReceived(self : State, id : Nat64) : Bool = switch (Map.get(self.received, Nat64.compare, id)) {
    case (?_) true;
    case null false
  };

  public func release(self : State, id : Nat64) {
    switch (Map.get(self.content, Nat64.compare, id)) {
      case (?content) {
        self.bytes -= sizeOf(content);
        Map.remove(self.content, Nat64.compare, id);
        Map.remove(self.received, Nat64.compare, id)
      };
      case null {}
    }
  };

  public func contentOf(self : State, id : Nat64) : ?Types.Content = Map.get(self.content, Nat64.compare, id);

  public func backlog(self : State) : Nat = LaneQueue.size(self.ready) + PriorityQueue.size(self.parked);

  /// Nothing accepted is ever shed: Internet Identity may still deliver it and
  /// a pull has to find content. What goes is the outbox, lowest lane first
  /// and newest first within it, which is the tail of a campaign rather than
  /// the notification behind it.
  func shed(self : State, capacityBytes : Nat, needed : Nat) : Bool {
    var lane = LANES;
    while (lane > 0) {
      lane -= 1;
      label shedding loop {
        if (self.bytes + needed <= capacityBytes) return true;
        if (LaneQueue.laneSize(self.ready, lane) == 0) break shedding;

        let victims = LaneQueue.take<Entry>(self.ready, laneOnly(lane), 1, furthestExpiry);
        if (victims.size() == 0) break shedding;
        release(self, victims[0].id)
      }
    };
    self.bytes + needed <= capacityBytes
  };

  func laneOnly(lane : Nat) : [Nat] {
    let weights : [var Nat] = [var 0, 0, 0, 0];
    weights[lane] := 1;
    Array_freeze(weights)
  };

  func Array_freeze(weights : [var Nat]) : [Nat] = [weights[0], weights[1], weights[2], weights[3]];

  func furthestExpiry(a : Entry, b : Entry) : Order.Order = Int.compare(b.expiresAt, a.expiresAt);

  func furthestDue(a : Entry, b : Entry) : Order.Order = Int.compare(a.dueAt, b.dueAt);

  func sizeOf(content : Types.Content) : Nat = Text.size(content.title) + Text.size(content.body) + (
    switch (content.url) { case (?u) Text.size(u); case null 0 }
  ) + 64
}
