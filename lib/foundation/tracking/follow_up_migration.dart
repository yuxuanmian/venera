import '../favorites.dart';
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
///
/// **Narrowed by 007 (FR-009 / FR-010).**  It used to also report
/// `scheduleRowsCopied` / `scheduleRowsExpired`, because the migration copied
/// the manual hot-window preference into the schedule store.  That half is gone:
/// the manual hot window is retired as a user capability, and writing schedule
/// columns was the one path that could blind-overwrite a live `next_at` /
/// `auto_hot_until` on a re-run.  The report now describes only what the
/// migration still does — move the user-visible flag.
class FollowUpMigrationReport {
  const FollowUpMigrationReport({
    required this.legacyRows,
    required this.flagRowsCopied,
    required this.flagRowsOrphaned,
    required this.flagRowsAlreadyClear,
    required this.alreadyMigrated,
  });

  const FollowUpMigrationReport.skipped()
    : legacyRows = 0,
      flagRowsCopied = 0,
      flagRowsOrphaned = 0,
      flagRowsAlreadyClear = 0,
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

  final bool alreadyMigrated;

  /// Whether every legacy row is accounted for.
  bool get isFullyAccounted =>
      flagRowsCopied + flagRowsOrphaned + flagRowsAlreadyClear == legacyRows;

  @override
  String toString() =>
      'legacy=$legacyRows flags=$flagRowsCopied orphaned=$flagRowsOrphaned '
      'clear=$flagRowsAlreadyClear';
}

/// One-time migration of the legacy follow-up state into the new stores.
///
/// Contract: FR-035 (update flags).  Two rules that must not be "simplified":
///
/// 1. **The source is read and copied, never cleared.**  The legacy tables are
///    inside 003's retirement boundary; deleting from them needs its own
///    storage migration.  A migration that emptied its source would also be
///    destructive on a rollback.
/// 2. **Rows for identities the target does not have are ignored.**  Creating
///    them would resurrect comics the user has since removed from favorites.
///
/// A conflict on the flag is resolved with logical OR: "was flagged" by either
/// store wins, because losing a flagged comic silently hides an update the user
/// was already owed.
///
/// **What 007 removed (FR-009 / FR-010 / R-05).**  The migration used to have a
/// second half that copied the legacy scheduler columns — `next_check_at`,
/// `auto_hot_until` and the manual hot-window preference — into
/// `schedule_state`.  That half is deleted outright rather than guarded:
///
///  * the manual hot window is retired (it had no user-side writer left, so the
///    migration was the only thing that could ever turn it on), and
///  * it was **lazily destructive**: on a re-run it overwrote live schedule rows
///    with old values and `activityAtMs = null`, which is the registered
///    "重跑即盲写覆盖排期" risk this requirement closes.
///
/// So this migration now has exactly one effect: it may raise the user-visible
/// update flag in judgment state.  It MUST NOT create, update or delete any
/// schedule row.
class FollowUpMigration {
  FollowUpMigration({
    required this.judgmentRepository,
    required this.source,
    NetworkFavoriteCacheManager? metadataStore,
  }) : _metadataStore = metadataStore;

  final JudgmentStateRepository judgmentRepository;

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

    // No clock is read here any more: only the flag is moved, and a flag has no
    // time comparison.  The retired half compared `manual_hot_until` against
    // "now" to decide whether a preference had already lapsed.
    final legacy = await source();
    await judgmentRepository.ensureOpen();
    final judgmentSnapshot = await judgmentRepository.readSnapshot();

    // Rule 2: the target set decides.  An identity present in judgment state is
    // in scope; anything else is not migrated.
    final flagUpdates = <JudgmentState>[];
    var orphaned = 0;
    var alreadyClear = 0;

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
    }

    final before = await judgmentRepository.readSnapshot();
    await judgmentRepository.applyBatch(flagUpdates);
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
