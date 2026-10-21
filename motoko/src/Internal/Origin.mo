import Text "mo:core/Text";

/// One origin per canister, whichever gateway domain reached it.
///
/// Internet Identity folds a canister's gateway origin onto `ic0.app` before it
/// derives anything from it, so that a principal does not depend on the domain
/// the user arrived through. That is the spelling it signs into the caller info
/// a content pull carries, so an app configured with the domain it is served on
/// has to read the two the same way.
module {

  /// The gateway domains that reach the same canister.
  let GATEWAY_DOMAINS : [Text] = ["ic0.app", "icp0.io", "icp.net"];

  /// The one Internet Identity keys an origin by.
  let CANONICAL_DOMAIN : Text = "ic0.app";

  /// A canister's gateway origin as Internet Identity spells it. Anything else
  /// — a custom domain, localhost — is its own origin and stands as it is.
  public func fold(origin : Text) : Text {
    let ?rest = origin.stripStart(#text "https://") else return origin;

    for (domain in GATEWAY_DOMAINS.values()) {
      switch (rest.stripEnd(#text("." # domain))) {
        case (?subdomain) if (isCanisterId(subdomain)) {
          return "https://" # subdomain # "." # CANONICAL_DOMAIN
        };
        case _ {}
      }
    };

    origin
  };

  func isCanisterId(subdomain : Text) : Bool {
    if (subdomain == "") return false;
    for (character in subdomain.chars()) {
      let ok = (character >= 'a' and character <= 'z') or (character >= 'A' and character <= 'Z') or (character >= '0' and character <= '9') or character == '-';
      if (not ok) return false
    };
    true
  }
}
