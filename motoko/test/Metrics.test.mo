import Metrics "../src/Internal/Metrics";
import Nat "mo:core/Nat";

let HOUR = 3_600_000_000_000;

// Events in the same hour land in one bucket, stamped with the hour's start.
do {
  let m = Metrics.empty();
  m.record(5 * HOUR + 1, #queued, 3);
  m.record(5 * HOUR + 2_000, #accepted, 2);
  m.record(5 * HOUR + HOUR - 1, #dropped, 1);

  let hours = m.snapshot();
  assert hours.size() == 1;
  assert hours[0].start == 5 * HOUR;
  assert hours[0].counts.queued == 3;
  assert hours[0].counts.accepted == 2;
  assert hours[0].counts.dropped == 1;
  assert hours[0].counts.received == 0
};

// A new hour opens a new bucket, and the old one keeps its counts.
do {
  let m = Metrics.empty();
  m.record(1 * HOUR, #queued, 1);
  m.record(2 * HOUR, #queued, 2);

  let hours = m.snapshot();
  assert hours.size() == 2;
  assert hours[0].counts.queued == 1 and hours[1].counts.queued == 2;
  assert hours[1].start == 2 * HOUR
};

// Quiet hours are absent rather than zero-filled, so nothing has to tick.
do {
  let m = Metrics.empty();
  m.record(1 * HOUR, #queued, 1);
  m.record(100 * HOUR, #queued, 1);

  assert m.snapshot().size() == 2
};

// The ring keeps a month and drops from the oldest end.
do {
  let m = Metrics.empty();
  for (hour in Nat.range(0, 800)) {
    m.record(hour * HOUR, #queued, 1)
  };

  let hours = m.snapshot();
  assert hours.size() == 720;
  assert hours[0].start == 80 * HOUR;
  assert hours[719].start == 799 * HOUR
};

// A funnel an app named counts beside the hours, and only while it exists.
do {
  let m = Metrics.empty();
  m.openFunnel("promo");
  m.recordFunnel("promo", #queued, 2);
  m.recordFunnel("never-opened", #queued, 5);

  let funnels = m.funnels();
  assert funnels.size() == 1;
  assert funnels[0].name == "promo";
  assert funnels[0].counts.queued == 2;

  m.forgetFunnel("promo");
  m.recordFunnel("promo", #queued, 1);
  assert m.funnels().size() == 0
}
