import Array "mo:core/Array";
import Int "mo:core/Int";
import Map "mo:core/Map";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Types "../Types";

/// The delivery pipeline: one bucket an hour, thirty days deep, and one per
/// funnel an app has named.
///
/// A step is counted in the hour the notification came in rather than the hour
/// it happens, so a bucket describes one cohort and reads as a funnel. Buckets
/// carry the hour they cover, so an hour with no traffic is absent rather than
/// zero-filled.
module {

  let HOUR : Nat = 3_600_000_000_000;
  let KEEP : Nat = 720;

  public type Counts = {
    var queued : Nat;
    var accepted : Nat;
    var received : Nat;
    var opened : Nat;
    var dropped : Nat;
    var deferred : Nat
  };

  public type State = {
    hours : Map.Map<Time.Time, Counts>;
    funnels : Map.Map<Text, Counts>
  };

  public type Event = {
    #queued;
    #accepted;
    #received;
    #opened;
    #dropped;
    #deferred
  };

  public func empty() : State = {
    hours = Map.empty<Time.Time, Counts>();
    funnels = Map.empty<Text, Counts>()
  };

  /// The hour a notification queued at `now` belongs to, which is the hour
  /// every step it takes is counted in.
  public func hourOf(now : Time.Time) : Time.Time = now - (now % HOUR);

  /// `at` is any instant in the hour the notification came in: its own stamp,
  /// or the clock for a notification coming in now.
  public func record(self : State, at : Time.Time, event : Event, count : Nat) {
    bump(hourly(self, hourOf(at)), event, count)
  };

  /// A funnel an app has forgotten is not brought back by a notification still
  /// carrying it.
  public func recordFunnel(self : State, name : Text, event : Event, count : Nat) {
    switch (self.funnels.get(Text.compare, name)) {
      case (?counts) bump(counts, event, count);
      case null {}
    }
  };

  /// Opens a funnel's row where the app has not used this label before.
  public func openFunnel(self : State, name : Text) {
    switch (self.funnels.get(Text.compare, name)) {
      case (?_) {};
      case null self.funnels.add(Text.compare, name, fresh())
    }
  };

  /// Drops a funnel's row. What it counted goes with it.
  public func forgetFunnel(self : State, name : Text) {
    self.funnels.remove(Text.compare, name)
  };

  public func snapshot(self : State) : [Types.Bucket] {
    self.hours.toArray().map<(Time.Time, Counts), Types.Bucket>(
      func((start, counts)) = { start; counts = read(counts) }
    )
  };

  public func funnels(self : State) : [Types.Funnel] {
    self.funnels.toArray().map<(Text, Counts), Types.Funnel>(
      func((name, counts)) = { name; counts = read(counts) }
    )
  };

  func bump(counts : Counts, event : Event, count : Nat) {
    switch event {
      case (#queued) counts.queued += count;
      case (#accepted) counts.accepted += count;
      case (#received) counts.received += count;
      case (#opened) counts.opened += count;
      case (#dropped) counts.dropped += count;
      case (#deferred) counts.deferred += count
    }
  };

  func read(counts : Counts) : Types.Counts = {
    queued = counts.queued;
    accepted = counts.accepted;
    received = counts.received;
    opened = counts.opened;
    dropped = counts.dropped;
    deferred = counts.deferred
  };

  func hourly(self : State, hour : Time.Time) : Counts {
    switch (self.hours.get(Int.compare, hour)) {
      case (?counts) counts;
      case null {
        let counts = fresh();
        self.hours.add(Int.compare, hour, counts);
        prune(self);
        counts
      }
    }
  };

  func prune(self : State) {
    while (self.hours.size() > KEEP) {
      switch (self.hours.entries().next()) {
        case (?(oldest, _)) self.hours.remove(Int.compare, oldest);
        case null return
      }
    }
  };

  func fresh() : Counts = {
    var queued = 0;
    var accepted = 0;
    var received = 0;
    var opened = 0;
    var dropped = 0;
    var deferred = 0
  }
}
