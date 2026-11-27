//! What a flush decides, with no `await` in sight: the canister layer builds a
//! batch, makes the call, and hands the answer back here.

use super::ii;
use super::store::{Entry, Event, Store};
use std::collections::HashMap;

/// How long a batch the application's configuration refused waits before it is
/// tried again. Only its operator can fix that, so a call every coalesce window
/// would spend cycles on the same answer until they do.
pub const MISCONFIGURED_RETRY_NS: u64 = 60 * 1_000_000_000;

#[derive(Clone, Debug)]
pub enum Outcome {
    /// Sent, with whatever Internet Identity would not take.
    Answered(Vec<ii::NotAccepted>),
    /// The batch was too large, and nothing in it was enqueued.
    TooMany(usize),
    /// The application does not publish this canister as one of its senders.
    NotAuthorized,
    /// The application at the derivation origin does not list the frontend
    /// among its alternative origins.
    FrontendNotListed,
    /// The call itself failed.
    Unreachable,
}

pub fn arg(
    origin: &str,
    derivation_origin: Option<&str>,
    batch: &[Entry],
) -> ii::SendNotificationArg {
    ii::SendNotificationArg {
        origin: origin.to_string(),
        derivation_origin: derivation_origin.map(str::to_string),
        notifications: batch
            .iter()
            .map(|entry| ii::Notification {
                id: entry.id,
                recipient: entry.recipient,
                expires_at: Some(entry.expires_at),
                urgency: Some(urgency_of(entry.lane)),
            })
            .collect(),
    }
}

/// Applies an outcome to the batch that produced it.
pub fn apply(store: &mut Store, batch: Vec<Entry>, outcome: Outcome, now: u64) {
    match outcome {
        Outcome::Answered(not_accepted) => {
            let refused: HashMap<u64, ii::NotAcceptedReason> = not_accepted
                .iter()
                .map(|entry| (entry.id, entry.reason))
                .collect();

            for entry in batch {
                match refused.get(&entry.id) {
                    None => {
                        store.record_for(&entry, Event::Accepted, 1);
                        store.settle(&entry);
                    }
                    Some(ii::NotAcceptedReason::Deferred { retry_after }) => {
                        store.record_for(&entry, Event::Deferred, 1);
                        store.defer(entry, *retry_after);
                    }
                    // No such recipient, or no channel: the user fixes both,
                    // and has until the notification expires to do it.
                    Some(_) => {
                        if !store.park(entry, now) {
                            store.record_for(&entry, Event::Dropped, 1);
                        }
                    }
                }
            }
        }

        Outcome::Unreachable => {
            for entry in batch {
                if !store.park(entry, now) {
                    store.record_for(&entry, Event::Dropped, 1);
                }
            }
        }

        Outcome::TooMany(_) => {
            for entry in batch {
                store.requeue(entry, now);
            }
        }

        // Nothing was enqueued, and nothing will be until the application's
        // configuration changes: later, without spending the second attempt.
        Outcome::NotAuthorized | Outcome::FrontendNotListed => {
            for entry in batch {
                store.defer(entry, now + MISCONFIGURED_RETRY_NS);
            }
        }
    }
}

/// What Internet Identity's answer to a send means for the batch.
pub fn outcome_of(result: ii::SendNotificationResult) -> Outcome {
    match result {
        ii::SendNotificationResult::Ok(response) => Outcome::Answered(response.not_accepted),
        ii::SendNotificationResult::Err(error) => match error {
            ii::SendNotificationError::TooManyNotifications { limit } => {
                Outcome::TooMany(limit as usize)
            }
            ii::SendNotificationError::NoSuchSender => Outcome::NotAuthorized,
            ii::SendNotificationError::NoSuchFrontend => Outcome::FrontendNotListed,
            ii::SendNotificationError::InternalCanisterError(_) => Outcome::Unreachable,
        },
    }
}

fn urgency_of(lane: u8) -> ii::Urgency {
    match lane {
        0 => ii::Urgency::High,
        1 => ii::Urgency::Normal,
        2 => ii::Urgency::Low,
        _ => ii::Urgency::VeryLow,
    }
}
