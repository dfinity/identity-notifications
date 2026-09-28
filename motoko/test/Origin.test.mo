import Origin "../src/Internal/Origin";

// A canister is one origin on every gateway domain.
do {
  let folded = "https://vt36r-2qaaa-aaaad-aad5a-cai.ic0.app";
  assert Origin.fold("https://vt36r-2qaaa-aaaad-aad5a-cai.ic0.app") == folded;
  assert Origin.fold("https://vt36r-2qaaa-aaaad-aad5a-cai.icp0.io") == folded;
  assert Origin.fold("https://vt36r-2qaaa-aaaad-aad5a-cai.icp.net") == folded
};

// Anything that is no gateway origin stands as it is.
do {
  assert Origin.fold("https://chat.example.com") == "https://chat.example.com";
  assert Origin.fold("https://example.icp0.io.evil.com") == "https://example.icp0.io.evil.com";
  assert Origin.fold("http://vt36r-2qaaa-aaaad-aad5a-cai.icp0.io") == "http://vt36r-2qaaa-aaaad-aad5a-cai.icp0.io";
  assert Origin.fold("https://.ic0.app") == "https://.ic0.app";
  assert Origin.fold("https://a.b.icp0.io") == "https://a.b.icp0.io";
  assert Origin.fold("http://127.0.0.1:4943") == "http://127.0.0.1:4943"
}
