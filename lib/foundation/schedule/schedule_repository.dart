import 'schedule_state.dart';

/// Schedule state storage boundary.
///
/// Contract: `specs/006-local-follow-up-loop/contracts/schedule-v1.md` (S1/S2/S4)
/// and `plan.md` (stable interfaces).
///
/// This is the **third independent store**, alongside `scan_results.db` and
/// `tracking_state.db`.  The three share no transaction, and deleting or
/// rebuilding any one of them damages neither of the others.
///
/// The interface exposes no transaction primitive: the all-or-nothing batch is
/// an implementation detail.
abstract class ScheduleStateRepository {
  /// Opens (and creates/migrates) the schedule database.
  Future<void> ensureOpen();

  /// Reads every stored schedule, keyed by `(sourceKey, comicId)`.
  Future<Map<String, ScheduleState>> readAll();

  /// Reads the schedules whose `next_at` is null or already reached.
  ///
  /// Deliberately **not** named `readDue`: this answers only the two conditions
  /// the schedule store can answer alone.  The full four-condition due test
  /// (Contract S4) also needs "has an observation" and "has a schedule record",
  /// and only a caller that can see both stores may merge them.  Naming this
  /// `readDue` invited exactly the mistake S4 warns about.
  ///
  /// [nowMs] is supplied by the caller; this layer MUST NOT read the system
  /// clock, or the same data would yield different sets at different moments.
  Future<Map<String, ScheduleState>> readExpired(int nowMs);

  /// Writes the batch inside one transaction and returns the row count.
  Future<int> applyBatch(List<ScheduleState> rows);

  /// Deletes every schedule row.  All identities become due again, because
  /// "no schedule record" is itself a due condition (S4).
  Future<void> clear();

  Future<void> close();
}

/// Raised when the schedule store cannot be read or written.
///
/// Kept distinct from judgment and scan storage failures so a failure is
/// attributed to the right store.
class ScheduleStorageException implements Exception {
  const ScheduleStorageException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'Schedule storage error: $message';
}
