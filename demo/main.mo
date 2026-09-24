import Principal "mo:core/Principal";
import Notifications "../src/lib";
import Types "../src/Types";

persistent actor {
  include Notifications<system>();

  public shared ({ caller }) func sendMessage(to : Principal, text : Text) : async () {
    notifications.send<system>(
      to,
      {
        title = "New message";
        body = text;
        url = ?("https://chat.example.com/chats/" # Principal.toText(caller));
        key = ?("chat-" # Principal.toText(caller));
        urgency = null;
        expiresAt = null;
      }
    )
  };

  public shared ({ caller }) func markRead(conversation : Text) : async () {
    notifications.dismiss(caller, conversation)
  };

  public query func deliveryMetrics() : async Types.Metrics {
    notifications.metrics()
  };
}
