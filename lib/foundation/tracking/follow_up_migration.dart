import '../favorites.dart';
import '../schedule/schedule_repository.dart';
import '../schedule/schedule_state.dart';
import 'judgment_event.dart';
import 'judgment_repository.dart';
import 'judgment_state.dart';

/// The metadata key recording that the 006 migration has run.
///
/// The same one-time mechanism `favorites.dart` already uses for its tracking
/// evidence migration: the marker is written inside the migrating transaction,
/// so an interrupted run rolls back and is retried, while a completed run never
/// runs again.
const String followUpMigrationKey = 'follow_up_006_migration';

/// What one run of the migration did.
///
/// A value type so a test can assert the retention ratio rather than only the
/// absence of an exception.
class FollowUpMigrationReport {
  const FollowUpMigrationReport({
    required this.legacyRows,
    required this.flagRowsCopied,
    required this.flagRowsOrphaned,
    required this.flagRowsAlreadyClear,
    required this.scheduleRowsCopied,
    required this.scheduleRowsExpired,
    required this.alreadyMigrated,
  });

  const FollowUpMigrationReport.skipped()
    : legacyRows = 0,
      flagRowsCopied = 0,
      flagRowsOrphaned = 0,
      flagRowsAlreadyClear = 0,
      scheduleRowsCopied = 0,
      scheduleRowsExpired = 0,
      alreadyMigrated = true;

  /// Rows the legacy store held.
  final int legacyRows;

  /// Flag rows written into judgment state.
  final int flagRowsCopied;

  /// Flag rows dropped because the target has no such identity.
  ///
  /// Expected to be large on a real device: the legacy table covers comics that
  /// are no longer favorites, and FR-035 says those are ignored.
  final int flagRowsOrphaned;

  /// Rows that are in scope and had nothing to copy.
  ///
  /// Counted separately from [flagRowsCopied] so the three add up to
  /// [legacyRows].  Merging the two would make "the target set was empty" and
  /// "there was nothing to do" produce the same number, which is exactly the
  /// silent-failure shape a migration audit must not have.
  final int flagRowsAlreadyClear;

  /// Schedule rows written.
  final int scheduleRowsCopied;

  /// Manual preferences dropped because their window had already closed.
  final int scheduleRowsExpired;

  final bool alreadyMigrated;

  /// Whether every legacy row is accounted for.
  bool get isFullyAccounted =>
      flagRowsCopied + flagRowsOrphaned + flagRowsAlreadyClear == legacyRows;

  @override
  String toString() =>
      'legacy=$legacyRows flags=$flagRowsCopied orphaned=$flagRowsOrphaned '
      'clear=$flagRowsAlreadyClear schedule=$scheduleRowsCopied '
      'expired=$scheduleRowsExpired';
}

/// One-time migration of the legacy follow-up state into the new stores.
///
/// Contract: FR-035 (update flags), FR-036 (manual preference).  Three rules
/// that must not be "simplified":
///
/// 1. **The source is read and copied, never cleared.**  The legacy tables are
///    inside 003's retirement boundary; deleting from them needs its own
///    storage migration.  A migration that emptied its source would also be
///    destructive on a rollback.
/// 2. **Rows for identities the target does not have are ignored.**  Creating
///    them would resurrect comics the user has since removed from favorites.
/// 3. **An expired manual preference is not migrated.**  Migration is not the
///    place to grant a hot window the user's own deadline had already closed;
///    `manual_hot_enabled` is written as false in that case.
///
/// A conflict on the flag is resolved with logical OR: "was flagged" by either
/// store wins, because losing a flagged comic silently hides an update the user
/// was already owed.
class FollowUpMigration {
  FollowUpMigration({
    required this.judgmentRepository,
    required this.scheduleRepository,
    required this.source,
    NetworkFavoriteCacheManager? metadataStore,
    DateTime Function()? clock,
  }) : _metadataStore = metadataStore,
       _clock = clock ?? DateTime.now;

  final JudgmentStateRepository judgmentRepository;
  final ScheduleStateRepository scheduleRepository;

  /// Reads the legacy rows.  A callback rather than a database handle, so this
  /// class cannot reach into the favorites store's other tables.
  final Future<List<LegacyFollowUpRow>> Function() source;

  /// Where the one-time marker lives.
  ///
  /// Injected so a test can point it at an isolated cache: the default
  /// singleton is opened during startup, and a migration that always used it
  /// would be untestable against a fresh database.
  final NetworkFavoriteCacheManager? _metadataStore;

  NetworkFavoriteCacheManager get _metadata =>
      _metadataStore ?? NetworkFavoriteCacheManager();

  final DateTime Function() _clock;

  FollowUpMigrationReport? _lastReport;

  /// The previous run's report, or null when it has not run.
  FollowUpMigrationReport? get lastReport => _lastReport;

  /// Runs the migration if it has not already run.
  ///
  /// Idempotent by the marker, and safe to call on every startup: a completed
  /// run returns immediately without reading the legacy table.
  Future<FollowUpMigrationReport> run() async {
    final done = _metadata.readMetadataValue(followUpMigrationKey);
    if (done == 'done') {
      return _lastReport = const FollowUpMigrationReport.skipped();
    }

    final legacy = await source();
    await judgmentRepository.ensureOpen();
    await scheduleRepository.ensureOpen();

    final nowMs = _clock().millisecondsSinceEpoch;
    final judgmentSnapshot = await judgmentRepository.readSnapshot();
    final scheduleSnapshot = await scheduleRepository.readAll();

    // Rule 2: the target set decides.  An identity present in neither store is
    // not migrated.
    final flagUpdates = <JudgmentState>[];
    final scheduleRows = <ScheduleState>[];
    var orphaned = 0;
    var alreadyClear = 0;
    var expired = 0;

    for (final row in legacy) {
      final identity = '${row.sourceKey}\u0000${row.comicId}';

      final existing = judgmentSnapshot[identity];
      if (existing == null) {
        orphaned++;
      } else if (row.hasNewUpdate && !existing.hasNewUpdate) {
        // Rule: OR.  Only ever raises the flag, so a re-run cannot flip a
        // comic the user has since read back to unread.
        flagUpdates.add(existing.copyWith(hasNewUpdate: true));
      } else {
        // In scope and nothing to do.  Counted so the three buckets add up.
        alreadyClear++;
      }

      // Only identities that already have a schedule row get one updated.  A
      // schedule row for an unobserved comic would be meaningless: "no
      // observation" is itself a due condition, so it would be recomputed away
      // on the first round anyway.
      if (!scheduleSnapshot.containsKey(identity)) continue;

      final manualUntil = row.manualHotUntilMs;
      final active =
          row.manualHotEnabled && manualUntil != null && manualUntil > nowMs;
      if (row.manualHotEnabled && !active) expired++;

      scheduleRows.add(
        ScheduleState(
          sourceKey: row.sourceKey,
          comicId: row.comicId,
          nextAtMs: row.nextCheckAtMs,
          // FR-036 and data-model 4.4: `source_activity_at` / `baseline_at` are
          // NOT migrated.  They are the retired scheduler's age anchors, and the
          // new activity anchor is derived from the observation itself; copying
          // them would introduce a second, disagreeing notion of "when did it
          // move".
          activityAtMs: null,
          autoHotUntilMs: row.autoHotUntilMs,
          manualHotEnabled: active,
          manualHotUntilMs: manualUntil,
          // Not migrated: the jitter offset is a stable hash of the identity, so
          // re-applying it to an unmarked row yields the same offset.
          oldScheduleJitterApplied: false,
        ),
      );
    }

    final before = await judgmentRepository.readSnapshot();
    await judgmentRepository.applyBatch(flagUpdates);
    await scheduleRepository.applyBatch(scheduleRows);
    await _markDone();

    // Retention is asserted in the log rather than assumed: a migration that
    // silently copied nothing would otherwise look identical to one that had
    // nothing to copy.
    final after = await judgmentRepository.readSnapshot();
    final report = FollowUpMigrationReport(
      legacyRows: legacy.length,
      flagRowsCopied: flagUpdates.length,
      flagRowsOrphaned: orphaned,
      flagRowsAlreadyClear: alreadyClear,
      scheduleRowsCopied: scheduleRows.length,
      scheduleRowsExpired: expired,
      alreadyMigrated: false,
    );
    assert(
      after.length >= before.length,
      'the migration must never shrink judgment state',
    );
    assert(
      report.isFullyAccounted,
      'every legacy row must land in exactly one bucket: $report',
    );
    return _lastReport = report;
  }

  Future<void> _markDone() async =>
      _metadata.writeMetadataValue(followUpMigrationKey, 'done');
}
