import LaneQueue "../src/Internal/LaneQueue";
import Nat "mo:core/Nat";
import Array "mo:core/Array";

// Items are (lane, deadline); within a lane the soonest deadline leads.
type Item = { lane : Nat; deadline : Nat };

func byDeadline(a : Item, b : Item) : { #less; #equal; #greater } = Nat.compare(a.deadline, b.deadline);

func push(q : LaneQueue.State<Item>, lane : Nat, deadline : Nat) = q.push<Item>(lane, { lane; deadline }, byDeadline);

func lanesOf(items : [Item]) : [Nat] = items.map<Item, Nat>(func(i) = i.lane);

// Within a lane, the soonest deadline comes out first.
do {
  let q = LaneQueue.empty<Item>(1);
  push(q, 0, 30);
  push(q, 0, 10);
  push(q, 0, 20);

  let out = q.take<Item>([1], 3, byDeadline);
  assert out.map<Item, Nat>(func(i) = i.deadline) == [10, 20, 30];
  assert q.size() == 0
};

// Weights decide the mix: 2:1 gives two of lane 0 per one of lane 1.
do {
  let q = LaneQueue.empty<Item>(2);
  for (i in Nat.range(0, 6)) { push(q, 0, i) };
  for (i in Nat.range(0, 6)) { push(q, 1, i) };

  assert lanesOf(q.take<Item>([2, 1], 6, byDeadline)) == [0, 0, 1, 0, 0, 1]
};

// An empty lane donates its turns instead of holding slots open.
do {
  let q = LaneQueue.empty<Item>(3);
  for (i in Nat.range(0, 4)) { push(q, 2, i) };

  let out = q.take<Item>([8, 4, 1], 4, byDeadline);
  assert lanesOf(out) == [2, 2, 2, 2]
};

// A high-weight lane cannot starve a low one: the low lane still moves.
do {
  let q = LaneQueue.empty<Item>(2);
  for (i in Nat.range(0, 100)) { push(q, 0, i) };
  for (i in Nat.range(0, 100)) { push(q, 1, i) };

  let out = q.take<Item>([8, 1], 27, byDeadline);
  var low = 0;
  for (item in out.values()) { if (item.lane == 1) low += 1 };
  assert low == 3
};

// Taking more than there is drains what exists and stops.
do {
  let q = LaneQueue.empty<Item>(2);
  push(q, 0, 1);
  push(q, 1, 1);

  assert q.take<Item>([4, 4], 100, byDeadline).size() == 2;
  assert q.size() == 0;
  assert q.take<Item>([4, 4], 10, byDeadline).size() == 0
}
