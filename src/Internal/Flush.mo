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
    /// Internet Identity refuses everything from this canister until the
    /// origin publishes it as a sender.
    #notAuthorized;
    /// The batch was too large. Nothing was enqueued, so it is safe to split
    /// and send again — and the limit is worth remembering.
    #tooMany : Nat;
    /// Sent, with whatever Internet Identity would not take.
    #answered : [II.NotAccepted];
    /// The call itself failed. Entries go back for their second attempt.
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

  /// Applies an outcome to the batch that produced it. Entries not named in
  /// `not_accepted` were taken, so they are simply gone from the outbox — what
  /// remains is content a channel may pull.
  public func apply(
    outbox : Outbox.State,
    pipeline : Metrics.State,
    batch : [Outbox.Entry],
    outcome : Outcome,
    now : Time.Time
  ) {
    Metrics.record(pipeline, now, #sent, batch.size());

    switch outcome {
      case (#answered(notAccepted)) {
        let refused = Map.empty<Nat64, II.NotAcceptedReason>();
        for (entry in notAccepted.values()) {
          Map.add(refused, Nat64.compare, entry.id, entry.reason)
        };

        Metrics.record(pipeline, now, #accepted, batch.size() - notAccepted.size());

        for (entry in batch.values()) {
          switch (Map.get(refused, Nat64.compare, entry.id)) {
            case null {};
            case (?#Deferred { retry_after }) {
              Metrics.record(pipeline, now, #deferred, 1);
              Outbox.defer(outbox, entry, Nat64.toNat(retry_after))
            };
            case (?_) {
              // No such recipient, or no channel: the user fixes both, and has
              // until the notification expires to do it.
              if (not Outbox.park(outbox, entry)) {
                Metrics.record(pipeline, now, #dropped, 1)
              }
            }
          }
        }
      };

      case (#unreachable) {
        for (entry in batch.values()) {
          if (not Outbox.park(outbox, entry)) {
            Metrics.record(pipeline, now, #dropped, 1)
          }
        }
      };

      case (#tooMany(_) or #notAuthorized) {
        // Nothing was enqueued. The entries go back where they came from, to
        // be sent again once the batch is split or the origin is fixed.
        for (entry in batch.values()) {
          entry.dueAt := now;
          Outbox.requeue(outbox, entry)
        }
      }
    }
  };

  func urgencyOf(lane : Nat) : { #VeryLow; #Low; #Normal; #High } = switch lane {
    case 0 #High;
    case 1 #Normal;
    case 2 #Low;
    case _ #VeryLow
  }
}
