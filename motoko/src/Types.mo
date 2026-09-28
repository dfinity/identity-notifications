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
    expiresAt : ?Time.Time;
    /// Which funnel to count this notification in, on top of the hour it was
    /// sent in. One campaign, one kind of notification — whatever the app wants
    /// to read a conversion rate for. A funnel costs a row until it is
    /// forgotten, so a label per notification is an unbounded set of
    /// one-notification funnels.
    funnel : ?Text
  };

  /// What a channel pulls back. The rest of a `Notification` never leaves this
  /// canister.
  public type Content = {
    title : Text;
    body : Text;
    url : ?Text
  };

  /// What became of a set of notifications, counted once each and attributed
  /// to where they came in rather than to when each step happened, so the
  /// stages read as one funnel: of `queued`, how many Internet Identity took,
  /// of those how many a channel showed, and of those how many were acted on.
  ///
  /// `deferred` is not a stage — Internet Identity asking to be tried later
  /// delays a notification rather than losing it — and a notification still on
  /// its way is in none of the later counts yet, so gaps in a window that has
  /// not settled are not yet losses.
  public type Counts = {
    /// Every call to `send`, including one the capacity ceiling refused.
    queued : Nat;
    accepted : Nat;
    received : Nat;
    /// Somebody acted on it: the last stage, and the only one that says the
    /// notification did its job. Counted while the notification's own window is
    /// open, which is the period the app declared it relevant for.
    opened : Nat;
    /// Given up on: never accepted before its window closed, or accepted and
    /// expired without any channel showing it.
    dropped : Nat;
    /// How often Internet Identity asked for one to come back later.
    deferred : Nat
  };

  /// One hour of the delivery pipeline.
  public type Bucket = {
    /// The instant the hour begins, nanoseconds since the epoch.
    start : Time.Time;
    counts : Counts
  };

  /// What became of the notifications an app labelled with one funnel name.
  public type Funnel = {
    name : Text;
    counts : Counts
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
    /// One per funnel an app has labelled, until it forgets it.
    funnels : [Funnel];
    /// Notifications waiting for Internet Identity to accept them.
    backlog : Nat;
    misconfigured : ?{ why : Misconfigured; since : Time.Time }
  }
}
