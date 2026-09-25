//! What a flush decides, with no `await` in sight: the canister layer builds a
//! batch, makes the call, and hands the answer back here.

use super::ii;
use super::metrics::{Event, Pipeline};
use super::outbox::{Entry, Outbox};
use std::collections::HashMap;

#[derive(Clone, Debug)]
pub enum Outcome {
    /// Sent, with whatever Internet Identity would not take.
    Answered(Vec<ii::NotAccepted>),
    /// The batch was too large. Nothing was enqueued, so it is safe to split
    /// and send again — and the limit is worth remembering.
    TooMany(usize),
    /// Internet Identity refuses everything from this canister until the
    /// origin publishes it as a sender.
    NotAuthorized,
    /// The call itself failed. Entries go back for their second attempt.
    Unreachable,
}

pub fn arg(origin: &str, batch: &[Entry]) -> ii::SendNotificationArg {
    ii::SendNotificationArg {
        origin: origin.to_string(),
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

/// Applies an outcome to the batch that produced it. Entries not named in
/// `not_accepted` were taken, so they leave the outbox — what remains of them
/// is content a channel may pull.
pub fn apply(
    outbox: &mut Outbox,
    pipeline: &mut Pipeline,
    batch: Vec<Entry>,
    outcome: Outcome,
    now: u64,
) {
    pipeline.record(now, Event::Sent, batch.len() as u64);

    match outcome {
        Outcome::Answered(not_accepted) => {
            let refused: HashMap<u64, ii::NotAcceptedReason> = not_accepted
                .iter()
                .map(|entry| (entry.id, entry.reason))
                .collect();

            pipeline.record(
                now,
                Event::Accepted,
                (batch.len() - not_accepted.len()) as u64,
            );

            for entry in batch {
                match refused.get(&entry.id) {
                    None => outbox.settle(&entry),
                    Some(ii::NotAcceptedReason::Deferred { retry_after }) => {
                        pipeline.record(now, Event::Deferred, 1);
                        outbox.defer(entry, *retry_after);
                    }
                    // No such recipient, or no channel: the user fixes both,
                    // and has until the notification expires to do it.
                    Some(_) => {
                        if !outbox.park(entry) {
                            pipeline.record(now, Event::Dropped, 1);
                        }
                    }
                }
            }
        }

        Outcome::Unreachable => {
            for entry in batch {
                if !outbox.park(entry) {
                    pipeline.record(now, Event::Dropped, 1);
                }
            }
        }

        // Nothing was enqueued. The entries go back where they came from, to
        // be sent again once the batch is split or the origin is fixed.
        Outcome::TooMany(_) | Outcome::NotAuthorized => {
            for entry in batch {
                outbox.requeue(entry, now);
            }
        }
    }
}

fn urgency_of(lane: usize) -> ii::Urgency {
    match lane {
        0 => ii::Urgency::High,
        1 => ii::Urgency::Normal,
        2 => ii::Urgency::Low,
        _ => ii::Urgency::VeryLow,
    }
}
