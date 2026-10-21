import Principal "mo:core/Principal";

/// Internet Identity's app-facing send interface, as the candid declares it.
module {

  public type Notification = {
    id : Nat64;
    recipient : Principal;
    expires_at : ?Nat64;
    urgency : ?{ #VeryLow; #Low; #Normal; #High }
  };

  public type SendNotificationArg = {
    origin : Text;
    notifications : [Notification]
  };

  public type NotAcceptedReason = {
    #NoSuchRecipient;
    #NoChannel;
    #Deferred : { retry_after : Nat64 }
  };

  public type NotAccepted = {
    id : Nat64;
    recipient : Principal;
    reason : NotAcceptedReason
  };

  public type SendNotificationResponse = {
    not_accepted : [NotAccepted]
  };

  public type SendNotificationError = {
    #NoSuchSender;
    #TooManyNotifications : { limit : Nat32 };
    #InternalCanisterError : Text
  };

  public type Service = actor {
    app_send_notification : (SendNotificationArg) -> async {
      #Ok : SendNotificationResponse;
      #Err : SendNotificationError
    }
  };

  public func service(canister : Principal) : Service = actor (canister.toText()) : Service
}
