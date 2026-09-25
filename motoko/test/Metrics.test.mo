import Metrics "../src/Internal/Metrics";
import Nat "mo:core/Nat";

let HOUR = 3_600_000_000_000;

// Events in the same hour land in one bucket, stamped with the hour's start.
do {
  let m = Metrics.empty();
  Metrics.record(m, 5 * HOUR + 1, #sent, 3);
  Metrics.record(m, 5 * HOUR + 2_000, #accepted, 2);
  Metrics.record(m, 5 * HOUR + HOUR - 1, #dropped, 1);

  let hours = Metrics.snapshot(m);
  assert hours.size() == 1;
  assert hours[0].start == 5 * HOUR;
  assert hours[0].sent == 3;
  assert hours[0].accepted == 2;
  assert hours[0].dropped == 1;
  assert hours[0].received == 0
};

// A new hour opens a new bucket, and the old one keeps its counts.
do {
  let m = Metrics.empty();
  Metrics.record(m, 1 * HOUR, #sent, 1);
  Metrics.record(m, 2 * HOUR, #sent, 2);

  let hours = Metrics.snapshot(m);
  assert hours.size() == 2;
  assert hours[0].sent == 1 and hours[1].sent == 2;
  assert hours[1].start == 2 * HOUR
};

// Quiet hours are absent rather than zero-filled, so nothing has to tick.
do {
  let m = Metrics.empty();
  Metrics.record(m, 1 * HOUR, #sent, 1);
  Metrics.record(m, 100 * HOUR, #sent, 1);

  assert Metrics.snapshot(m).size() == 2
};

// The ring keeps a month and drops from the oldest end.
do {
  let m = Metrics.empty();
  for (hour in Nat.range(0, 800)) {
    Metrics.record(m, hour * HOUR, #sent, 1)
  };

  let hours = Metrics.snapshot(m);
  assert hours.size() == 720;
  assert hours[0].start == 80 * HOUR;
  assert hours[719].start == 799 * HOUR
}
