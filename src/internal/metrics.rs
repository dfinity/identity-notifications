//! The delivery pipeline, one bucket an hour, thirty days deep.
//!
//! Buckets carry the hour they cover, so the ring rolls over lazily: a canister
//! that sends nothing for a week needs no timer keeping empty buckets
//! contiguous, and the quiet hours are simply absent.

use crate::types::Bucket;
use candid::CandidType;
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

const HOUR: u64 = 3_600_000_000_000;
const KEEP: usize = 720;

#[derive(Clone, Copy, Debug)]
pub enum Event {
    Sent,
    Accepted,
    Deferred,
    Received,
    Dropped,
}

#[derive(CandidType, Serialize, Deserialize, Clone, Debug, Default)]
pub struct Pipeline {
    hours: VecDeque<Bucket>,
}

impl Pipeline {
    pub fn record(&mut self, now: u64, event: Event, count: u64) {
        let bucket = self.current(now);
        match event {
            Event::Sent => bucket.sent += count,
            Event::Accepted => bucket.accepted += count,
            Event::Deferred => bucket.deferred += count,
            Event::Received => bucket.received += count,
            Event::Dropped => bucket.dropped += count,
        }
    }

    pub fn snapshot(&self) -> Vec<Bucket> {
        self.hours.iter().copied().collect()
    }

    fn current(&mut self, now: u64) -> &mut Bucket {
        let start = now - (now % HOUR);

        if self.hours.back().map(|b| b.start) != Some(start) {
            self.hours.push_back(Bucket {
                start,
                ..Bucket::default()
            });
            while self.hours.len() > KEEP {
                self.hours.pop_front();
            }
        }

        self.hours.back_mut().expect("just pushed")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn events_in_one_hour_share_a_bucket() {
        let mut pipeline = Pipeline::default();
        pipeline.record(5 * HOUR + 1, Event::Sent, 3);
        pipeline.record(5 * HOUR + 2_000, Event::Accepted, 2);
        pipeline.record(6 * HOUR - 1, Event::Dropped, 1);

        let hours = pipeline.snapshot();
        assert_eq!(hours.len(), 1);
        assert_eq!(hours[0].start, 5 * HOUR);
        assert_eq!(
            (hours[0].sent, hours[0].accepted, hours[0].dropped),
            (3, 2, 1)
        );
        assert_eq!(hours[0].received, 0);
    }

    #[test]
    fn a_new_hour_opens_a_bucket_and_keeps_the_old_counts() {
        let mut pipeline = Pipeline::default();
        pipeline.record(HOUR, Event::Sent, 1);
        pipeline.record(2 * HOUR, Event::Sent, 2);

        let hours = pipeline.snapshot();
        assert_eq!(hours.len(), 2);
        assert_eq!((hours[0].sent, hours[1].sent), (1, 2));
        assert_eq!(hours[1].start, 2 * HOUR);
    }

    #[test]
    fn quiet_hours_are_absent_rather_than_zero_filled() {
        let mut pipeline = Pipeline::default();
        pipeline.record(HOUR, Event::Sent, 1);
        pipeline.record(100 * HOUR, Event::Sent, 1);

        assert_eq!(pipeline.snapshot().len(), 2);
    }

    #[test]
    fn the_ring_keeps_a_month_and_drops_the_oldest() {
        let mut pipeline = Pipeline::default();
        for hour in 0..800u64 {
            pipeline.record(hour * HOUR, Event::Sent, 1);
        }

        let hours = pipeline.snapshot();
        assert_eq!(hours.len(), KEEP);
        assert_eq!(hours[0].start, 80 * HOUR);
        assert_eq!(hours[KEEP - 1].start, 799 * HOUR);
    }
}
