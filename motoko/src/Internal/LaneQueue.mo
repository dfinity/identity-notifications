import Array "mo:core/Array";
import List "mo:core/List";
import Order "mo:core/Order";
import PriorityQueue "mo:core/PriorityQueue";

/// A queue whose items sit in lanes and are taken from them in weighted
/// cycles, so no lane starves however busy another one is.
///
/// The lane an item belongs to and the order within a lane are the caller's,
/// which keeps `State` plain data and therefore stable across upgrades.
///
/// `compare` is ascending, as everywhere else, and the smallest item leads its
/// lane. Core's `PriorityQueue` pops the greatest, so the comparator is
/// inverted here rather than in every caller.
module {

  public type State<T> = {
    lanes : [PriorityQueue.PriorityQueue<T>]
  };

  func smallestFirst<T>(compare : (T, T) -> Order.Order) : (T, T) -> Order.Order = func(a, b) = compare(b, a);

  public func empty<T>(laneCount : Nat) : State<T> = {
    lanes = Array.tabulate<PriorityQueue.PriorityQueue<T>>(
      laneCount,
      func(_) = PriorityQueue.empty<T>()
    )
  };

  public func push<T>(
    self : State<T>,
    lane : Nat,
    item : T,
    compare : (T, T) -> Order.Order
  ) {
    self.lanes[lane].push(smallestFirst(compare), item)
  };

  public func size<T>(self : State<T>) : Nat {
    var total = 0;
    var lane = 0;
    while (lane < self.lanes.size()) {
      total += self.lanes[lane].size();
      lane += 1
    };
    total
  };

  public func laneSize<T>(self : State<T>, lane : Nat) : Nat {
    self.lanes[lane].size()
  };

  /// Up to `count` items, taking `weights[lane]` from each lane per cycle and
  /// moving on when a lane runs dry, so an empty lane donates its turns rather
  /// than holding a slot open.
  public func take<T>(
    self : State<T>,
    weights : [Nat],
    count : Nat,
    compare : (T, T) -> Order.Order
  ) : [T] {
    let taken = List.empty<T>();

    label cycles loop {
      var progressed = false;
      var lane = 0;

      while (lane < self.lanes.size()) {
        var turn = 0;
        label turns while (turn < weights[lane]) {
          if (taken.size() >= count) break cycles;
          switch (self.lanes[lane].pop(smallestFirst(compare))) {
            case (?item) {
              taken.add(item);
              progressed := true
            };
            case null break turns
          };
          turn += 1
        };
        lane += 1
      };

      if (not progressed) break cycles
    };

    taken.toArray()
  }
}
