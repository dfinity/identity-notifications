import Principal "mo:core/Principal";
import CallerInfo "../src/Internal/CallerInfo";

let account = Principal.fromText("un4fu-tqaaa-aaaab-qadjq-cai");
let someoneElse = Principal.fromText("rdmx6-jaaaa-aaaaa-aaadq-cai");
let anonymous = Principal.fromText("2vxsx-fae");

// Internet Identity reads for the account its caller info names.
assert CallerInfo.mayRead(account, someoneElse, ?account);

// Caller info for another account reads nothing.
assert not CallerInfo.mayRead(account, someoneElse, ?someoneElse);

// The recipient reads its own notification without caller info.
assert CallerInfo.mayRead(account, account, null);

// Anyone else without caller info reads nothing.
assert not CallerInfo.mayRead(account, someoneElse, null);

// The anonymous caller reads nothing, even where it is the recipient.
assert not CallerInfo.mayRead(anonymous, anonymous, null);

// A dismissed notification is hidden from Internet Identity, which would show
// it, and still answered to the recipient's own service worker.
assert CallerInfo.mayRead(account, someoneElse, ?account) and not CallerInfo.isRecipient(account, someoneElse);
assert CallerInfo.isRecipient(account, account);
assert not CallerInfo.isRecipient(anonymous, anonymous)
