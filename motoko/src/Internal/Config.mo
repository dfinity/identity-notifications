import Prim "mo:⛔";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Types "../Types";
import Origin "Origin";

/// Four environment variables, two of them optional. Read on use, because a
/// canister's environment does not change under it.
module {

  let DEFAULT_CAPACITY_MB : Nat = 1024;

  public type Config = {
    /// `null` where the variable is unset, which `setSender` can still answer
    /// for.
    sender : ?Principal;
    /// The frontend the notifications are sent for.
    origin : Text;
    /// The application whose users receive them, where `origin` is one of its
    /// frontends: the derivation origin that frontend signs in with. `null`
    /// where the variable is unset or empty, and `origin` is the application.
    derivationOrigin : ?Text;
    capacityBytes : Nat
  };

  /// The environment variables, each as it is set or `null`.
  public type Variables = {
    notification_sender : ?Text;
    notification_origin : ?Text;
    notification_derivation_origin : ?Text;
    notification_capacity_mb : ?Text
  };

  /// The canister's environment variables, as a configuration.
  public func read<system>() : { #ok : Config; #err : Types.Misconfigured } {
    fromVariables({
      notification_sender = Runtime.envVar<system>("notification_sender");
      notification_origin = Runtime.envVar<system>("notification_origin");
      notification_derivation_origin = Runtime.envVar<system>("notification_derivation_origin");
      notification_capacity_mb = Runtime.envVar<system>("notification_capacity_mb")
    })
  };

  /// The variables, as a configuration. Missing configuration is reported
  /// rather than guessed at.
  public func fromVariables(variables : Variables) : {
    #ok : Config;
    #err : Types.Misconfigured
  } {
    let ?origin = nonEmpty(variables.notification_origin) else return #err(#origin);

    #ok {
      sender = switch (variables.notification_sender) {
        case (?identity) ?Principal.fromText(identity);
        case null null
      };
      origin;
      derivationOrigin = nonEmpty(variables.notification_derivation_origin);
      capacityBytes = megabytes(variables.notification_capacity_mb) * 1_048_576
    }
  };

  /// The application whose users receive the notifications, and the origin
  /// Internet Identity signs into the caller info of a pull for them.
  public func applicationOrigin(config : Config) : Text = switch (config.derivationOrigin) {
    case (?derivationOrigin) derivationOrigin;
    case null config.origin
  };

  /// Whether an origin Internet Identity signed into a pull's caller info is
  /// this application's, on whichever gateway domain it was spelled.
  public func isApplication(config : Config, origin : Text) : Bool = Origin.fold(origin) == Origin.fold(applicationOrigin(config));

  func nonEmpty(value : ?Text) : ?Text = switch value {
    case (?text) if (Text.size(text) == 0) null else ?text;
    case null null
  };

  func megabytes(value : ?Text) : Nat {
    switch value {
      case (?text) switch (parse(text)) {
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
