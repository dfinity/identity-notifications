import Array "mo:core/Array";
import Int "mo:core/Int";
import Map "mo:core/Map";
import Nat64 "mo:core/Nat64";
import Time "mo:core/Time";
import II "II";
import Metrics "Metrics";
import Outbox "Outbox";

/// What a flush decides, with no `await` in sight: the async shell builds a
/// batch, makes the call, and hands the answer back here.
module {

  public type Outcome = {
    /// The origin does not publish this canister as one of its senders.
    #notAuthorized;
    /// The batch was too large, and nothing in it was enqueued.
    #tooMany : Nat;
    /// Sent, with whatever Internet Identity would not take.
    #answered : [II.NotAccepted];
    /// The call itself failed.
    #unreachable
  };

  public func arg(origin : Text, batch : [Outbox.Entry]) : II.SendNotificationArg = {
    origin;
    notifications = Array.map<Outbox.Entry, II.Notification>(
      batch,
      func(entry) = {
        id = entry.id;
        recipient = entry.recipient;
        expires_at = ?Nat64.fromNat(Int.abs(entry.expiresAt));
        urgency = ?urgencyOf(entry.lane)
      }
    )
  };

  /// Applies an outcome to the batch that produced it.
  public func apply(
    outbox : Outbox.State,
    pipeline : Metrics.State,
    batch : [Outbox.Entry],
    outcome : Outcome,
    now : Time.Time
  ) {
    switch outcome {
      case (#answered(notAccepted)) {
        let refused = Map.empty<Nat64, II.NotAcceptedReason>();
        for (entry in notAccepted.values()) {
          Map.add(refused, Nat64.compare, entry.id, entry.reason)
        };

        for (entry in batch.values()) {
          switch (Map.get(refused, Nat64.compare, entry.id)) {
            case null {
              count(pipeline, entry, #accepted);
              Outbox.settle(outbox, entry)
            };
            case (?#Deferred { retry_after }) {
              count(pipeline, entry, #deferred);
              Outbox.defer(outbox, entry, Nat64.toNat(retry_after))
            };
            case (?_) {
              // No such recipient, or no channel: the user fixes both, and has
              // until the notification expires to do it.
              if (not Outbox.park(outbox, entry, now)) {
                count(pipeline, entry, #dropped)
              }
            }
          }
        }
      };

      case (#unreachable) {
        for (entry in batch.values()) {
          if (not Outbox.park(outbox, entry, now)) {
            count(pipeline, entry, #dropped)
          }
        }
      };

      case (#tooMany(_) or #notAuthorized) {
        for (entry in batch.values()) {
          Outbox.requeue(outbox, entry, now)
        }
      }
    }
  };

  func urgencyOf(lane : Nat) : { #VeryLow; #Low; #Normal; #High } = switch lane {
    case 0 #High;
    case 1 #Normal;
    case 2 #Low;
    case _ #VeryLow
  };

  /// A step counts in the hour its notification came in, and in the funnel its
  /// app named.
  public func count(pipeline : Metrics.State, entry : Outbox.Entry, event : Metrics.Event) {
    Metrics.record(pipeline, entry.queuedHour, event, 1);
    switch (entry.funnel) {
      case (?name) Metrics.recordFunnel(pipeline, name, event, 1);
      case null {}
    }
  }
}
