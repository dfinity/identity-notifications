import Config "../src/Internal/Config";

let II = "rdmx6-jaaaa-aaaaa-aaadq-cai";

func configured(variables : Config.Variables) : Config.Config {
  switch (Config.fromVariables(variables)) {
    case (#ok(config)) config;
    case (#err(_)) { assert false; loop {} }
  }
};

// Without a derivation origin, the frontend is the application.
do {
  let config = configured({
    notification_sender = ?II;
    notification_origin = ?"https://app.example.com";
    notification_derivation_origin = null;
    notification_capacity_mb = null
  });

  assert config.derivationOrigin == null;
  assert Config.applicationOrigin(config) == "https://app.example.com"
};

// A derivation origin names the application the frontend sends for.
do {
  let config = configured({
    notification_sender = ?II;
    notification_origin = ?"https://mail.suite.example";
    notification_derivation_origin = ?"https://suite.example";
    notification_capacity_mb = null
  });

  assert config.origin == "https://mail.suite.example";
  assert config.derivationOrigin == ?"https://suite.example";
  assert Config.applicationOrigin(config) == "https://suite.example"
};

// An empty derivation origin is unset.
do {
  let config = configured({
    notification_sender = null;
    notification_origin = ?"https://app.example.com";
    notification_derivation_origin = ?"";
    notification_capacity_mb = null
  });

  assert config.derivationOrigin == null;
  assert Config.applicationOrigin(config) == "https://app.example.com"
};

// A derivation origin needs the frontend it sends for.
do {
  let result = Config.fromVariables({
    notification_sender = ?II;
    notification_origin = null;
    notification_derivation_origin = ?"https://suite.example";
    notification_capacity_mb = null
  });
  switch result {
    case (#err(#origin)) {};
    case _ assert false
  }
};

// A pull minted for the derivation origin is answered, and one for the
// frontend is not.
do {
  let config = configured({
    notification_sender = ?II;
    notification_origin = ?"https://mail.suite.example";
    notification_derivation_origin = ?"https://suite.example";
    notification_capacity_mb = null
  });

  assert Config.isApplication(config, "https://suite.example");
  assert not Config.isApplication(config, "https://mail.suite.example");
  assert not Config.isApplication(config, "https://other.example")
};

// A derivation origin is the application on every gateway domain.
do {
  let config = configured({
    notification_sender = ?II;
    notification_origin = ?"https://mail.suite.example";
    notification_derivation_origin = ?"https://vt36r-2qaaa-aaaad-aad5a-cai.icp0.io";
    notification_capacity_mb = null
  });

  assert Config.isApplication(config, "https://vt36r-2qaaa-aaaad-aad5a-cai.ic0.app");
  assert Config.isApplication(config, "https://vt36r-2qaaa-aaaad-aad5a-cai.icp.net");
  assert not Config.isApplication(config, "https://mail.suite.example")
};

// Without a derivation origin, a pull is answered for the frontend alone.
do {
  let config = configured({
    notification_sender = ?II;
    notification_origin = ?"https://app.example.com";
    notification_derivation_origin = null;
    notification_capacity_mb = null
  });

  assert Config.isApplication(config, "https://app.example.com");
  assert not Config.isApplication(config, "https://suite.example")
};

// The capacity falls back to its default where it is no number.
do {
  let config = configured({
    notification_sender = null;
    notification_origin = ?"https://app.example.com";
    notification_derivation_origin = null;
    notification_capacity_mb = ?"lots"
  });

  assert config.capacityBytes == 1024 * 1_048_576
}
