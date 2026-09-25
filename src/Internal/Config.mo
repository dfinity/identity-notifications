import Prim "mo:⛔";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Types "../Types";

/// Two environment variables and a default. Read once, because a canister's
/// environment does not change under it.
module {

  let DEFAULT_CAPACITY_MB : Nat = 1024;

  public type Config = {
    sender : Principal;
    origin : Text;
    capacityBytes : Nat
  };

  /// Missing configuration is a deployment mistake rather than something an
  /// app can handle, so it is reported rather than guessed at.
  public func read<system>() : { #ok : Config; #err : Types.Misconfigured } {
    let ?origin = Runtime.envVar<system>("notification_origin") else return #err(#origin);
    if (Text.size(origin) == 0) return #err(#origin);

    let ?identity = Runtime.envVar<system>("notification_sender") else return #err(#sender);

    #ok {
      sender = Principal.fromText(identity);
      origin;
      capacityBytes = megabytes<system>() * 1_048_576
    }
  };

  func megabytes<system>() : Nat {
    switch (Runtime.envVar<system>("notification_capacity_mb")) {
      case (?value) switch (parse(value)) {
        case (?mb) mb;
        case null DEFAULT_CAPACITY_MB
      };
      case null DEFAULT_CAPACITY_MB
    }
  };

  func parse(value : Text) : ?Nat {
    var total : Nat = 0;
    var digits = 0;
    for (char in value.chars()) {
      let code = Prim.charToNat32(char);
      if (code < 48 or code > 57) return null;
      total := total * 10 + Prim.nat32ToNat(code - 48);
      digits += 1
    };
    if (digits == 0) null else ?total
  }
}
