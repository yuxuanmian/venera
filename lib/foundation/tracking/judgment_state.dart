import 'judgment.dart';

/// Persisted judgment state value type.
/// Contract: `specs/005-tracking-reconnect/contracts/state-schema.sql` and
/// `specs/005-tracking-reconnect/data-model.md` section 2.
///
/// The table has exactly one row per `(sourceKey, comicId)`.  Column ownership
/// is explicit (data-model 2.4): judgment owns the fact, decision, visible-flag
/// and idempotency partitions only.  Future scheduling, health and
/// user-confirmation columns belong to other writers and must never appear in
/// this class.
class JudgmentState {
  const JudgmentState({
    required this.sourceKey,
    required this.comicId,
    required this.lastDecision,
    required this.lastReason,
    required this.decidedAtMs,
    this.factJson,
    this.factObservedAtMs,
    this.evidenceSchema,
    this.lastEvidence,
    this.lastPreviousValue,
    this.lastCurrentValue,
    this.noCommonStreak = 0,
    this.hasNewUpdate = false,
    this.processedAttemptId,
    this.algorithmVersion,
  });

  final String sourceKey;
  final String comicId;

  // ---- Fact (watermark) ----

  /// The last adopted observation, kept as its **raw JSON** so the original
  /// `updatedAt` representation is never rewritten by parsing.
  final String? factJson;

  /// Formation time of [factJson].
  final int? factObservedAtMs;

  /// Comparable label of [factJson]; required whenever a fact exists.
  final String? evidenceSchema;

  // ---- Decision result ----

  final JudgmentConclusion lastDecision;
  final JudgmentEvidence? lastEvidence;

  /// The comparison pair of this decision.  Persisted because advancing the
  /// fact replaces `factJson`, making the previous value otherwise
  /// unrecoverable.
  final String? lastPreviousValue;
  final String? lastCurrentValue;
  final JudgmentReason lastReason;
  final int decidedAtMs;

  /// Consecutive "has content evidence but no common field" observations.
  final int noCommonStreak;

  // ---- Visible flag and idempotency ----

  /// Sticky boolean; the authoritative value read by behaviour.
  final bool hasNewUpdate;

  /// Identity of the last processed observation.  Kept separate from
  /// [factObservedAtMs] because `unknown` does not advance the fact.
  final String? processedAttemptId;

  /// The [judgmentAlgorithmVersion] that produced this row.
  ///
  /// Null for rows written before the column existed, which is exactly the
  /// signal that they must be recomputed: a stored decision with no recorded
  /// rule version cannot be trusted to match the current rules.
  final int? algorithmVersion;

  /// Whether this row was produced by the current rules.
  bool get isCurrentAlgorithm => algorithmVersion == judgmentAlgorithmVersion;

  /// The composite identity used as the snapshot map key.
  String get identity => '$sourceKey\u0000$comicId';

  JudgmentState copyWith({
    bool? hasNewUpdate,
    int? noCommonStreak,
    String? processedAttemptId,
  }) => JudgmentState(
    sourceKey: sourceKey,
    comicId: comicId,
    factJson: factJson,
    factObservedAtMs: factObservedAtMs,
    evidenceSchema: evidenceSchema,
    lastDecision: lastDecision,
    lastEvidence: lastEvidence,
    lastPreviousValue: lastPreviousValue,
    lastCurrentValue: lastCurrentValue,
    lastReason: lastReason,
    decidedAtMs: decidedAtMs,
    noCommonStreak: noCommonStreak ?? this.noCommonStreak,
    hasNewUpdate: hasNewUpdate ?? this.hasNewUpdate,
    processedAttemptId: processedAttemptId ?? this.processedAttemptId,
    algorithmVersion: algorithmVersion,
  );

  bool get hasFact => factJson != null;

  @override
  String toString() =>
      'JudgmentState($sourceKey/$comicId ${lastDecision.value} '
      '${lastReason.value})';
}

/// Output of one comparison (Contract J / data-model section 1).
///
/// Contains only judgment-owned values: no scheduling, health or
/// user-confirmation field may be added here.
class JudgmentOutcome {
  const JudgmentOutcome({
    required this.conclusion,
    required this.reason,
    required this.decidedAtMs,
    required this.previousHasNewUpdate,
    required this.hasNewUpdate,
    required this.noCommonStreak,
    required this.factAdvanced,
    this.selectedEvidence,
    this.previousValue,
    this.currentValue,
    this.factJson,
    this.factObservedAtMs,
    this.evidenceSchema,
    this.activityAt,
  });

  final JudgmentConclusion conclusion;
  final JudgmentEvidence? selectedEvidence;
  final JudgmentReason reason;
  final String? previousValue;
  final String? currentValue;
  final int decidedAtMs;

  /// When the *content* moved, parsed from this observation's time field.
  ///
  /// Null means the source declared no usable time field — not "unknown yet".
  /// Published on the judgment event so the schedule domain can use it as the
  /// activity anchor (Contract E4 / Contract S5) without re-reading or
  /// re-parsing the observation payload.
  final DateTime? activityAt;

  /// Whether this decision replaced the stored fact (J4 "advance fact").
  final bool factAdvanced;

  /// Fact JSON after the decision; equals the previous fact when not advanced.
  final String? factJson;
  final int? factObservedAtMs;
  final String? evidenceSchema;

  final int noCommonStreak;
  final bool previousHasNewUpdate;
  final bool hasNewUpdate;
}
