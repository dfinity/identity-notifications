import Blob "mo:core/Blob";
import Nat64 "mo:core/Nat64";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Iter "mo:core/Iter";
import Sha256 "mo:sha2/Sha256";

/// Notification ids, which Internet Identity scopes to `(origin, recipient)`.
///
/// A keyed id is derived rather than remembered: the same `(recipient, key)`
/// always yields the same id, so an update supersedes its predecessor after an
/// upgrade, after the content has been swept, and after the app has forgotten
/// it ever sent anything. A table would have to be evicted or grow forever,
/// and both are wrong.
module {

  /// Separates derived ids from counter ids, so the two spaces cannot collide.
  let KEYED : Nat64 = 0x8000_0000_0000_0000;

  public func keyed(recipient : Principal, key : Text) : Nat64 {
    // The recipient is length-prefixed so that no pair of (recipient, key)
    // can be spelled two ways and land on one id.
    let who = Blob.toArray(Principal.toBlob(recipient));
    let what = Blob.toArray(Text.encodeUtf8(key));
    let digest = Sha256.fromIter(
      #sha256,
      Iter.concat(
        Iter.singleton(Nat8.fromNat(who.size())),
        Iter.concat(who.values(), what.values())
      )
    );
    KEYED | (leading64(digest) & (KEYED - 1))
  };

  /// Counter ids start from a random offset rather than from one, so two
  /// canisters sending for the same origin — a relay and its replacement, or
  /// a deployment that broke the one-sender rule — do not both hand out the
  /// same low numbers.
  public func keyless(seed : Nat64, counter : Nat64) : Nat64 {
    (seed +% counter) & (KEYED - 1)
  };

  /// The first eight bytes of anything random, as an offset.
  public func seedFrom(randomness : Blob) : Nat64 {
    leading64(randomness) & (KEYED - 1)
  };

  func leading64(digest : Blob) : Nat64 {
    let bytes = Blob.toArray(digest);
    var value : Nat64 = 0;
    var i = 0;
    while (i < 8) {
      value := (value << 8) | Nat64.fromNat(Nat8.toNat(bytes[i]));
      i += 1
    };
    value
  }
}
