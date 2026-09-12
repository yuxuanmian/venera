import 'judgment.dart';
import 'update_state.dart';

export 'judgment.dart'
    show
        JudgmentConclusion,
        JudgmentConclusionValue,
        JudgmentEvidence,
        JudgmentEvidenceValue,
        JudgmentReason,
        JudgmentReasonValue;

enum ContentChange { changed, unchanged, rebaseline, unknown }

enum EvidenceType { updatedAt, latestChapterId, chapterCount, recentChapterIds }

class ComparisonDecision {
  const ComparisonDecision({
    required this.contentChange,
    required this.selectedEvidence,
    required this.reason,
    this.previousValue,
    this.currentValue,
  });

  final ContentChange contentChange;
  final EvidenceType? selectedEvidence;

  /// Taken from the frozen [JudgmentReason] vocabulary (Contract J5) so the
  /// same value can be persisted and displayed without a second mapping.
  final JudgmentReason reason;

  final Object? previousValue;
  final Object? currentValue;
}

/// Compares only the strongest evidence available in both baselines.
///
/// The `marker` tier was retired by feature 005: it is no longer accepted as
/// an input and never selected as evidence (Contract J2).
ComparisonDecision compareTrackingEvidence({
  required UpdateState? previousState,
  required UpdateState? currentState,
}) {
  final usableCurrentState = currentState?.isUsable == true;
  final usablePreviousState = previousState?.isUsable == true;

  if (!usableCurrentState) {
    return const ComparisonDecision(
      contentChange: ContentChange.unknown,
      selectedEvidence: null,
      reason: JudgmentReason.noUsableEvidence,
    );
  }
  if (!usablePreviousState) {
    return const ComparisonDecision(
      contentChange: ContentChange.rebaseline,
      selectedEvidence: null,
      reason: JudgmentReason.noPreviousEvidence,
    );
  }

  if (previousState?.updatedAt != null && currentState?.updatedAt != null) {
    final previous = previousState!.updatedAt!;
    final current = currentState!.updatedAt!;
    final result = current.isAfter(previous)
        ? ContentChange.changed
        : current.isBefore(previous)
        ? ContentChange.rebaseline
        : ContentChange.unchanged;
    return _decision(
      result,
      EvidenceType.updatedAt,
      result == ContentChange.changed
          ? JudgmentReason.later
          : result == ContentChange.rebaseline
          ? JudgmentReason.regressed
          : JudgmentReason.equal,
      previous,
      current,
      lowerEvidenceDisagrees: _lowerEvidenceDisagrees(
        previousState,
        currentState,
        selected: EvidenceType.updatedAt,
      ),
    );
  }

  if (previousState?.latestChapterId != null &&
      currentState?.latestChapterId != null) {
    final previous = previousState!.latestChapterId!;
    final current = currentState!.latestChapterId!;
    final result = previous == current
        ? ContentChange.unchanged
        : ContentChange.changed;
    return _decision(
      result,
      EvidenceType.latestChapterId,
      previous == current ? JudgmentReason.equal : JudgmentReason.different,
      previous,
      current,
      lowerEvidenceDisagrees: _lowerEvidenceDisagrees(
        previousState,
        currentState,
        selected: EvidenceType.latestChapterId,
      ),
    );
  }

  if (previousState?.chapterCount != null &&
      currentState?.chapterCount != null) {
    final previous = previousState!.chapterCount!;
    final current = currentState!.chapterCount!;
    final result = current > previous
        ? ContentChange.changed
        : current < previous
        ? ContentChange.rebaseline
        : ContentChange.unchanged;
    return _decision(
      result,
      EvidenceType.chapterCount,
      result == ContentChange.changed
          ? JudgmentReason.increased
          : result == ContentChange.rebaseline
          ? JudgmentReason.decreased
          : JudgmentReason.equal,
      previous,
      current,
      lowerEvidenceDisagrees: _lowerEvidenceDisagrees(
        previousState,
        currentState,
        selected: EvidenceType.chapterCount,
      ),
    );
  }

  final previousRecent = previousState?.recentChapterIds;
  final currentRecent = currentState?.recentChapterIds;
  if (previousRecent?.isNotEmpty == true && currentRecent?.isNotEmpty == true) {
    final previousFirst = previousRecent!.first;
    final currentFirst = currentRecent!.first;
    final previousAnchor = currentRecent.indexOf(previousFirst);
    final currentAnchor = previousRecent.indexOf(currentFirst);
    final ContentChange result;
    final JudgmentReason reason;
    if (currentFirst == previousFirst) {
      result = ContentChange.unchanged;
      reason = JudgmentReason.sameFirst;
    } else if (previousAnchor > 0) {
      result = ContentChange.changed;
      reason = JudgmentReason.newerAnchor;
    } else {
      result = ContentChange.rebaseline;
      reason = currentAnchor > 0
          ? JudgmentReason.regressed
          : JudgmentReason.noSafeAnchor;
    }
    return _decision(
      result,
      EvidenceType.recentChapterIds,
      reason,
      previousRecent,
      currentRecent,
      lowerEvidenceDisagrees: _lowerEvidenceDisagrees(
        previousState!,
        currentState!,
        selected: EvidenceType.recentChapterIds,
      ),
    );
  }

  // Both sides carry content evidence but share no field.
  //
  // The conclusion is `unknown`, not `rebaseline`: advancing the fact here
  // would let alternating field sets swallow a real change forever
  // (research R-02 / Contract J4).
  return const ComparisonDecision(
    contentChange: ContentChange.unknown,
    selectedEvidence: null,
    reason: JudgmentReason.noCommonEvidence,
  );
}

ComparisonDecision _decision(
  ContentChange contentChange,
  EvidenceType evidence,
  JudgmentReason reason,
  Object previousValue,
  Object currentValue, {
  required bool lowerEvidenceDisagrees,
}) => ComparisonDecision(
  contentChange: contentChange,
  selectedEvidence: evidence,
  reason: lowerEvidenceDisagrees ? JudgmentReason.priority : reason,
  previousValue: previousValue,
  currentValue: currentValue,
);

bool _lowerEvidenceDisagrees(
  UpdateState previous,
  UpdateState current, {
  required EvidenceType selected,
}) {
  final selectedIndex = EvidenceType.values.indexOf(selected);
  for (
    var index = selectedIndex + 1;
    index < EvidenceType.values.length;
    index++
  ) {
    final evidence = EvidenceType.values[index];
    switch (evidence) {
      case EvidenceType.updatedAt:
        if (previous.updatedAt != null &&
            current.updatedAt != null &&
            previous.updatedAt != current.updatedAt) {
          return true;
        }
      case EvidenceType.latestChapterId:
        if (previous.latestChapterId != null &&
            current.latestChapterId != null &&
            previous.latestChapterId != current.latestChapterId) {
          return true;
        }
      case EvidenceType.chapterCount:
        if (previous.chapterCount != null &&
            current.chapterCount != null &&
            previous.chapterCount != current.chapterCount) {
          return true;
        }
      case EvidenceType.recentChapterIds:
        if (previous.recentChapterIds?.isNotEmpty == true &&
            current.recentChapterIds?.isNotEmpty == true &&
            previous.recentChapterIds!.first !=
                current.recentChapterIds!.first) {
          return true;
        }
    }
  }
  return false;
}
