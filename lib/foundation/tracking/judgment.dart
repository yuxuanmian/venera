// The judgment engine: a pure comparison of two observations plus the
// recorded comparable label.
//
// Contract: `specs/005-tracking-reconnect/contracts/judgment-v1.md`.
//
// The engine must never consult a clock, a network or any history beyond the
// values handed to it.  The visible flag (J6) and the time guard (J9) are the
// two documented exceptions, and both take their "current time" from the
// caller through `decidedAtMs`.

import 'dart:convert';

import '../tracking_time_guard.dart';
import 'comparability.dart';
import 'judgment_state.dart';

/// The judgment algorithm version.
///
/// Persisted with every decision so a rule change is detected on the next run:
/// the service compares the stored version against this constant and recomputes
/// any row produced by a different one.  Without it a run would skip every row
/// by `processedAttemptId`, and a repaired rule would never reach data that had
/// already been judged (US2 acceptance scenario 2).
///
/// **Bump this when a change alters what [decide] returns for the same
/// inputs** — the evidence tier order, the conclusion or reason mapping, the
/// visible-flag rule, or the time semantics.  Purely cosmetic changes, new
/// storage columns and diagnostics improvements do **not** need a bump.
///
/// A bump has a deliberate consequence: the next run reprocesses every stored
/// observation and rewrites every judgment state row.  It issues no source
/// request and needs no re-scan, but it does discard comparison results that
/// were produced by rules which no longer apply — which is exactly the point.
const int judgmentAlgorithmVersion = 1;

/// The four comparison conclusions (Contract J3).
enum JudgmentConclusion { changed, unchanged, rebaseline, unknown }

/// Evidence tiers in fixed priority order (Contract J2).
///
/// `marker` is deliberately absent: that tier was retired by this feature and
/// judgment must neither accept nor produce one.
enum JudgmentEvidence {
  updatedAt,
  latestChapterId,
  chapterCount,
  recentChapterIds,
}

/// The closed reason vocabulary (Contract J5), exactly 14 values.
///
/// This enum, the CHECK constraint in `contracts/state-schema.sql` and the
/// engine implementation must agree character for character.
///
/// `labelChanged` and `noPreviousEvidence` are distinct situations: the first
/// means "the comparison baseline changed meaning", the second means "this
/// device never compared this comic".  They must not be merged.
enum JudgmentReason {
  noUsableEvidence,
  noPreviousEvidence,
  labelChanged,
  noCommonEvidence,
  later,
  regressed,
  equal,
  different,
  increased,
  decreased,
  sameFirst,
  newerAnchor,
  noSafeAnchor,
  priority,
}

extension JudgmentConclusionValue on JudgmentConclusion {
  String get value => name;

  static JudgmentConclusion? parse(Object? value) {
    for (final candidate in JudgmentConclusion.values) {
      if (candidate.name == value) return candidate;
    }
    return null;
  }
}

extension JudgmentEvidenceValue on JudgmentEvidence {
  String get value => name;

  static JudgmentEvidence? parse(Object? value) {
    for (final candidate in JudgmentEvidence.values) {
      if (candidate.name == value) return candidate;
    }
    return null;
  }
}

extension JudgmentReasonValue on JudgmentReason {
  String get value => name;

  static JudgmentReason? parse(Object? value) {
    for (final candidate in JudgmentReason.values) {
      if (candidate.name == value) return candidate;
    }
    return null;
  }
}

/// Lower bound of the accepted timestamp range (Contract J9).
///
/// Re-exported from the shared guard so judgment and the follow-up schedule
/// parser cannot drift apart.
final DateTime judgmentTimeFloor = timestampWindowFloor;

/// Upper bound slack over the caller-supplied "now" (Contract J9).
const Duration judgmentTimeCeilingSlack = timestampWindowCeilingSlack;

/// Parses one observation JSON string into its raw map.
///
/// Returns null when the payload is not a JSON object; the engine then treats
/// the observation as having no usable evidence.
Map<String, Object?>? _decodeObservation(String? json) {
  if (json == null) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(json);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  return decoded.cast<String, Object?>();
}

/// The parsed, comparable projection of one observation.
class _Evidence {
  _Evidence({
    this.updatedAt,
    this.updatedAtText,
    this.latestChapterId,
    this.chapterCount,
    this.recentChapterIds,
    this.sourceUnread,
  });

  final DateTime? updatedAt;

  /// The raw text of `updatedAt`, preserved verbatim for reporting.
  final String? updatedAtText;
  final String? latestChapterId;
  final int? chapterCount;
  final List<String>? recentChapterIds;

  /// The account-level unread signal; not content evidence (Contract J2).
  final bool? sourceUnread;

  bool get hasAnyEvidence => hasContentEvidence || sourceUnread != null;

  bool get hasContentEvidence =>
      updatedAt != null ||
      latestChapterId != null ||
      chapterCount != null ||
      (recentChapterIds?.isNotEmpty ?? false);

  /// Evidence fields both sides carry, in tier order.
  List<JudgmentEvidence> sharedWith(_Evidence other) {
    final shared = <JudgmentEvidence>[];
    if (updatedAt != null && other.updatedAt != null) {
      shared.add(JudgmentEvidence.updatedAt);
    }
    if (latestChapterId != null && other.latestChapterId != null) {
      shared.add(JudgmentEvidence.latestChapterId);
    }
    if (chapterCount != null && other.chapterCount != null) {
      shared.add(JudgmentEvidence.chapterCount);
    }
    if ((recentChapterIds?.isNotEmpty ?? false) &&
        (other.recentChapterIds?.isNotEmpty ?? false)) {
      shared.add(JudgmentEvidence.recentChapterIds);
    }
    return shared;
  }
}

/// A single comparison conclusion plus the values it compared.
class _TierResult {
  const _TierResult({
    required this.conclusion,
    required this.reason,
    required this.previousValue,
    required this.currentValue,
  });

  final JudgmentConclusion conclusion;
  final JudgmentReason reason;
  final String previousValue;
  final String currentValue;
}

/// Reads the raw observation into comparable evidence.
///
/// Each field is sanitized independently: an invalid value drops only itself
/// (Contract J9) and never invalidates its siblings.
_Evidence _readEvidence(Map<String, Object?>? raw, {required DateTime now}) {
  if (raw == null) return _Evidence();
  final update = raw['update'];
  final updateMap = update is Map ? update.cast<String, Object?>() : null;

  DateTime? updatedAt;
  String? updatedAtText;
  if (updateMap != null) {
    final rawUpdatedAt = updateMap['updatedAt'];
    if (rawUpdatedAt is String) {
      final candidate = rawUpdatedAt.trim();
      final parsed = parseInstant(candidate, now);
      if (parsed != null) {
        updatedAt = parsed;
        updatedAtText = candidate;
      }
    }
  }

  String? latestChapterId;
  if (updateMap != null) {
    final rawLatest = updateMap['latestChapterId'];
    if (rawLatest is String) {
      final candidate = rawLatest.trim();
      if (candidate.isNotEmpty) latestChapterId = candidate;
    }
  }

  int? chapterCount;
  if (updateMap != null) {
    final rawCount = updateMap['chapterCount'];
    if (rawCount is int && rawCount >= 0) {
      chapterCount = rawCount;
    } else if (rawCount is num &&
        rawCount.isFinite &&
        rawCount == rawCount.truncate() &&
        rawCount >= 0) {
      chapterCount = rawCount.toInt();
    }
  }

  List<String>? recentChapterIds;
  if (updateMap != null) {
    final rawRecent = updateMap['recentChapterIds'];
    if (rawRecent is List) {
      final ids = <String>[];
      for (final value in rawRecent) {
        if (value is! String) continue;
        final candidate = value.trim();
        if (candidate.isEmpty || ids.contains(candidate)) continue;
        ids.add(candidate);
        if (ids.length == 5) break;
      }
      if (ids.isNotEmpty) recentChapterIds = List.unmodifiable(ids);
    }
  }

  final rawUnread = raw['sourceUnread'];
  final sourceUnread = rawUnread is bool ? rawUnread : null;

  return _Evidence(
    updatedAt: updatedAt,
    updatedAtText: updatedAtText,
    latestChapterId: latestChapterId,
    chapterCount: chapterCount,
    recentChapterIds: recentChapterIds,
    sourceUnread: sourceUnread,
  );
}

/// Compares only the strongest evidence tier both sides carry (Contract J2).
_TierResult _compareTier(
  _Evidence previous,
  _Evidence current,
  JudgmentEvidence tier,
) {
  switch (tier) {
    case JudgmentEvidence.updatedAt:
      final before = previous.updatedAt!;
      final after = current.updatedAt!;
      final (conclusion, reason) = after.isAfter(before)
          ? (JudgmentConclusion.changed, JudgmentReason.later)
          : after.isBefore(before)
          ? (JudgmentConclusion.rebaseline, JudgmentReason.regressed)
          : (JudgmentConclusion.unchanged, JudgmentReason.equal);
      return _TierResult(
        conclusion: conclusion,
        reason: reason,
        previousValue:
            previous.updatedAtText ?? before.toUtc().toIso8601String(),
        currentValue: current.updatedAtText ?? after.toUtc().toIso8601String(),
      );
    case JudgmentEvidence.latestChapterId:
      final before = previous.latestChapterId!;
      final after = current.latestChapterId!;
      return _TierResult(
        conclusion: before == after
            ? JudgmentConclusion.unchanged
            : JudgmentConclusion.changed,
        reason: before == after
            ? JudgmentReason.equal
            : JudgmentReason.different,
        previousValue: before,
        currentValue: after,
      );
    case JudgmentEvidence.chapterCount:
      final before = previous.chapterCount!;
      final after = current.chapterCount!;
      // 0 is a valid value and is distinct from "field absent".
      final (conclusion, reason) = after > before
          ? (JudgmentConclusion.changed, JudgmentReason.increased)
          : after < before
          ? (JudgmentConclusion.rebaseline, JudgmentReason.decreased)
          : (JudgmentConclusion.unchanged, JudgmentReason.equal);
      return _TierResult(
        conclusion: conclusion,
        reason: reason,
        previousValue: '$before',
        currentValue: '$after',
      );
    case JudgmentEvidence.recentChapterIds:
      final before = previous.recentChapterIds!;
      final after = current.recentChapterIds!;
      final previousFirst = before.first;
      final currentFirst = after.first;
      final previousAnchor = after.indexOf(previousFirst);
      final currentAnchor = before.indexOf(currentFirst);
      final JudgmentConclusion conclusion;
      final JudgmentReason reason;
      if (currentFirst == previousFirst) {
        conclusion = JudgmentConclusion.unchanged;
        reason = JudgmentReason.sameFirst;
      } else if (previousAnchor > 0) {
        conclusion = JudgmentConclusion.changed;
        reason = JudgmentReason.newerAnchor;
      } else {
        conclusion = JudgmentConclusion.rebaseline;
        reason = currentAnchor > 0
            ? JudgmentReason.regressed
            : JudgmentReason.noSafeAnchor;
      }
      return _TierResult(
        conclusion: conclusion,
        reason: reason,
        previousValue: jsonEncode(before),
        currentValue: jsonEncode(after),
      );
  }
}

/// Whether a lower-priority shared tier contradicts the selected conclusion
/// (Contract J7).
///
/// The conclusion is never overturnable; only the reason records the
/// disagreement.
bool _lowerEvidenceDisagrees(
  _Evidence previous,
  _Evidence current,
  JudgmentEvidence selected,
) {
  final selectedIndex = JudgmentEvidence.values.indexOf(selected);
  for (
    var index = selectedIndex + 1;
    index < JudgmentEvidence.values.length;
    index++
  ) {
    final tier = JudgmentEvidence.values[index];
    switch (tier) {
      case JudgmentEvidence.updatedAt:
        if (previous.updatedAt != null &&
            current.updatedAt != null &&
            previous.updatedAt != current.updatedAt) {
          return true;
        }
      case JudgmentEvidence.latestChapterId:
        if (previous.latestChapterId != null &&
            current.latestChapterId != null &&
            previous.latestChapterId != current.latestChapterId) {
          return true;
        }
      case JudgmentEvidence.chapterCount:
        if (previous.chapterCount != null &&
            current.chapterCount != null &&
            previous.chapterCount != current.chapterCount) {
          return true;
        }
      case JudgmentEvidence.recentChapterIds:
        if ((previous.recentChapterIds?.isNotEmpty ?? false) &&
            (current.recentChapterIds?.isNotEmpty ?? false) &&
            previous.recentChapterIds!.first !=
                current.recentChapterIds!.first) {
          return true;
        }
    }
  }
  return false;
}

/// Resolves the sticky visible flag (Contract J6).
///
/// An explicit source signal always wins, regardless of the conclusion class.
bool _resolveVisibleFlag({
  required bool previousHasNewUpdate,
  required bool? sourceUnread,
  required JudgmentConclusion conclusion,
}) {
  if (sourceUnread == true) return true;
  if (sourceUnread == false) return false;
  if (conclusion == JudgmentConclusion.changed) return true;
  return previousHasNewUpdate;
}

/// Compares a stored fact against a current observation.
///
/// The five-step order is fixed by the Contract J4 decision table and must not
/// be reordered: "no usable evidence" has to precede "no previous evidence",
/// otherwise an empty observation would be mistaken for a first baseline.
JudgmentOutcome decide({
  required String? previousFactJson,
  required String? recordedLabel,
  required String currentObservationJson,
  required String currentLabel,
  required int currentObservedAtMs,
  required int decidedAtMs,
  required bool previousHasNewUpdate,
  required int previousNoCommonStreak,
}) {
  final now = DateTime.fromMillisecondsSinceEpoch(decidedAtMs, isUtc: true);
  final current = _readEvidence(
    _decodeObservation(currentObservationJson),
    now: now,
  );
  final previous = _readEvidence(
    _decodeObservation(previousFactJson),
    now: now,
  );

  JudgmentOutcome build({
    required JudgmentConclusion conclusion,
    required JudgmentReason reason,
    required bool factAdvanced,
    required int noCommonStreak,
    JudgmentEvidence? selectedEvidence,
    String? previousValue,
    String? currentValue,
    String? factJson,
    int? factObservedAtMs,
    String? evidenceSchema,
  }) => JudgmentOutcome(
    conclusion: conclusion,
    selectedEvidence: selectedEvidence,
    reason: reason,
    previousValue: previousValue,
    currentValue: currentValue,
    decidedAtMs: decidedAtMs,
    factAdvanced: factAdvanced,
    factJson: factJson,
    factObservedAtMs: factObservedAtMs,
    evidenceSchema: evidenceSchema,
    noCommonStreak: noCommonStreak,
    previousHasNewUpdate: previousHasNewUpdate,
    hasNewUpdate: _resolveVisibleFlag(
      previousHasNewUpdate: previousHasNewUpdate,
      sourceUnread: current.sourceUnread,
      conclusion: conclusion,
    ),
  );

  // 1. The current observation carries no usable evidence at all.
  if (!current.hasAnyEvidence) {
    return build(
      conclusion: JudgmentConclusion.unknown,
      reason: JudgmentReason.noUsableEvidence,
      factAdvanced: false,
      noCommonStreak: previousNoCommonStreak,
      factJson: previousFactJson,
    );
  }

  // 2. No previous fact: first decision, or the state was cleared.
  if (previousFactJson == null) {
    return build(
      conclusion: JudgmentConclusion.rebaseline,
      reason: JudgmentReason.noPreviousEvidence,
      factAdvanced: true,
      noCommonStreak: 0,
      factJson: currentObservationJson,
      factObservedAtMs: currentObservedAtMs,
      evidenceSchema: currentLabel,
    );
  }

  // 3. The comparison baseline changed meaning: rebuild it, report no update.
  if (!ComparableLabel.matches(recordedLabel, currentLabel)) {
    return build(
      conclusion: JudgmentConclusion.rebaseline,
      reason: JudgmentReason.labelChanged,
      factAdvanced: true,
      noCommonStreak: 0,
      factJson: currentObservationJson,
      factObservedAtMs: currentObservedAtMs,
      evidenceSchema: currentLabel,
    );
  }

  // 4. Both sides carry content evidence with at least one shared field.
  final shared = previous.sharedWith(current);
  if (shared.isNotEmpty) {
    final tier = shared.first;
    final result = _compareTier(previous, current, tier);
    final disagrees = _lowerEvidenceDisagrees(previous, current, tier);
    return build(
      conclusion: result.conclusion,
      reason: disagrees ? JudgmentReason.priority : result.reason,
      selectedEvidence: tier,
      previousValue: result.previousValue,
      currentValue: result.currentValue,
      factAdvanced: true,
      noCommonStreak: 0,
      factJson: currentObservationJson,
      factObservedAtMs: currentObservedAtMs,
      evidenceSchema: currentLabel,
    );
  }

  // 5. Both sides carry content evidence, but nothing in common.  The fact is
  // deliberately *not* advanced: advancing it would let alternating field sets
  // swallow a real change forever (Contract J4 note 1).
  if (previous.hasContentEvidence && current.hasContentEvidence) {
    return build(
      conclusion: JudgmentConclusion.unknown,
      reason: JudgmentReason.noCommonEvidence,
      factAdvanced: false,
      noCommonStreak: previousNoCommonStreak + 1,
      factJson: previousFactJson,
    );
  }

  // The current observation carried only an account-level signal, so it is not
  // usable content evidence; the fact stays put and the streak is unchanged.
  return build(
    conclusion: JudgmentConclusion.unknown,
    reason: JudgmentReason.noUsableEvidence,
    factAdvanced: false,
    noCommonStreak: previousNoCommonStreak,
    factJson: previousFactJson,
  );
}

/// Parses one timestamp field into the instant used for comparison, or null
/// when the value must be dropped.
///
/// Contract J9 rules:
///
/// - a full instant carrying an explicit timezone is accepted and compared as
///   an instant (two different offsets denoting the same moment compare equal);
/// - a date-only value is accepted and compared as that day's start (UTC);
/// - the time guard rejects a value outside
///   `[2000-01-01, now + 24h]`, dropping only that field;
/// - nothing is ever converted to midnight for storage, upgraded in precision,
///   or guessed as local time — the raw string is what the fact keeps.
///
/// [now] is injected by the caller; this function must never read the system
/// clock, or the same evidence would produce different conclusions at
/// different times (research R-08).
DateTime? parseInstant(String value, DateTime now) {
  final candidate = value.trim();
  final period = _timePeriod(candidate);
  if (period == null) return null;
  // The whole represented period must sit inside the guard window.  A
  // date-only value therefore gets a one-day window, which is what makes
  // `2026-09-10` acceptable at `2026-09-10T12:00Z` rather than looking like a
  // future value.
  final ceiling = now.toUtc().add(judgmentTimeCeilingSlack);
  if (period.start.isBefore(judgmentTimeFloor)) return null;
  if (period.end.isAfter(ceiling)) return null;
  return period.start;
}

/// The instant range one timestamp representation covers.
///
/// A full instant covers zero duration; a date-only value covers its whole day
/// because that is genuinely all the source told us (Contract J9 accepts the
/// resulting same-day blind spot).
class _TimePeriod {
  const _TimePeriod(this.start, this.end);

  final DateTime start;
  final DateTime end;
}

/// Reads the two accepted timestamp forms and rejects everything else.
///
/// This mirrors the calendar and explicit-timezone validation the scan codec
/// already applies, so judgment never becomes a fourth opinion about what a
/// timestamp looks like.
_TimePeriod? _timePeriod(String value) {
  final date = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (date != null) {
    final year = int.parse(date.group(1)!);
    final month = int.parse(date.group(2)!);
    final day = int.parse(date.group(3)!);
    if (!_validCalendarDate(year, month, day)) return null;
    final start = DateTime.utc(year, month, day);
    return _TimePeriod(start, start.add(const Duration(days: 1)));
  }
  final time = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:\d{2})$',
  ).firstMatch(value);
  if (time == null) return null;
  final year = int.parse(time.group(1)!);
  final month = int.parse(time.group(2)!);
  final day = int.parse(time.group(3)!);
  if (!_validCalendarDate(year, month, day)) return null;
  if (int.parse(time.group(4)!) > 23 ||
      int.parse(time.group(5)!) > 59 ||
      int.parse(time.group(6)!) > 59) {
    return null;
  }
  final offset = time.group(7)!;
  if (offset != 'Z') {
    if (int.parse(offset.substring(1, 3)) > 23 ||
        int.parse(offset.substring(4, 6)) > 59) {
      return null;
    }
  }
  late final DateTime instant;
  try {
    instant = DateTime.parse(value).toUtc();
  } catch (_) {
    return null;
  }
  return _TimePeriod(instant, instant);
}

bool _validCalendarDate(int year, int month, int day) {
  if (month < 1 || month > 12 || day < 1) return false;
  final leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
  const days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return day <= (month == 2 && leap ? 29 : days[month - 1]);
}
