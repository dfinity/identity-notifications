//! Keys for the stable maps.
//!
//! `ic-stable-structures` orders a map by the bytes a key encodes to, so each
//! field goes in big-endian and in the order it should sort by. That is what
//! makes a range scan over one lane, in expiry order, the natural way to take
//! a batch — no heap to rebuild after an upgrade.

use ic_stable_structures::storable::{Bound, Storable};
use std::borrow::Cow;

/// `(lane, expires_at, id)`: a scan of one lane yields its soonest expiry
/// first.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct ReadyKey {
    pub lane: u8,
    pub expires_at: u64,
    pub id: u64,
}

impl ReadyKey {
    pub fn lane_start(lane: u8) -> Self {
        Self {
            lane,
            expires_at: 0,
            id: 0,
        }
    }

    pub fn lane_end(lane: u8) -> Self {
        Self {
            lane,
            expires_at: u64::MAX,
            id: u64::MAX,
        }
    }
}

impl Storable for ReadyKey {
    const BOUND: Bound = Bound::Bounded {
        max_size: 17,
        is_fixed_size: true,
    };

    fn to_bytes(&self) -> Cow<'_, [u8]> {
        let mut bytes = Vec::with_capacity(17);
        bytes.push(self.lane);
        bytes.extend_from_slice(&self.expires_at.to_be_bytes());
        bytes.extend_from_slice(&self.id.to_be_bytes());
        Cow::Owned(bytes)
    }

    fn into_bytes(self) -> Vec<u8> {
        self.to_bytes().into_owned()
    }

    fn from_bytes(bytes: Cow<[u8]>) -> Self {
        Self {
            lane: bytes[0],
            expires_at: u64::from_be_bytes(bytes[1..9].try_into().expect("17 bytes")),
            id: u64::from_be_bytes(bytes[9..17].try_into().expect("17 bytes")),
        }
    }
}

/// `(due_at, id)`: a scan yields whatever is due next.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct ParkedKey {
    pub due_at: u64,
    pub id: u64,
}

impl Storable for ParkedKey {
    const BOUND: Bound = Bound::Bounded {
        max_size: 16,
        is_fixed_size: true,
    };

    fn to_bytes(&self) -> Cow<'_, [u8]> {
        let mut bytes = Vec::with_capacity(16);
        bytes.extend_from_slice(&self.due_at.to_be_bytes());
        bytes.extend_from_slice(&self.id.to_be_bytes());
        Cow::Owned(bytes)
    }

    fn into_bytes(self) -> Vec<u8> {
        self.to_bytes().into_owned()
    }

    fn from_bytes(bytes: Cow<[u8]>) -> Self {
        Self {
            due_at: u64::from_be_bytes(bytes[..8].try_into().expect("16 bytes")),
            id: u64::from_be_bytes(bytes[8..16].try_into().expect("16 bytes")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ready_keys_sort_by_lane_then_expiry_then_id() {
        let mut keys = vec![
            ReadyKey {
                lane: 1,
                expires_at: 5,
                id: 9,
            },
            ReadyKey {
                lane: 0,
                expires_at: 9,
                id: 1,
            },
            ReadyKey {
                lane: 0,
                expires_at: 5,
                id: 2,
            },
            ReadyKey {
                lane: 0,
                expires_at: 5,
                id: 1,
            },
        ];
        keys.sort_by_key(|key| key.to_bytes().into_owned());

        assert_eq!(
            keys,
            vec![
                ReadyKey {
                    lane: 0,
                    expires_at: 5,
                    id: 1
                },
                ReadyKey {
                    lane: 0,
                    expires_at: 5,
                    id: 2
                },
                ReadyKey {
                    lane: 0,
                    expires_at: 9,
                    id: 1
                },
                ReadyKey {
                    lane: 1,
                    expires_at: 5,
                    id: 9
                },
            ]
        );
    }

    #[test]
    fn byte_order_matches_numeric_order_across_the_whole_range() {
        let small = ParkedKey { due_at: 255, id: 0 };
        let large = ParkedKey { due_at: 256, id: 0 };
        assert!(small.to_bytes().into_owned() < large.to_bytes().into_owned());
    }

    #[test]
    fn keys_round_trip() {
        let key = ReadyKey {
            lane: 3,
            expires_at: u64::MAX,
            id: 42,
        };
        assert_eq!(ReadyKey::from_bytes(key.to_bytes()), key);

        let parked = ParkedKey {
            due_at: 7,
            id: u64::MAX,
        };
        assert_eq!(ParkedKey::from_bytes(parked.to_bytes()), parked);
    }
}
