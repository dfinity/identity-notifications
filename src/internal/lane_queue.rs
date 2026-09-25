//! A queue whose items sit in lanes and are taken from them in weighted
//! cycles, so no lane starves however busy another one is.

use std::collections::BinaryHeap;

/// An item that knows which lane it belongs to and when it is due out of it.
pub trait Laned {
    fn lane(&self) -> usize;
    /// Smaller goes first.
    fn order(&self) -> u64;
}

#[derive(Debug)]
struct Queued<T>(T);

impl<T: Laned> PartialEq for Queued<T> {
    fn eq(&self, other: &Self) -> bool {
        self.0.order() == other.0.order()
    }
}

impl<T: Laned> Eq for Queued<T> {}

impl<T: Laned> Ord for Queued<T> {
    /// Reversed, because `BinaryHeap` is a max-heap and the smallest `order`
    /// leads its lane.
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        other.0.order().cmp(&self.0.order())
    }
}

impl<T: Laned> PartialOrd for Queued<T> {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

#[derive(Debug)]
pub struct LaneQueue<T: Laned> {
    lanes: Vec<BinaryHeap<Queued<T>>>,
    weights: Vec<usize>,
}

impl<T: Laned> LaneQueue<T> {
    pub fn new(weights: &[usize]) -> Self {
        Self {
            lanes: (0..weights.len()).map(|_| BinaryHeap::new()).collect(),
            weights: weights.to_vec(),
        }
    }

    pub fn push(&mut self, item: T) {
        let lane = item.lane().min(self.lanes.len() - 1);
        self.lanes[lane].push(Queued(item));
    }

    pub fn len(&self) -> usize {
        self.lanes.iter().map(BinaryHeap::len).sum()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn lane_len(&self, lane: usize) -> usize {
        self.lanes.get(lane).map_or(0, BinaryHeap::len)
    }

    /// Up to `count` items, taking `weights[lane]` from each lane per cycle and
    /// moving on when a lane runs dry, so an empty lane donates its turns
    /// rather than holding a slot open.
    pub fn take(&mut self, count: usize) -> Vec<T> {
        let mut taken = Vec::new();

        while taken.len() < count {
            let mut progressed = false;

            for (lane, &weight) in self.weights.iter().enumerate() {
                for _ in 0..weight {
                    if taken.len() >= count {
                        return taken;
                    }
                    match self.lanes[lane].pop() {
                        Some(Queued(item)) => {
                            taken.push(item);
                            progressed = true;
                        }
                        None => break,
                    }
                }
            }

            if !progressed {
                break;
            }
        }

        taken
    }

    /// Every item, for persisting across an upgrade. Order is derived from the
    /// items themselves, so it is rebuilt rather than stored.
    pub fn drain_clone(&self) -> Vec<T>
    where
        T: Clone,
    {
        self.lanes
            .iter()
            .flat_map(|lane| lane.iter().map(|queued| queued.0.clone()))
            .collect()
    }

    /// One item from a single lane, in that lane's own order. Used when
    /// shedding at the capacity ceiling.
    pub fn pop_lane(&mut self, lane: usize) -> Option<T> {
        self.lanes
            .get_mut(lane)
            .and_then(BinaryHeap::pop)
            .map(|Queued(item)| item)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, PartialEq, Eq)]
    struct Item {
        lane: usize,
        deadline: u64,
    }

    impl Laned for Item {
        fn lane(&self) -> usize {
            self.lane
        }
        fn order(&self) -> u64 {
            self.deadline
        }
    }

    fn item(lane: usize, deadline: u64) -> Item {
        Item { lane, deadline }
    }

    #[test]
    fn soonest_deadline_leads_its_lane() {
        let mut queue = LaneQueue::new(&[1]);
        queue.push(item(0, 30));
        queue.push(item(0, 10));
        queue.push(item(0, 20));

        let deadlines: Vec<u64> = queue.take(3).iter().map(|i| i.deadline).collect();
        assert_eq!(deadlines, vec![10, 20, 30]);
        assert!(queue.is_empty());
    }

    #[test]
    fn weights_decide_the_mix() {
        let mut queue = LaneQueue::new(&[2, 1]);
        for i in 0..6 {
            queue.push(item(0, i));
            queue.push(item(1, i));
        }

        let lanes: Vec<usize> = queue.take(6).iter().map(|i| i.lane).collect();
        assert_eq!(lanes, vec![0, 0, 1, 0, 0, 1]);
    }

    #[test]
    fn an_empty_lane_donates_its_turns() {
        let mut queue = LaneQueue::new(&[8, 4, 1]);
        for i in 0..4 {
            queue.push(item(2, i));
        }

        let lanes: Vec<usize> = queue.take(4).iter().map(|i| i.lane).collect();
        assert_eq!(lanes, vec![2, 2, 2, 2]);
    }

    #[test]
    fn a_busy_lane_cannot_starve_a_quiet_one() {
        let mut queue = LaneQueue::new(&[8, 1]);
        for i in 0..100 {
            queue.push(item(0, i));
            queue.push(item(1, i));
        }

        let taken = queue.take(27);
        assert_eq!(taken.iter().filter(|i| i.lane == 1).count(), 3);
    }

    #[test]
    fn taking_more_than_there_is_drains_and_stops() {
        let mut queue = LaneQueue::new(&[4, 4]);
        queue.push(item(0, 1));
        queue.push(item(1, 1));

        assert_eq!(queue.take(100).len(), 2);
        assert!(queue.is_empty());
        assert!(queue.take(10).is_empty());
    }
}
