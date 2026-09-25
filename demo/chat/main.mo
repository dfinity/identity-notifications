import List "mo:core/List";
import Map "mo:core/Map";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Notifications "../../src/lib";
import Types "../../src/Types";

/// A chat app, to show what using the library looks like from the outside:
/// one-to-one conversations and groups, and three calls into the library.
persistent actor {

  include Notifications<system>();

  type Message = { from : Principal; text : Text; at : Time.Time };

  type Conversation = {
    id : Text;
    members : [Principal];
    messages : List.List<Message>;
  };

  let conversations = Map.empty<Text, Conversation>();
  let readUpTo = Map.empty<Principal, Map.Map<Text, Time.Time>>();

  /// One-to-one conversations are named by their two members, so both sides
  /// arrive at the same one.
  func directId(a : Principal, b : Principal) : Text {
    let x = Principal.toText(a);
    let y = Principal.toText(b);
    if (x < y) x # "|" # y else y # "|" # x
  };

  public shared ({ caller }) func createGroup(name : Text, members : [Principal]) : async Text {
    let id = "group:" # name;
    Map.add(
      conversations,
      Text.compare,
      id,
      { id; members = withCaller(members, caller); messages = List.empty<Message>() }
    );
    id
  };

  public shared ({ caller }) func sendDirect(to : Principal, text : Text) : async () {
    let id = directId(caller, to);
    let conversation = switch (Map.get(conversations, Text.compare, id)) {
      case (?existing) existing;
      case null {
        let fresh = { id; members = [caller, to]; messages = List.empty<Message>() };
        Map.add(conversations, Text.compare, id, fresh);
        fresh
      }
    };
    post<system>(conversation, caller, text)
  };

  public shared ({ caller }) func sendToGroup(id : Text, text : Text) : async () {
    switch (Map.get(conversations, Text.compare, id)) {
      case (?conversation) post<system>(conversation, caller, text);
      case null {}
    }
  };

  /// Everyone in the conversation except the sender hears about it.
  func post<system>(conversation : Conversation, from : Principal, text : Text) {
    List.add(conversation.messages, { from; text; at = Time.now() });

    for (member in conversation.members.values()) {
      if (member != from) {
        notifications.send<system>(
          member,
          {
            title = title(conversation, from);
            body = text;
            url = ?("https://chat.example.com/c/" # conversation.id);
            key = ?conversation.id;
            urgency = null;
            expiresAt = null
          }
        )
      }
    }
  };

  /// Read state is a marker: it moves forward as they read and back when they
  /// mark something unread again. The notification is stale only once nothing
  /// in the conversation is unread.
  public shared ({ caller }) func markRead(id : Text, upTo : Time.Time) : async () {
    let mine = switch (Map.get(readUpTo, Principal.compare, caller)) {
      case (?existing) existing;
      case null {
        let fresh = Map.empty<Text, Time.Time>();
        Map.add(readUpTo, Principal.compare, caller, fresh);
        fresh
      }
    };
    Map.add(mine, Text.compare, id, upTo);

    switch (Map.get(conversations, Text.compare, id)) {
      case (?conversation) switch (List.last(conversation.messages)) {
        case (?newest) if (upTo >= newest.at) notifications.dismiss(caller, id);
        case null {}
      };
      case null {}
    }
  };

  public query func deliveryMetrics() : async Types.Metrics {
    notifications.metrics()
  };

  func title(conversation : Conversation, from : Principal) : Text {
    if (conversation.members.size() > 2) {
      conversation.id # " · " # Principal.toText(from)
    } else {
      Principal.toText(from)
    }
  };

  func withCaller(members : [Principal], caller : Principal) : [Principal] {
    for (member in members.values()) {
      if (member == caller) return members
    };
    let all = List.empty<Principal>();
    List.add(all, caller);
    for (member in members.values()) List.add(all, member);
    List.toArray(all)
  }
}
