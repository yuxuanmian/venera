import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';

import 'fakes.dart';

JudgmentState seeded({
  required String sourceKey,
  required String comicId,
  bool hasNewUpdate = true,
}) => JudgmentState(
  sourceKey: sourceKey,
  comicId: comicId,
  factJson: '{"update":{"latestChapterId":"chapter-9"}}',
  factObservedAtMs: 1757000000000,
  evidenceSchema: labelA,
  lastDecision: JudgmentConclusion.changed,
  lastEvidence: JudgmentEvidence.latestChapterId,
  lastPreviousValue: 'chapter-8',
  lastCurrentValue: 'chapter-9',
  lastReason: JudgmentReason.different,
  decidedAtMs: 1758000000000,
  noCommonStreak: 4,
  hasNewUpdate: hasNewUpdate,
  processedAttemptId: 'attempt-9',
);

void main() {
  late InMemoryJudgmentRepository judgment;
  late JudgmentService service;

  setUp(() {
    judgment = InMemoryJudgmentRepository();
    service = JudgmentService(
      repository: judgment,
      scanRepository: InMemoryScanItemStore(),
      clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
    );
  });

  test(
    'FR-027: switching accounts clears only that source\'s visible flag',
    () async {
      judgment.rows['source-a\u0000comic-1'] = seeded(
        sourceKey: 'source-a',
        comicId: 'comic-1',
      );
      judgment.rows['source-a\u0000comic-2'] = seeded(
        sourceKey: 'source-a',
        comicId: 'comic-2',
      );
      judgment.rows['source-b\u0000comic-1'] = seeded(
        sourceKey: 'source-b',
        comicId: 'comic-1',
      );
      final beforeA1 = judgment.rows['source-a\u0000comic-1']!;
      final beforeB1 = judgment.rows['source-b\u0000comic-1']!;

      final affected = await service.clearUnreadForSource('source-a');

      expect(affected, 2);
      for (final comicId in const ['comic-1', 'comic-2']) {
        final after = judgment.rows['source-a\u0000$comicId']!;
        expect(after.hasNewUpdate, isFalse, reason: comicId);
        // Content facts and judgment result columns are account independent and
        // must be unchanged field by field.
        expect(after.factJson, beforeA1.factJson, reason: comicId);
        expect(
          after.factObservedAtMs,
          beforeA1.factObservedAtMs,
          reason: comicId,
        );
        expect(after.evidenceSchema, beforeA1.evidenceSchema, reason: comicId);
        expect(after.lastDecision, beforeA1.lastDecision, reason: comicId);
        expect(after.lastEvidence, beforeA1.lastEvidence, reason: comicId);
        expect(
          after.lastPreviousValue,
          beforeA1.lastPreviousValue,
          reason: comicId,
        );
        expect(
          after.lastCurrentValue,
          beforeA1.lastCurrentValue,
          reason: comicId,
        );
        expect(after.lastReason, beforeA1.lastReason, reason: comicId);
        expect(after.decidedAtMs, beforeA1.decidedAtMs, reason: comicId);
        expect(after.noCommonStreak, beforeA1.noCommonStreak, reason: comicId);
        expect(
          after.processedAttemptId,
          beforeA1.processedAttemptId,
          reason: comicId,
        );
      }

      // The other source is untouched, field for field.
      final afterB1 = judgment.rows['source-b\u0000comic-1']!;
      expect(afterB1.hasNewUpdate, isTrue);
      expect(afterB1.factJson, beforeB1.factJson);
      expect(afterB1.lastDecision, beforeB1.lastDecision);
      expect(afterB1.processedAttemptId, beforeB1.processedAttemptId);
    },
  );

  test('an unaffected source produces no write at all', () async {
    judgment.rows['source-a\u0000comic-1'] = seeded(
      sourceKey: 'source-a',
      comicId: 'comic-1',
      hasNewUpdate: true,
    );
    judgment.rows['source-b\u0000comic-1'] = seeded(
      sourceKey: 'source-b',
      comicId: 'comic-1',
      hasNewUpdate: true,
    );

    final before = judgment.applyBatchCalls;
    await service.clearUnreadForSource('source-a');
    // Exactly one batch was written, covering only source-a's row.
    expect(judgment.applyBatchCalls, before + 1);

    final afterCallCount = judgment.applyBatchCalls;
    // A second call for a source with nothing left to clear writes nothing.
    expect(await service.clearUnreadForSource('source-a'), 0);
    expect(judgment.applyBatchCalls, afterCallCount);
  });

  test('every comic of the source is cleared, not just flagged ones', () async {
    judgment.rows['source-a\u0000comic-1'] = seeded(
      sourceKey: 'source-a',
      comicId: 'comic-1',
      hasNewUpdate: false,
    );
    judgment.rows['source-a\u0000comic-2'] = seeded(
      sourceKey: 'source-a',
      comicId: 'comic-2',
      hasNewUpdate: true,
    );
    judgment.rows['source-a\u0000comic-3'] = seeded(
      sourceKey: 'source-a',
      comicId: 'comic-3',
      hasNewUpdate: true,
    );

    expect(await service.clearUnreadForSource('source-a'), 2);
    expect(
      judgment.rows.values
          .where((state) => state.sourceKey == 'source-a')
          .every((state) => !state.hasNewUpdate),
      isTrue,
    );
  });

  test('clearing an unknown source is a no-op', () async {
    judgment.rows['source-a\u0000comic-1'] = seeded(
      sourceKey: 'source-a',
      comicId: 'comic-1',
    );
    expect(await service.clearUnreadForSource('never-seen'), 0);
    expect(judgment.rows['source-a\u0000comic-1']!.hasNewUpdate, isTrue);
  });
}
