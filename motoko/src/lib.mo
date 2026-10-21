import Int "mo:core/Int";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Time "mo:core/Time";
import Timer "mo:core/Timer";
import CallerInfo "Internal/CallerInfo";
import Config "Internal/Config";
import Flush "Internal/Flush";
import II "Internal/II";
import Metrics "Internal/Metrics";
import Origin "Internal/Origin";
import Outbox "Internal/Outbox";
import Types "Types";

/// Notify Internet Identity users from a Motoko canister.
///
/// ```motoko
/// actor {
///   include Notifications<system>();
///
///   public shared ({ caller }) func sendMessage(to : Principal, text : Text) : async () {
///     notifications.send(to, {
///       title = "New message"; body = text; url = null;
///       key = ?("chat-" # Principal.toText(caller));
///       urgency = null; expiresAt = null;
///     });
///   };
/// };
/// ```
///
/// Configured by environment variables: `notification_sender`,
/// `notification_origin`, and optionally `notification_capacity_mb`.
mixin<system>() {

  /// How long sends accumulate before one call carries them. Urgency decides
  /// which lane drains first, not call timing, so everything waits for it.
  let COALESCE : Nat = 2_000_000_000;

  /// What Internet Identity accepts in one call, until `TooManyNotifications`
  /// says otherwise.
  let BATCH_GUESS : Nat = 1_000;

  /// Internet Identity's own default, mirrored so the outbox orders and
  /// expires notifications by the window they actually have.
  let II_DEFAULT_RETENTION : Int = 300_000_000_000;

  let configured = Config.read<system>();
  transient let randomness = actor "aaaaa-aa" : actor {
    raw_rand : () -> async Blob
  };

  let outbox = Outbox.empty();
  let pipeline = Metrics.empty();

  var batchLimit : Nat = BATCH_GUESS;
  var misconfigured : ?{ why : Types.Misconfigured; since : Time.Time } = null;
  var seeded : Bool = false;
  /// The wake-up that is set, and when it fires, so a nearer one can take its
  /// place. Transient because a timer does not survive an upgrade: a canister
  /// that came back believing one was armed would never arm another.
  transient var armed : ?(Timer.TimerId, Time.Time) = null;
  transient var flushing : Bool = false;
  transient var senderOverride : ?Principal = null;

  transient let notifications = object {

    /// Sends a notification, or updates the one this recipient's `key` already
    /// names. Never traps, never awaits: a notification is an aside to
    /// whatever the app was actually doing.
    public func send<system>(recipient : Principal, notification : Types.Notification) {
      // The app asked, so the hour and the funnel it asked in count the ask,
      // whether or not there is anything to send it through.
      let now = Time.now();
      let hour = Metrics.hourOf(now);
      switch (notification.funnel) {
        case (?name) pipeline.openFunnel(name);
        case null {}
      };
      countAsk(hour, notification.funnel, #queued);

      switch configured {
        case (#err(why)) {
          note(why);
          countAsk(hour, notification.funnel, #dropped)
        };
        case (#ok(config)) {
          if (sender(config) == null) {
            note(#sender);
            countAsk(hour, notification.funnel, #dropped);
            return
          };
          let added = outbox.add(
            recipient,
            notification,
            now + II_DEFAULT_RETENTION,
            config.capacityBytes,
            now
          );
          switch added {
            case null countAsk(hour, notification.funnel, #dropped);
            case (?_) arm<system>()
          }
        }
      }
    };

    /// Sends through this canister, and trusts it on a pull, in place of the
    /// `notification_sender` variable; `null` goes back to the variable. For a
    /// test canister retargeting Internet Identity at runtime, and not
    /// remembered across an upgrade.
    public func setSender(sender : ?Principal) {
      senderOverride := sender
    };

    /// This notification no longer needs anyone's attention. Its content goes,
    /// so a pull finds nothing and a channel that sweeps can close it.
    public func dismiss(recipient : Principal, key : Text) {
      outbox.dismiss(recipient, key)
    };

    public func metrics() : Types.Metrics = {
      hours = pipeline.snapshot();
      funnels = pipeline.funnels();
      backlog = outbox.backlog();
      misconfigured
    };

    /// Drops a funnel's row. What it counted goes with it, and notifications
    /// still carrying it are counted in their hour alone.
    public func forgetFunnel(name : Text) {
      pipeline.forgetFunnel(name)
    }
  };

  /// A step of a notification that has no entry yet: the ask itself.
  func countAsk(hour : Time.Time, funnel : ?Text, event : Metrics.Event) {
    pipeline.record(hour, event, 1);
    switch funnel {
      case (?name) pipeline.recordFunnel(name, event, 1);
      case null {}
    }
  };

  /// Called by Internet Identity, not by the app, once a channel has a
  /// notification to render.
  public shared query func _internet_identity_notification_content(
    id : Nat64
  ) : async ?Types.Content {
    let ?_ = senderInfo() else return null;
    outbox.contentOf(id)
  };

  /// Delivered. Content stays until it expires, because another of the user's
  /// devices may still pull it.
  public shared func _internet_identity_notification_received(id : Nat64) : async () {
    let ?_ = senderInfo() else return;
    if (not outbox.holds(id)) return;
    if (not outbox.markReceived(id)) return;
    switch (outbox.entryOf(id)) {
      case (?entry) Flush.count(pipeline, entry, #received);
      case null {}
    }
  };

  /// Somebody acted on the notification a channel showed them.
  public shared func _internet_identity_notification_opened(id : Nat64) : async () {
    let ?_ = senderInfo() else return;
    if (not outbox.markOpened(id)) return;
    switch (outbox.entryOf(id)) {
      case (?entry) Flush.count(pipeline, entry, #opened);
      case null {}
    }
  };

  /// Internet Identity signed this call's caller info, and it names our own
  /// origin. Anything else is not ours to answer.
  func senderInfo() : ?CallerInfo.SenderInfo {
    let #ok(config) = configured else return null;
    let ?signer = sender(config) else return null;
    let ?info = CallerInfo.read(signer) else return null;
    if (Origin.fold(info.origin) != Origin.fold(config.origin)) return null;
    ?info
  };

  /// Who this canister sends through, and whose caller info it trusts: what
  /// `setSender` was given, or the configured variable.
  func sender(config : Config.Config) : ?Principal = switch senderOverride {
    case (?override_) ?override_;
    case null config.sender
  };

  func note(why : Types.Misconfigured) {
    switch misconfigured {
      case (?current) if (current.why == why) return;
      case null {}
    };
    misconfigured := ?{ why; since = Time.now() }
  };

  /// Sets the wake-up for when the outbox next has something to do: the
  /// coalesce window where anything is waiting, the due time where an entry is
  /// parked for later, and no timer at all for an empty outbox. A call in
  /// flight carries its own wake-up, and one already set for later gives way to
  /// a nearer one.
  func arm<system>() {
    if (flushing) return;
    let ?due = outbox.nextDue() else return;

    let now = Time.now();
    let soonest = now + COALESCE;
    let at = if (due > soonest) due else soonest;
    switch armed {
      case (?(_, when)) if (when <= at) return;
      case null {}
    };
    switch armed {
      case (?(timer, _)) Timer.cancelTimer(timer);
      case null {}
    };
    armed := ?(
      Timer.setTimer<system>(
        #nanoseconds(Int.abs(at - now)),
        func() : async () { await flush() }
      ),
      at
    )
  };

  func flush() : async () {
    armed := null;
    if (flushing) return;

    let config = switch configured {
      case (#err(why)) { note(why); return };
      case (#ok(c)) c
    };
    let ?signer = sender(config) else { note(#sender); return };

    if (not seeded) {
      seeded := true;
      try {
        outbox.seed(await randomness.raw_rand())
      } catch (_) {}
    };

    let now = Time.now();
    // Internet Identity held them and no channel ever showed them, which is the
    // delivery pipeline's quietest loss.
    for (entry in outbox.sweep(now).values()) {
      Flush.count(pipeline, entry, #dropped)
    };
    outbox.promote(now);
    let (batch, expired) = outbox.sendable(outbox.take(batchLimit), now);
    for (entry in expired.values()) {
      Flush.count(pipeline, entry, #dropped)
    };

    // Nothing is sendable yet: a parked entry still has its turn coming.
    if (batch.size() == 0) return arm<system>();

    flushing := true;
    let outcome = try {
      switch (await II.service(signer).app_send_notification(Flush.arg(config.origin, batch))) {
        case (#Ok(response)) #answered(response.not_accepted);
        case (#Err(#TooManyNotifications { limit })) #tooMany(Nat64.fromNat32(limit).toNat());
        case (#Err(#NoSuchSender)) #notAuthorized;
        case (#Err(#InternalCanisterError(_))) #unreachable
      }
    } catch (_) {
      #unreachable
    };
    flushing := false;

    switch outcome {
      case (#tooMany(limit)) batchLimit := limit;
      case (#notAuthorized) note(#notAuthorizedSender);
      case (_) {}
    };

    Flush.apply(outbox, pipeline, batch, outcome, now);
    arm<system>()
  };

  // Runs on every install and every upgrade. A timer does not survive one, so
  // an outbox that did is picked up here rather than waiting for a send. A
  // fresh install has nothing queued, which arming answers with no timer.
  arm<system>()
}
