import Ids "../src/Internal/Ids";
import Principal "mo:core/Principal";
import Nat64 "mo:core/Nat64";

let alice = Principal.fromText("un4fu-tqaaa-aaaab-qadjq-cai");
let bob = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
let KEYED : Nat64 = 0x8000_0000_0000_0000;

// The same key for the same recipient is the same notification, every time.
do {
  assert Ids.keyed(alice, "chat-7") == Ids.keyed(alice, "chat-7")
};

// Different keys, and the same key for different people, are different
// notifications — the latter is what scopes ids to a recipient.
do {
  assert Ids.keyed(alice, "chat-7") != Ids.keyed(alice, "chat-8");
  assert Ids.keyed(alice, "chat-7") != Ids.keyed(bob, "chat-7")
};

// The top bit separates derived ids from counter ids, so the two spaces
// cannot collide however many of either an app sends.
do {
  assert Ids.keyed(alice, "chat-7") & KEYED == KEYED;
  assert Ids.keyless(0) & KEYED == 0;
  assert Ids.keyless(1) & KEYED == 0;
  assert Ids.keyless(0x7FFF_FFFF_FFFF_FFFF) & KEYED == 0
};

// Counter ids stay distinct as the counter moves.
do {
  assert Ids.keyless(41) != Ids.keyless(42)
}
