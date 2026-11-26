//! Four environment variables, two of them optional. Read on use: a
//! canister's environment does not change under it.

use crate::types::Misconfigured;
use candid::Principal;

pub const DEFAULT_CAPACITY_MB: usize = 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Config {
    /// `None` where the variable is unset or not a principal, which
    /// [`crate::set_sender`] can still answer for.
    pub sender: Option<Principal>,
    /// The frontend the notifications are sent for.
    pub origin: String,
    /// The application whose users receive them, where `origin` is one of its
    /// frontends: the derivation origin that frontend signs in with. `None`
    /// where the variable is unset or empty, and `origin` is the application.
    pub derivation_origin: Option<String>,
    pub capacity_bytes: usize,
}

impl Config {
    /// The application whose users receive the notifications, and the origin
    /// Internet Identity signs into the caller info of a pull for them.
    pub fn application_origin(&self) -> &str {
        self.derivation_origin.as_deref().unwrap_or(&self.origin)
    }
}

/// The variables `lookup` answers, as a configuration. Missing configuration is
/// reported rather than guessed at.
pub fn from_variables(lookup: impl Fn(&str) -> Option<String>) -> Result<Config, Misconfigured> {
    let Some(origin) = lookup("notification_origin").filter(|origin| !origin.is_empty()) else {
        return Err(Misconfigured::Origin);
    };

    let sender = lookup("notification_sender").and_then(|text| Principal::from_text(text).ok());

    let derivation_origin =
        lookup("notification_derivation_origin").filter(|origin| !origin.is_empty());

    let capacity_mb = lookup("notification_capacity_mb")
        .and_then(|value| value.parse().ok())
        .unwrap_or(DEFAULT_CAPACITY_MB);

    Ok(Config {
        sender,
        origin,
        derivation_origin,
        capacity_bytes: capacity_mb * 1_048_576,
    })
}

/// The canister's environment variables, as a configuration.
#[cfg(target_arch = "wasm32")]
pub fn read() -> Result<Config, Misconfigured> {
    use ic_cdk::api::{env_var_name_exists, env_var_value};

    from_variables(|name| env_var_name_exists(name).then(|| env_var_value(name)))
}

/// Off-canister there is no environment to read.
#[cfg(not(target_arch = "wasm32"))]
pub fn read() -> Result<Config, Misconfigured> {
    from_variables(|_| None)
}

#[cfg(test)]
mod tests {
    use super::*;

    const II: &str = "rdmx6-jaaaa-aaaaa-aaadq-cai";

    fn configured(variables: &[(&str, &str)]) -> Result<Config, Misconfigured> {
        from_variables(|name| {
            variables
                .iter()
                .find(|(variable, _)| *variable == name)
                .map(|(_, value)| value.to_string())
        })
    }

    #[test]
    fn without_a_derivation_origin_the_frontend_is_the_application() {
        let config = configured(&[
            ("notification_sender", II),
            ("notification_origin", "https://app.example.com"),
        ])
        .expect("configured");

        assert_eq!(config.derivation_origin, None);
        assert_eq!(config.application_origin(), "https://app.example.com");
    }

    #[test]
    fn a_derivation_origin_names_the_application_the_frontend_sends_for() {
        let config = configured(&[
            ("notification_sender", II),
            ("notification_origin", "https://mail.suite.example"),
            ("notification_derivation_origin", "https://suite.example"),
        ])
        .expect("configured");

        assert_eq!(config.origin, "https://mail.suite.example");
        assert_eq!(
            config.derivation_origin.as_deref(),
            Some("https://suite.example")
        );
        assert_eq!(config.application_origin(), "https://suite.example");
    }

    #[test]
    fn an_empty_derivation_origin_is_unset() {
        let config = configured(&[
            ("notification_origin", "https://app.example.com"),
            ("notification_derivation_origin", ""),
        ])
        .expect("configured");

        assert_eq!(config.derivation_origin, None);
        assert_eq!(config.application_origin(), "https://app.example.com");
    }

    #[test]
    fn a_derivation_origin_needs_the_frontend_it_sends_for() {
        let config = configured(&[
            ("notification_sender", II),
            ("notification_derivation_origin", "https://suite.example"),
        ]);

        assert_eq!(config, Err(Misconfigured::Origin));
    }

    #[test]
    fn the_capacity_falls_back_to_its_default_where_it_is_no_number() {
        let config = configured(&[
            ("notification_origin", "https://app.example.com"),
            ("notification_capacity_mb", "lots"),
        ])
        .expect("configured");

        assert_eq!(config.capacity_bytes, 1024 * 1_048_576);
    }
}
