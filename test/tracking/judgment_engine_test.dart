import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tracking/comparability.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';

import 'fakes.dart';

/// A convenient call site: one previous observation, one current observation.
///
/// The default "now" is 2026-09-10T12:00Z, so the synthetic evidence below sits
/// inside the Contract J9 guard window instead of being dropped by it.
JudgmentOutcome decideFor({
  ObservationSpec? previous,
  ObservationSpec current = const ObservationSpec(),
  String? recordedLabel,
  String currentLabel = labelA,
  bool previousHasNewUpdate = false,
  int previousNoCommonStreak = 0,
  int decidedAtMs = 1789041600000,
  int currentObservedAtMs = 1789036800000,
}) => decide(
  previousFactJson: previous?.json,
  recordedLabel: previous == null ? null : (recordedLabel ?? labelA),
  currentObservationJson: current.json,
  currentLabel: currentLabel,
  currentObservedAtMs: currentObservedAtMs,
  decidedAtMs: decidedAtMs,
  previousHasNewUpdate: previousHasNewUpdate,
  previousNoCommonStreak: previousNoCommonStreak,
);

void main() {
  group('Contract J4 decision table, row by row', () {
    test('no usable evidence -> unknown / noUsableEvidence', () {
      final outcome = decideFor(
        previous: const ObservationSpec(latestChapterId: 'c-1'),
        current: const ObservationSpec(sourceUnread: true),
      );
      expect(outcome.conclusion, JudgmentConclusion.unknown);
      expect(outcome.reason, JudgmentReason.noUsableEvidence);
      expect(outcome.selectedEvidence, isNull);
      expect(outcome.factAdvanced, isFalse);
    });

    test('no previous fact -> rebaseline / noPreviousEvidence', () {
      final outcome = decideFor(
        current: const ObservationSpec(latestChapterId: 'c-1'),
      );
      expect(outcome.conclusion, JudgmentConclusion.rebaseline);
      expect(outcome.reason, JudgmentReason.noPreviousEvidence);
      expect(outcome.factAdvanced, isTrue);
      expect(outcome.factJson, contains('c-1'));
    });

    test('label mismatch -> rebaseline / labelChanged', () {
      final outcome = decideFor(
        previous: const ObservationSpec(latestChapterId: 'c-1'),
        current: const ObservationSpec(latestChapterId: 'c-2'),
        recordedLabel: labelA,
        currentLabel: labelB,
      );
      expect(outcome.conclusion, JudgmentConclusion.rebaseline);
      expect(outcome.reason, JudgmentReason.labelChanged);
      expect(outcome.factAdvanced, isTrue);
      expect(outcome.evidenceSchema, labelB);
    });

    test('labelChanged is distinct from noPreviousEvidence', () {
      final first = decideFor(
        current: const ObservationSpec(latestChapterId: 'c-1'),
      );
      final changed = decideFor(
        previous: const ObservationSpec(latestChapterId: 'c-1'),
        current: const ObservationSpec(latestChapterId: 'c-2'),
        recordedLabel: labelA,
        currentLabel: labelB,
      );
      expect(first.conclusion, changed.conclusion);
      expect(first.reason, isNot(changed.reason));
    });

    test('shared field, content ahead -> changed / later', () {
      final outcome = decideFor(
        previous: const ObservationSpec(updatedAt: '2026-09-01T00:00:00Z'),
        current: const ObservationSpec(updatedAt: '2026-09-02T00:00:00Z'),
      );
      expect(outcome.conclusion, JudgmentConclusion.changed);
      expect(outcome.reason, JudgmentReason.later);
      expect(outcome.selectedEvidence, JudgmentEvidence.updatedAt);
      expect(outcome.factAdvanced, isTrue);
    });

    test('shared field, content identical -> unchanged / equal', () {
      final outcome = decideFor(
        previous: const ObservationSpec(latestChapterId: 'c-1'),
        current: const ObservationSpec(latestChapterId: 'c-1'),
      );
      expect(outcome.conclusion, JudgmentConclusion.unchanged);
      expect(outcome.reason, JudgmentReason.equal);
      expect(outcome.selectedEvidence, JudgmentEvidence.latestChapterId);
    });

    test('shared field, content behind -> rebaseline / regressed', () {
      final outcome = decideFor(
        previous: const ObservationSpec(updatedAt: '2026-09-03T00:00:00Z'),
        current: const ObservationSpec(updatedAt: '2026-09-01T00:00:00Z'),
      );
      expect(outcome.conclusion, JudgmentConclusion.rebaseline);
      expect(outcome.reason, JudgmentReason.regressed);
      expect(outcome.factAdvanced, isTrue);
    });

    test('content evidence without a shared field -> unknown, fact held', () {
      final previous = const ObservationSpec(updatedAt: '2026-09-01T00:00:00Z');
      final outcome = decideFor(
        previous: previous,
        current: const ObservationSpec(chapterCount: 42),
      );
      expect(outcome.conclusion, JudgmentConclusion.unknown);
      expect(outcome.reason, JudgmentReason.noCommonEvidence);
      expect(outcome.selectedEvidence, isNull);
      // The fact is deliberately NOT advanced; advancing would let alternating
      // field sets swallow a real change forever.
      expect(outcome.factAdvanced, isFalse);
      expect(outcome.factJson, previous.json);
    });

    test('a failed item is not judged at all', () {
      // The engine never sees failures: the service skips them, so the
      // observable contract here is that no decision exists to make.
      final item = ObservationSpec.failureItem(
        sourceKey: 'src',
        comicId: 'comic',
      );
      expect(item.result.isSuccess, isFalse);
      expect(item.result.observation, isNull);
    });
  });

  group('evidence tier selection (Contract J2)', () {
    test('tier order is updatedAt before latestChapterId', () {
      final outcome = decideFor(
        previous: const ObservationSpec(
          updatedAt: '2026-09-01T00:00:00Z',
          latestChapterId: 'c-1',
        ),
        current: const ObservationSpec(
          updatedAt: '2026-09-01T00:00:00Z',
          latestChapterId: 'c-2',
        ),
      );
      expect(outcome.selectedEvidence, JudgmentEvidence.updatedAt);
      // The lower tier disagrees, so the reason records it but the conclusion
      // stands (Contract J7).
      expect(outcome.conclusion, JudgmentConclusion.unchanged);
      expect(outcome.reason, JudgmentReason.priority);
    });

    test('low-priority disagreement never overturns the conclusion', () {
      final outcome = decideFor(
        previous: const ObservationSpec(
          latestChapterId: 'c-1',
          chapterCount: 41,
        ),
        current: const ObservationSpec(
          latestChapterId: 'c-1',
          chapterCount: 42,
        ),
      );
      expect(outcome.selectedEvidence, JudgmentEvidence.latestChapterId);
      expect(outcome.conclusion, JudgmentConclusion.unchanged);
      expect(outcome.reason, JudgmentReason.priority);
    });

    test('marker is not an accepted tier', () {
      // A payload carrying only a marker-shaped key has no usable evidence.
      final outcome = decide(
        previousFactJson: jsonEncode({
          'update': {'marker': 'm-1'},
        }),
        recordedLabel: labelA,
        currentObservationJson: jsonEncode({
          'update': {'marker': 'm-2'},
        }),
        currentLabel: labelA,
        currentObservedAtMs: 1789036800000,
        decidedAtMs: 1789041600000,
        previousHasNewUpdate: false,
        previousNoCommonStreak: 0,
      );
      expect(outcome.conclusion, JudgmentConclusion.unknown);
      expect(outcome.reason, JudgmentReason.noUsableEvidence);
    });
  });

  group('invalid fields drop only themselves', () {
    test('an unusable updatedAt still leaves sibling fields comparable', () {
      final outcome = decideFor(
        previous: const ObservationSpec(
          updatedAt: '2026-09-01T00:00:00Z',
          latestChapterId: 'c-1',
        ),
        current: const ObservationSpec(
          updatedAt: 'not-a-timestamp',
          latestChapterId: 'c-2',
        ),
      );
      expect(outcome.selectedEvidence, JudgmentEvidence.latestChapterId);
      expect(outcome.conclusion, JudgmentConclusion.changed);
      expect(outcome.reason, JudgmentReason.different);
    });
  });

  group('continuity counter (Contract J8)', () {
    test('resets to zero whenever a common field exists', () {
      final outcome = decideFor(
        previous: const ObservationSpec(latestChapterId: 'c-1'),
        current: const ObservationSpec(latestChapterId: 'c-2'),
        previousNoCommonStreak: 7,
      );
      expect(outcome.noCommonStreak, 0);
    });

    test('increments on content evidence without a shared field', () {
      final outcome = decideFor(
        previous: const ObservationSpec(latestChapterId: 'c-1'),
        current: const ObservationSpec(chapterCount: 3),
        previousNoCommonStreak: 2,
      );
      expect(outcome.noCommonStreak, 3);
    });

    test('stays put when there is no usable evidence', () {
      final outcome = decideFor(
        previous: const ObservationSpec(latestChapterId: 'c-1'),
        current: const ObservationSpec(sourceUnread: false),
        previousNoCommonStreak: 4,
      );
      expect(outcome.noCommonStreak, 4);
    });
  });

  group('visible flag (Contract J6)', () {
    test('an explicit true signal always wins', () {
      final outcome = decideFor(
        previous: const ObservationSpec(latestChapterId: 'c-1'),
        current: const ObservationSpec(
          latestChapterId: 'c-1',
          sourceUnread: true,
        ),
        previousHasNewUpdate: false,
      );
      expect(outcome.conclusion, JudgmentConclusion.unchanged);
      expect(outcome.hasNewUpdate, isTrue);
    });

    test('an explicit false signal always wins', () {
      final outcome = decideFor(
        previous: const ObservationSpec(latestChapterId: 'c-1'),
        current: const ObservationSpec(
          latestChapterId: 'c-2',
          sourceUnread: false,
        ),
        previousHasNewUpdate: true,
      );
      expect(outcome.conclusion, JudgmentConclusion.changed);
      expect(outcome.hasNewUpdate, isFalse);
    });

    test('an unknown signal keeps the previous value except on changed', () {
      final unchanged = decideFor(
        previous: const ObservationSpec(latestChapterId: 'c-1'),
        current: const ObservationSpec(latestChapterId: 'c-1'),
        previousHasNewUpdate: true,
      );
      expect(unchanged.hasNewUpdate, isTrue);

      final changed = decideFor(
        previous: const ObservationSpec(latestChapterId: 'c-1'),
        current: const ObservationSpec(latestChapterId: 'c-2'),
        previousHasNewUpdate: false,
      );
      expect(changed.hasNewUpdate, isTrue);
    });

    test('rebaseline and unknown do not raise the flag on their own', () {
      final rebaseline = decideFor(
        current: const ObservationSpec(latestChapterId: 'c-1'),
        previousHasNewUpdate: false,
      );
      expect(rebaseline.hasNewUpdate, isFalse);

      final unknown = decideFor(
        previous: const ObservationSpec(latestChapterId: 'c-1'),
        current: const ObservationSpec(chapterCount: 2),
        previousHasNewUpdate: false,
      );
      expect(unknown.hasNewUpdate, isFalse);
    });
  });

  group('chapterCount zero is a value, not a missing field', () {
    test('zero compares as content evidence', () {
      final outcome = decideFor(
        previous: const ObservationSpec(chapterCount: 0),
        current: const ObservationSpec(chapterCount: 1),
      );
      expect(outcome.selectedEvidence, JudgmentEvidence.chapterCount);
      expect(outcome.conclusion, JudgmentConclusion.changed);
      expect(outcome.reason, JudgmentReason.increased);
      expect(outcome.previousValue, '0');
    });

    test('zero equals zero', () {
      final outcome = decideFor(
        previous: const ObservationSpec(chapterCount: 0),
        current: const ObservationSpec(chapterCount: 0),
      );
      expect(outcome.conclusion, JudgmentConclusion.unchanged);
      expect(outcome.reason, JudgmentReason.equal);
    });

    test('absent chapterCount is not the same as zero', () {
      final outcome = decideFor(
        previous: const ObservationSpec(chapterCount: 0),
        current: const ObservationSpec(latestChapterId: 'c-1'),
      );
      // No shared field at all: zero on one side does not pair with absence.
      expect(outcome.reason, JudgmentReason.noCommonEvidence);
    });
  });

  group('recentChapterIds tier', () {
    test('equal first entry -> sameFirst', () {
      final outcome = decideFor(
        previous: const ObservationSpec(recentChapterIds: ['c-3', 'c-2']),
        current: const ObservationSpec(recentChapterIds: ['c-3', 'c-1']),
      );
      expect(outcome.conclusion, JudgmentConclusion.unchanged);
      expect(outcome.reason, JudgmentReason.sameFirst);
    });

    test('the previous first entry moving later -> newerAnchor', () {
      final outcome = decideFor(
        previous: const ObservationSpec(recentChapterIds: ['c-3', 'c-2']),
        current: const ObservationSpec(recentChapterIds: ['c-4', 'c-3']),
      );
      expect(outcome.conclusion, JudgmentConclusion.changed);
      expect(outcome.reason, JudgmentReason.newerAnchor);
    });

    test('no safe anchor -> noSafeAnchor', () {
      final outcome = decideFor(
        previous: const ObservationSpec(recentChapterIds: ['c-3', 'c-2']),
        current: const ObservationSpec(recentChapterIds: ['c-1', 'c-0']),
      );
      expect(outcome.conclusion, JudgmentConclusion.rebaseline);
      expect(outcome.reason, JudgmentReason.noSafeAnchor);
    });
  });

  group('decision is a pure function of its inputs', () {
    test('the same inputs always produce the same outcome', () {
      final first = decideFor(
        previous: const ObservationSpec(latestChapterId: 'c-1'),
        current: const ObservationSpec(latestChapterId: 'c-2'),
      );
      final second = decideFor(
        previous: const ObservationSpec(latestChapterId: 'c-1'),
        current: const ObservationSpec(latestChapterId: 'c-2'),
      );
      expect(first.conclusion, second.conclusion);
      expect(first.reason, second.reason);
      expect(first.factJson, second.factJson);
      expect(first.hasNewUpdate, second.hasNewUpdate);
    });

    test('labels compare through ComparableLabel, not raw equality', () {
      final label = ComparableLabel.of(const {
        'latestChapterId': 'last_chapter.id',
      });
      final outcome = decideFor(
        previous: const ObservationSpec(latestChapterId: 'c-1'),
        current: const ObservationSpec(latestChapterId: 'c-1'),
        recordedLabel: label,
        currentLabel: label,
      );
      expect(outcome.reason, JudgmentReason.equal);
    });
  });
}
