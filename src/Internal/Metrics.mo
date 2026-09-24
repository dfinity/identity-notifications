import Array "mo:core/Array";
import List "mo:core/List";
import Time "mo:core/Time";
import Types "../Types";

/// The delivery pipeline, one bucket an hour, thirty days deep.
///
/// Buckets carry the hour they cover, so the ring rolls over lazily: a canister
/// that sends nothing for a week needs no timer keeping empty buckets
/// contiguous, and the quiet hours are simply absent.
module {

  let HOUR : Nat = 3_600_000_000_000;
  let KEEP : Nat = 720;

  public type Counts = {
    start : Time.Time;
    var sent : Nat;
    var accepted : Nat;
    var deferred : Nat;
    var received : Nat;
    var dropped : Nat
  };

  public type State = {
    buckets : List.List<Counts>
  };

  public type Event = {
    #sent;
    #accepted;
    #deferred;
    #received;
    #dropped
  };

  public func empty() : State = { buckets = List.empty<Counts>() };

  public func record(self : State, now : Time.Time, event : Event, count : Nat) {
    let bucket = current(self, now);
    switch event {
      case (#sent) bucket.sent += count;
      case (#accepted) bucket.accepted += count;
      case (#deferred) bucket.deferred += count;
      case (#received) bucket.received += count;
      case (#dropped) bucket.dropped += count
    }
  };

  public func snapshot(self : State) : [Types.Bucket] {
    Array.map<Counts, Types.Bucket>(
      List.toArray(self.buckets),
      func(b) = {
        start = b.start;
        sent = b.sent;
        accepted = b.accepted;
        deferred = b.deferred;
        received = b.received;
        dropped = b.dropped
      }
    )
  };

  func current(self : State, now : Time.Time) : Counts {
    let start = now - (now % HOUR);

    switch (List.last(self.buckets)) {
      case (?latest) if (latest.start == start) return latest;
      case null {}
    };

    let fresh : Counts = {
      start;
      var sent = 0;
      var accepted = 0;
      var deferred = 0;
      var received = 0;
      var dropped = 0
    };
    List.add(self.buckets, fresh);
    prune(self);
    fresh
  };

  func prune(self : State) {
    if (List.size(self.buckets) <= KEEP) return;

    let kept = Array.sliceToArray<Counts>(
      List.toArray(self.buckets),
      List.size(self.buckets) - KEEP,
      List.size(self.buckets)
    );
    List.clear(self.buckets);
    for (bucket in kept.vals()) List.add(self.buckets, bucket)
  }
}
