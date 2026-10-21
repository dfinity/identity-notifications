import Prim "mo:⛔";
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";
import Text "mo:core/Text";

/// Who Internet Identity says this call is for.
///
/// The IC verifies the signature over the caller info before the callee runs,
/// so nothing here is cryptography. The caller principal is ignored: it
/// carries no authority, and the account in the info is who the call is for.
module {

  let DOMAIN = "notification-sender-info";

  public type SenderInfo = {
    origin : Text;
    account : Principal
  };

  /// `null` when the call carries no caller info, when someone other than the
  /// configured Internet Identity signed it, or when the info is not something
  /// this library understands.
  public func read(trusted : Principal) : ?SenderInfo {
    let signer = Prim.callerInfoSigner();
    if (signer.size() == 0) return null;
    if (Principal.fromBlob(signer) != trusted) return null;

    decode(Prim.callerInfoData())
  };

  /// `<domain><origin><account>`, each length-prefixed, as Internet Identity
  /// signs it.
  public func decode(info : Blob) : ?SenderInfo {
    let bytes = info.toArray();
    var at = 0;

    let ?domain = field(bytes, at) else return null;
    if (textOf(domain.value) != ?DOMAIN) return null;
    at := domain.next;

    let ?origin = field(bytes, at) else return null;
    let ?text = textOf(origin.value) else return null;
    at := origin.next;

    let ?account = field(bytes, at) else return null;
    if (account.next != bytes.size()) return null;

    ?{
      origin = text;
      account = Principal.fromBlob(account.value.toBlob())
    }
  };

  func field(bytes : [Nat8], at : Nat) : ?{ value : [Nat8]; next : Nat } {
    if (at >= bytes.size()) return null;
    let length = bytes[at].toNat();
    let from = at + 1;
    if (from + length > bytes.size()) return null;

    let value = Prim.Array_tabulate<Nat8>(length, func(i) = bytes[from + i]);
    ?{ value; next = from + length }
  };

  func textOf(bytes : [Nat8]) : ?Text = bytes.toBlob().decodeUtf8()
}
