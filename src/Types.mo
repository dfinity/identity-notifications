import Time "mo:core/Time";

/// What an app passes in and reads back. Everything else in this library is
/// internal.
module {

  /// How Internet Identity should schedule a notification against the origin's
  /// other traffic. Not a rendering hint: channels without a tray honour it too.
  public type Urgency = { #veryLow; #low; #normal; #high };

  /// What the app describes when it sends.
  public type Notification = {
    title : Text;
    body : Text;
    /// Where acting on it takes them. Must be on the sending origin or one of
    /// its alternative origins; Internet Identity refuses anything else.
    url : ?Text;
    /// What this notification is about. Sending again with the same key
    /// updates that notification rather than adding another, and it is what
    /// `dismiss` names. Derive it from data the sender cannot choose.
    key : ?Text;
    /// `null` is `#normal`.
    urgency : ?Urgency;
    /// `null` is Internet Identity's default retention, which is also its
    /// ceiling.
    expiresAt : ?Time.Time
  };

  /// What a channel pulls back. The rest of a `Notification` never leaves this
  /// canister.
  public type Content = {
    title : Text;
    body : Text;
    url : ?Text
  };

  /// One hour of the delivery pipeline.
  public type Bucket = {
    /// The instant the hour begins, nanoseconds since the epoch.
    start : Time.Time;
    sent : Nat;
    accepted : Nat;
    deferred : Nat;
    received : Nat;
    dropped : Nat
  };

  public type Misconfigured = {
    /// `notification_origin` is unset or unusable.
    #origin;
    /// `notification_sender` is unset or not a principal.
    #sender;
    /// The origin does not publish this canister as one of its senders.
    #notAuthorizedSender
  };

  public type Metrics = {
    /// Up to 720 buckets, oldest first. Hours with no traffic are absent.
    hours : [Bucket];
    /// Notifications waiting for Internet Identity to accept them.
    backlog : Nat;
    misconfigured : ?{ why : Misconfigured; since : Time.Time }
  }
}
