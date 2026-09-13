/// Persisted schedule state value type.
///
/// Contract: `specs/006-local-follow-up-loop/contracts/schedule-state-schema.sql`
/// and `contracts/schedule-v1.md` (S1/S2).
///
/// The table has exactly one row per `(sourceKey, comicId)`, and the identity
/// is **identical** to `judgment_state`'s primary key.  Column ownership is
/// total here — this writer owns all seven columns — and the type deliberately
/// carries no observation, fact or conclusion field:
///
///  * "when did we last look at it" belongs to the observation
///    (`scan_item_state.observed_at_ms`) and is **not stored**, because a
///    second copy would drift from it (S2);
///  * "when did it last change" is carried by [activityAt] (S5);
///  * "did it change" belongs to the judgment domain and MUST NOT appear here.
class ScheduleState {
  const ScheduleState({
    required this.sourceKey,
    required this.comicId,
    this.nextAtMs,
    this.activityAtMs,
    this.autoHotUntilMs,
    this.manualHotEnabled = false,
    this.manualHotUntilMs,
    this.oldScheduleJitterApplied = false,
  });

  /// The `(sourceKey, comicId)` columns.  Both are part of the primary key.
  final String sourceKey;
  final String comicId;

  // ---- Schedule-owned columns (all seven) ----

  /// Next check time in milliseconds.
  ///
  /// Null means "not yet computed".  Because the due condition also accepts
  /// "no schedule record at all" (S4), a null here only ever appears on a row
  /// that already exists, and it is due.
  final int? nextAtMs;

  /// The content activity anchor, three-tier (S5): the event's content time,
  /// else this row's previous value, else the comic's first observation time.
  ///
  /// MUST NOT be set to "now" or to the last check time — that would make every
  /// long-dormant comic look freshly active each time it is checked.
  final int? activityAtMs;

  /// Automatic hot window deadline.  Set only when the judgment conclusion is
  /// `changed` (S6.1); never set or extended by any other conclusion.
  final int? autoHotUntilMs;

  /// User preference.  Derived from the user, never from a judgment (S6.2).
  final bool manualHotEnabled;

  /// Manual hot window deadline; non-null whenever [manualHotEnabled] is true
  /// (enforced by a CHECK constraint in the DDL).
  final int? manualHotUntilMs;

  /// One-time legacy jitter marker, written back from the algorithm result.
  ///
  /// Not migrated from the old store: the jitter offset is a stable hash of
  /// `(sourceKey, comicId)`, so re-applying it to an unmarked row yields the
  /// same offset and the behaviour is equivalent.
  final bool oldScheduleJitterApplied;

  /// The composite identity used as the snapshot map key.
  ///
  /// Byte-identical to [JudgmentState.identity] by construction, so the two
  /// stores can never disagree about what one comic is.
  String get identity => '$sourceKey\u0000$comicId';

  /// Whether a schedule has been computed for this identity at all.
  ///
  /// This is the "has a schedule record" half of the due condition; the caller
  /// merges it with "has an observation" (S4).
  bool get hasNextAt => nextAtMs != null;

  ScheduleState copyWith({
    int? nextAtMs,
    int? activityAtMs,
    int? autoHotUntilMs,
    bool? manualHotEnabled,
    int? manualHotUntilMs,
    bool? oldScheduleJitterApplied,
  }) => ScheduleState(
    sourceKey: sourceKey,
    comicId: comicId,
    nextAtMs: nextAtMs ?? this.nextAtMs,
    activityAtMs: activityAtMs ?? this.activityAtMs,
    autoHotUntilMs: autoHotUntilMs ?? this.autoHotUntilMs,
    manualHotEnabled: manualHotEnabled ?? this.manualHotEnabled,
    manualHotUntilMs: manualHotUntilMs ?? this.manualHotUntilMs,
    oldScheduleJitterApplied:
        oldScheduleJitterApplied ?? this.oldScheduleJitterApplied,
  );

  @override
  String toString() =>
      'ScheduleState($sourceKey/$comicId next=$nextAtMs '
      'activity=$activityAtMs hot=$autoHotUntilMs)';
}
