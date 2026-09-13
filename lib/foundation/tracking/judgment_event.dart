import 'judgment.dart';

/// One legacy `comic_check_state` row, as the 006 migration needs it.
///
/// Lives here rather than beside the migration because the favorites store must
/// be able to *produce* it while the migration *consumes* it, and favorites
/// cannot import the migration without a cycle.  This module is the neutral one
/// both can reach.
///
/// **Narrowed by 007 (FR-009)**: it used to carry the retired scheduler's
/// columns (`nextCheckAtMs`, `autoHotUntilMs`, `manualHotEnabled`,
/// `manualHotUntilMs`) because the migration copied the manual preference into
/// the schedule store.  That half of the migration is gone — the manual hot
/// window is retired, and copying schedule columns is what made a re-run able to
/// blind-overwrite live schedule rows — so the projection is now exactly the
/// user-visible flag the migration still has a reason to move.
///
/// Deliberately narrower than the table: the migration must not be able to start
/// depending on a column that has no bearing on it.
class LegacyFollowUpRow {
  const LegacyFollowUpRow({
    required this.sourceKey,
    required this.comicId,
    required this.hasNewUpdate,
  });

  final String sourceKey;
  final String comicId;
  final bool hasNewUpdate;
}

/// One judged identity, as published to incremental consumers.
///
/// Contract: `specs/006-local-follow-up-loop/contracts/judgment-event-v1.md` E3.
class JudgmentRowResult {
  const JudgmentRowResult({
    required this.sourceKey,
    required this.comicId,
    required this.conclusion,
    required this.observedAtMs,
    this.activityAt,
  });

  final String sourceKey;
  final String comicId;

  /// The comparison conclusion.  Consumers use this to decide whether the
  /// content is active; they must not re-derive it from the observation.
  final JudgmentConclusion conclusion;

  /// When this observation landed on disk — the "completion time" that starts
  /// the next schedule.
  ///
  /// Carried by the event because the schedule store deliberately does not keep
  /// a copy (two copies drift, Contract S2).  Without it here the schedule
  /// service would have to read the acquisition store, which would make the
  /// schedule domain depend on the observation table's shape.
  final int observedAtMs;

  /// When the *content* moved, or null when the source declares no time field.
  ///
  /// The judgment engine already parses this while reading the evidence, so it
  /// is carried rather than re-parsed: a second parse would duplicate the
  /// logic and make the schedule domain depend on the observation payload.
  ///
  /// Null MUST NOT be filled in with [observedAtMs] or any other clock.  Doing
  /// so would hide "this source declares no time field" and turn the documented
  /// cold-start cost into silent behaviour.  The three-tier anchor fallback
  /// (Contract S5) needs to know the difference — it just does the fallback
  /// itself, in the one place that can also consult the previous schedule.
  final DateTime? activityAt;

  String get identity => '$sourceKey\u0000$comicId';

  @override
  String toString() =>
      'JudgmentRowResult($sourceKey/$comicId ${conclusion.value} '
      'observed=$observedAtMs activity=$activityAt)';
}

/// One batch of judged identities.
///
/// Granularity is the batch, payload is per row — the two are not a choice.
/// One event per row would be indistinguishable from row-by-row consumption;
/// one event per run would withhold the per-row activity time that Contract S5
/// needs.
///
/// This is a **runtime notification only**.  It is never persisted and has no
/// replay: a missed batch is recoverable, because the inputs to a recompute
/// (the observation's landing time and the time fields inside the recorded
/// fact) stay durable — the event only decides *when* the computation happens
/// (Contract E4).
class JudgmentBatchEvent {
  const JudgmentBatchEvent({required this.rows});

  final List<JudgmentRowResult> rows;

  bool get isEmpty => rows.isEmpty;

  @override
  String toString() => 'JudgmentBatchEvent(${rows.length} rows)';
}
