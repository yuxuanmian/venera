import 'update_state.dart';

enum ContentChange { changed, unchanged, rebaseline, unknown }

enum EvidenceType {
  updatedAt,
  latestChapterId,
  chapterCount,
  recentChapterIds,
  marker,
}

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
  final String reason;
  final Object? previousValue;
  final Object? currentValue;
}

/// Compares only the strongest evidence available in both baselines.
ComparisonDecision compareTrackingEvidence({
  required UpdateState? previousState,
  required String? previousMarker,
  required UpdateState? currentState,
  required String? currentMarker,
}) {
  final usableCurrentState = currentState?.isUsable == true;
  final usablePreviousState = previousState?.isUsable == true;
  final usableCurrentMarker = _usableMarker(currentMarker);
  final usablePreviousMarker = _usableMarker(previousMarker);

  if (!usableCurrentState && !usableCurrentMarker) {
    return const ComparisonDecision(
      contentChange: ContentChange.unknown,
      selectedEvidence: null,
      reason: 'noUsableEvidence',
    );
  }
  if (!usablePreviousState && !usablePreviousMarker) {
    return const ComparisonDecision(
      contentChange: ContentChange.rebaseline,
      selectedEvidence: null,
      reason: 'noPreviousEvidence',
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
          ? 'later'
          : result == ContentChange.rebaseline
          ? 'regressed'
          : 'equal',
      previous,
      current,
      lowerEvidenceDisagrees: _lowerEvidenceDisagrees(
        previousState,
        currentState,
        selected: EvidenceType.updatedAt,
        previousMarker: previousMarker,
        currentMarker: currentMarker,
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
      previous == current ? 'equal' : 'different',
      previous,
      current,
      lowerEvidenceDisagrees: _lowerEvidenceDisagrees(
        previousState,
        currentState,
        selected: EvidenceType.latestChapterId,
        previousMarker: previousMarker,
        currentMarker: currentMarker,
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
          ? 'increased'
          : result == ContentChange.rebaseline
          ? 'decreased'
          : 'equal',
      previous,
      current,
      lowerEvidenceDisagrees: _lowerEvidenceDisagrees(
        previousState,
        currentState,
        selected: EvidenceType.chapterCount,
        previousMarker: previousMarker,
        currentMarker: currentMarker,
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
    final String reason;
    if (currentFirst == previousFirst) {
      result = ContentChange.unchanged;
      reason = 'sameFirst';
    } else if (previousAnchor > 0) {
      result = ContentChange.changed;
      reason = 'newerAnchor';
    } else {
      result = ContentChange.rebaseline;
      reason = currentAnchor > 0 ? 'regressed' : 'noSafeAnchor';
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
        previousMarker: previousMarker,
        currentMarker: currentMarker,
      ),
    );
  }

  if (usablePreviousMarker && usableCurrentMarker) {
    final same = previousMarker == currentMarker;
    return ComparisonDecision(
      contentChange: same ? ContentChange.unchanged : ContentChange.changed,
      selectedEvidence: EvidenceType.marker,
      reason: same ? 'equal' : 'different',
      previousValue: previousMarker,
      currentValue: currentMarker,
    );
  }

  return const ComparisonDecision(
    contentChange: ContentChange.rebaseline,
    selectedEvidence: null,
    reason: 'noCommonEvidence',
  );
}

ComparisonDecision _decision(
  ContentChange contentChange,
  EvidenceType evidence,
  String reason,
  Object previousValue,
  Object currentValue, {
  required bool lowerEvidenceDisagrees,
}) => ComparisonDecision(
  contentChange: contentChange,
  selectedEvidence: evidence,
  reason: lowerEvidenceDisagrees ? 'priority' : reason,
  previousValue: previousValue,
  currentValue: currentValue,
);

bool _usableMarker(String? value) => value != null && value.trim().isNotEmpty;

bool _lowerEvidenceDisagrees(
  UpdateState previous,
  UpdateState current, {
  required EvidenceType selected,
  required String? previousMarker,
  required String? currentMarker,
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
      case EvidenceType.marker:
        if (_usableMarker(previousMarker) &&
            _usableMarker(currentMarker) &&
            previousMarker != currentMarker) {
          return true;
        }
    }
  }
  return false;
}
