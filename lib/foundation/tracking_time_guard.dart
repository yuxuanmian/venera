/// The shared plausibility window for source-supplied timestamps.
///
/// Both the retired follow-up schedule parser and the judgment engine validate
/// evidence against the same interval, so the constants live here rather than
/// as duplicated literals (research R-08 / Contract J9).
///
/// The upper bound is deliberately caller-relative: every consumer must pass
/// its own `now`, so the comparison stays a pure function of its inputs and a
/// stored timestamp is never judged against a hidden system clock.
library;

/// Earliest acceptable instant.
final DateTime timestampWindowFloor = DateTime.utc(2000);

/// How far past the caller's "now" a value may sit before it is implausible.
const Duration timestampWindowCeilingSlack = Duration(hours: 24);

/// Whether [instant] sits inside `[floor, now + slack]`.
bool isWithinTimestampWindow(DateTime instant, DateTime now) {
  final candidate = instant.toUtc();
  if (candidate.isBefore(timestampWindowFloor)) return false;
  return !candidate.isAfter(now.toUtc().add(timestampWindowCeilingSlack));
}
