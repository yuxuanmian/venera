import 'dart:async';

import '../follow_update_schedule.dart';
import '../tracking/judgment.dart';
import '../tracking/judgment_event.dart';
import 'schedule_repository.dart';
import 'schedule_state.dart';

/// Recomputes one identity's schedule from one judgment row.
///
/// Pure: no clock, no repository, no source request.  Everything it needs is in
/// its arguments, which is what makes the whole algorithm testable without a
/// database and keeps the schedule domain from reaching into either of the
/// other two stores (Contract S3).
///
/// [previous] may be null, meaning this identity has no schedule yet.
ScheduleState recomputeSchedule({
  required JudgmentRowResult row,
  required ScheduleState? previous,
}) {
  // ---- Activity anchor, three tiers, first hit wins (Contract S5) ----
  //
  // 1. what the source itself said the content's time was;
  // 2. else this row's recorded anchor, when the source declares no time;
  // 3. else this comic's first observation.
  //
  // Tier 3 is `row.observedAtMs` and NOT "now": an observation's landing time
  // is a fixed historical fact, so the anchor ages naturally and the comic
  // migrates to slower bands over time.  Using the current check time instead
  // would make every long-dormant comic look freshly active on every check, so
  // the check frequency would rise with the number of checks — the opposite of
  // what a schedule is for.
  final activityAtMs =
      row.activityAt?.millisecondsSinceEpoch ??
      previous?.activityAtMs ??
      row.observedAtMs;

  // ---- Automatic hot window (Contract S6.1) ----
  //
  // Set only by "content changed".  Every other conclusion — including
  // "content unchanged" — leaves it exactly as it was: not set, not extended.
  // The window expresses "this content is active", not "we looked at it
  // recently"; treating the latter as activity would keep every comic hot
  // forever.
  final completion = DateTime.fromMillisecondsSinceEpoch(
    row.observedAtMs,
    isUtc: true,
  );
  final autoHotUntilMs = row.conclusion == JudgmentConclusion.changed
      ? completion.add(kFollowUpdateHotWindow).millisecondsSinceEpoch
      : previous?.autoHotUntilMs;

  final carrier = ScheduleState(
    sourceKey: row.sourceKey,
    comicId: row.comicId,
    activityAtMs: activityAtMs,
    autoHotUntilMs: autoHotUntilMs,
    // User preference and the one-time jitter marker are carried, never
    // derived: S6.2 keeps the manual window a pure user preference, and the
    // jitter is a stable hash that the algorithm itself decides to consume.
    manualHotEnabled: previous?.manualHotEnabled ?? false,
    manualHotUntilMs: previous?.manualHotUntilMs,
    oldScheduleJitterApplied: previous?.oldScheduleJitterApplied ?? false,
  );

  return _withDecision(carrier, _decideFor(carrier, completion, activityAtMs));
}

ScheduleDecision _decideFor(
  ScheduleState carrier,
  DateTime completion,
  int activityAtMs,
) => computeNextSchedule(
  completedAt: completion,
  effectiveActivityAt: DateTime.fromMillisecondsSinceEpoch(
    activityAtMs,
    isUtc: true,
  ),
  autoHotUntil: carrier.autoHotUntilMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(
          carrier.autoHotUntilMs!,
          isUtc: true,
        ),
  manualHotEnabled: carrier.manualHotEnabled,
  manualHotUntil: carrier.manualHotUntilMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(
          carrier.manualHotUntilMs!,
          isUtc: true,
        ),
  oldScheduleJitterApplied: carrier.oldScheduleJitterApplied,
  sourceKey: carrier.sourceKey,
  comicId: carrier.comicId,
);

ScheduleState _withDecision(ScheduleState carrier, ScheduleDecision decision) =>
    ScheduleState(
      sourceKey: carrier.sourceKey,
      comicId: carrier.comicId,
      nextAtMs: decision.nextCheckAt.millisecondsSinceEpoch,
      activityAtMs: carrier.activityAtMs,
      autoHotUntilMs: carrier.autoHotUntilMs,
      manualHotEnabled: carrier.manualHotEnabled,
      manualHotUntilMs: carrier.manualHotUntilMs,
      oldScheduleJitterApplied: decision.appliedOldScheduleJitter,
    );

/// Subscribes to judgment batches and keeps the schedule store current.
///
/// Contract: `specs/006-local-follow-up-loop/contracts/schedule-v1.md`.
///
/// The direction of the dependency is the whole design: judgment publishes,
/// the schedule consumes, and the schedule never writes judgment or
/// observation state.  There is deliberately **no** "recompute everything"
/// entry point — clearing the store is how a rebuild is requested, because
/// "no schedule record" is itself a due condition (S4), so every identity
/// returns to the due set by itself.
class ScheduleService {
  ScheduleService({
    required ScheduleStateRepository repository,
    required Stream<JudgmentBatchEvent> events,
    DateTime Function()? clock,
  }) : _repository = repository,
       _events = events,
       _clock = clock ?? DateTime.now;

  final ScheduleStateRepository _repository;
  final Stream<JudgmentBatchEvent> _events;
  final DateTime Function() _clock;

  StreamSubscription<JudgmentBatchEvent>? _subscription;

  /// Begins consuming judgment batches.  Idempotent.
  void listen() => _subscription ??= _events.listen(recomputeFromEvent);

  /// Recomputes every row of one batch and writes it in one transaction.
  ///
  /// Per batch rather than per run, so a check that is terminated halfway still
  /// has correct next-times for everything it finished.  This is the only
  /// source of resumability in the feature (S3).
  Future<int> recomputeFromEvent(JudgmentBatchEvent event) async {
    if (event.rows.isEmpty) return 0;
    await _repository.ensureOpen();
    final previous = await _repository.readAll();
    final recomputed = <ScheduleState>[];
    for (final row in event.rows) {
      recomputed.add(
        recomputeSchedule(row: row, previous: previous[row.identity]),
      );
    }
    return _repository.applyBatch(recomputed);
  }

  /// Reads one identity's stored schedule for **presentation only** (007).
  ///
  /// Contract W4/W8 and FR-030: this is a thin, side-effect-free passthrough.
  /// It MUST NOT trigger a scan, a judgment or a recompute; it MUST NOT write
  /// anything; it MUST NOT create a row to satisfy a caller.  A `null` result
  /// means "this comic has no check record yet" and is a normal state.
  ///
  /// The one production caller is the details page indicator, which asks
  /// whether the automatic hot window is still open.  Keeping the read here
  /// rather than in the page is what stops the page from re-deriving schedule
  /// rules (Contract W3).
  Future<ScheduleState?> readIdentity(String sourceKey, String comicId) async {
    await _repository.ensureOpen();
    return _repository.readByIdentity(sourceKey, comicId);
  }

  /// The identities of one source whose recorded schedule says "due".
  ///
  /// Answers only the two conditions the schedule store can answer alone
  /// (Contract S4): the caller merges in "has no observation" and "has no
  /// schedule record" before treating the result as the complete due set.
  Future<Set<String>> expiredIdentities(String sourceKey, {int? nowMs}) async {
    await _repository.ensureOpen();
    final expired = await _repository.readExpired(
      nowMs ?? _clock().millisecondsSinceEpoch,
    );
    return {
      for (final state in expired.values)
        if (state.sourceKey == sourceKey) state.comicId,
    };
  }

  /// The identities of one source whose recorded schedule is still in the
  /// future.
  ///
  /// The complement of [expiredIdentities] within "has a schedule record".
  /// Both are needed to evaluate S4 completely: the merge has to know whether a
  /// record exists at all, not only whether it has expired.
  Future<Set<String>> futureIdentities(String sourceKey, {int? nowMs}) async {
    await _repository.ensureOpen();
    final all = await _repository.readAll();
    final now = nowMs ?? _clock().millisecondsSinceEpoch;
    return {
      for (final state in all.values)
        if (state.sourceKey == sourceKey &&
            state.nextAtMs != null &&
            state.nextAtMs! > now)
          state.comicId,
    };
  }

  /// Deletes every schedule row.  Every identity becomes due again.
  Future<void> clear() => _repository.clear();

  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    await _repository.close();
  }
}
