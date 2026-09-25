import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Time "mo:core/Time";
import Timer "mo:core/Timer";
import CallerInfo "Internal/CallerInfo";
import Config "Internal/Config";
import Flush "Internal/Flush";
import II "Internal/II";
import Metrics "Internal/Metrics";
import Outbox "Internal/Outbox";
import Types "Types";

/// Notify Internet Identity users from a Motoko canister.
///
/// ```motoko
/// persistent actor {
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
  /// Transient because a timer does not survive an upgrade: a canister that
  /// came back believing one was armed would never arm another.
  transient var flushArmed : Bool = false;
  transient var flushing : Bool = false;
  transient var senderOverride : ?Principal = null;

  transient let notifications = object {

    /// Sends a notification, or updates the one this recipient's `key` already
    /// names. Never traps, never awaits: a notification is an aside to
    /// whatever the app was actually doing.
    public func send<system>(recipient : Principal, notification : Types.Notification) {
      switch configured {
        case (#err(why)) {
          note(why);
          Metrics.record(pipeline, Time.now(), #dropped, 1)
        };
        case (#ok(config)) {
          let now = Time.now();
          if (sender(config) == null) {
            note(#sender);
            Metrics.record(pipeline, now, #dropped, 1);
            return
          };
          let added = Outbox.add(
            outbox,
            recipient,
            notification,
            now + II_DEFAULT_RETENTION,
            config.capacityBytes,
            now
          );
          switch added {
            case null Metrics.record(pipeline, now, #dropped, 1);
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
      Outbox.dismiss(outbox, recipient, key)
    };

    public func metrics() : Types.Metrics = {
      hours = Metrics.snapshot(pipeline);
      backlog = Outbox.backlog(outbox);
      misconfigured
    }
  };

  /// Called by Internet Identity, not by the app, once a channel has a
  /// notification to render.
  ///
  /// An update rather than a query because Motoko cannot read caller info from
  /// a query, and without it a pull would hand any notification's content to
  /// anyone who guessed its id.
  public shared func _internet_identity_notification_content(
    id : Nat64
  ) : async ?Types.Content {
    let ?_ = senderInfo<system>() else return null;
    Outbox.contentOf(outbox, id)
  };

  /// Delivered. Content stays until it expires, because another of the user's
  /// devices may still pull it.
  public shared func _internet_identity_notification_received(id : Nat64) : async () {
    let ?_ = senderInfo<system>() else return;
    if (Outbox.holds(outbox, id)) {
      Metrics.record(pipeline, Time.now(), #received, 1)
    }
  };

  /// Internet Identity signed this call's caller info, and it names our own
  /// origin. Anything else is not ours to answer.
  func senderInfo<system>() : ?CallerInfo.SenderInfo {
    let #ok(config) = configured else return null;
    let ?signer = sender(config) else return null;
    let ?info = CallerInfo.read<system>(signer) else return null;
    if (info.origin != config.origin) return null;
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

  func arm<system>() {
    if (flushArmed or flushing) return;
    flushArmed := true;
    ignore Timer.setTimer<system>(
      #nanoseconds COALESCE,
      func() : async () { await flush() }
    )
  };

  func flush() : async () {
    flushArmed := false;
    if (flushing) return;

    let config = switch configured {
      case (#err(why)) { note(why); return };
      case (#ok(c)) c
    };
    let ?signer = sender(config) else { note(#sender); return };

    if (not seeded) {
      seeded := true;
      try {
        Outbox.seed(outbox, await randomness.raw_rand())
      } catch (_) {}
    };

    let now = Time.now();
    Outbox.sweep(outbox, now);
    Outbox.promote(outbox, now);
    let (batch, expired) = Outbox.sendable(outbox, Outbox.take(outbox, batchLimit), now);
    if (expired > 0) Metrics.record(pipeline, now, #dropped, expired);
    if (batch.size() == 0) return;

    flushing := true;
    let outcome = try {
      switch (await II.service(signer).app_send_notification(Flush.arg(config.origin, batch))) {
        case (#Ok(response)) #answered(response.not_accepted);
        case (#Err(#TooManyNotifications { limit })) #tooMany(Nat64.toNat(Nat64.fromNat32(limit)));
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
    if (Outbox.backlog(outbox) > 0) arm<system>()
  };

  // Runs on every install and every upgrade. A timer does not survive one, so
  // an outbox that did is picked up here rather than waiting for a send.
  if (Outbox.backlog(outbox) > 0) arm<system>()
}
