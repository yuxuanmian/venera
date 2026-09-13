import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_repository.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';

import 'fakes.dart';

JudgmentService serviceFor(
  InMemoryJudgmentRepository judgment,
  InMemoryScanItemStore scans, {
  FixedClock? clock,
  Future<void> Function()? cancelInFlightScan,
}) => JudgmentService(
  repository: judgment,
  scanRepository: scans,
  clock: (clock ?? FixedClock(DateTime.utc(2026, 9, 10, 12))).call,
  cancelInFlightScan: cancelInFlightScan,
);

void main() {
  group('read phase', () {
    test('nothing pending writes zero rows', () async {
      final judgment = InMemoryJudgmentRepository();
      final scans = InMemoryScanItemStore();
      final summary = await serviceFor(judgment, scans).run();

      expect(summary.writtenRows, 0);
      expect(summary.processed, 0);
      expect(summary.isEmptyRun, isTrue);
      expect(judgment.rows, isEmpty);
    });

    test('a first observation establishes a baseline', () async {
      final judgment = InMemoryJudgmentRepository();
      final scans = InMemoryScanItemStore(
        items: [
          const ObservationSpec(latestChapterId: 'c-1').toStoredItem(
            sourceKey: 'src',
            comicId: 'comic-1',
            evidenceSchema: labelA,
          ),
        ],
      );

      final summary = await serviceFor(judgment, scans).run();
      expect(summary.processed, 1);
      expect(summary.writtenRows, 1);

      final state = await judgment.readFor('src', 'comic-1');
      expect(state!.lastDecision, JudgmentConclusion.rebaseline);
      expect(state.lastReason, JudgmentReason.noPreviousEvidence);
      expect(state.evidenceSchema, labelA);
      expect(state.processedAttemptId, 'src\u0000comic-1\u00000');
    });

    test('failure items produce no state change at all', () async {
      final judgment = InMemoryJudgmentRepository();
      final scans = InMemoryScanItemStore(
        items: [
          ObservationSpec.failureItem(sourceKey: 'src', comicId: 'comic-1'),
        ],
      );

      final summary = await serviceFor(judgment, scans).run();
      expect(summary.failed, 1);
      expect(summary.processed, 0);
      expect(summary.writtenRows, 0);
      expect(judgment.rows, isEmpty);
    });
  });

  group('idempotency (SC-002 / SC-005)', () {
    test('the same observation processed twice writes exactly once', () async {
      final judgment = InMemoryJudgmentRepository();
      final scans = InMemoryScanItemStore(
        items: [
          const ObservationSpec(latestChapterId: 'c-1').toStoredItem(
            sourceKey: 'src',
            comicId: 'comic-1',
            evidenceSchema: labelA,
          ),
        ],
      );
      final service = serviceFor(judgment, scans);

      final first = await service.run();
      expect(first.writtenRows, 1);
      final afterFirst = await judgment.readFor('src', 'comic-1');

      final second = await service.run();
      expect(second.writtenRows, 0);
      expect(second.processed, 0);
      final afterSecond = await judgment.readFor('src', 'comic-1');
      expect(afterSecond!.lastDecision, afterFirst!.lastDecision);
      expect(afterSecond.lastReason, afterFirst.lastReason);
      expect(afterSecond.decidedAtMs, afterFirst.decidedAtMs);
      expect(afterSecond.processedAttemptId, afterFirst.processedAttemptId);
    });

    test(
      '100 repeated runs keep the record count and row writes at zero',
      () async {
        final judgment = InMemoryJudgmentRepository();
        const identityCount = 700;
        final scans = InMemoryScanItemStore(
          items: [
            for (var index = 0; index < identityCount; index++)
              ObservationSpec(latestChapterId: 'chapter-$index').toStoredItem(
                sourceKey: 'src',
                comicId: 'comic-$index',
                evidenceSchema: labelA,
              ),
          ],
        );
        final service = serviceFor(judgment, scans);

        final first = await service.run();
        expect(first.writtenRows, identityCount);
        expect(judgment.rows.length, identityCount);

        for (var round = 0; round < 100; round++) {
          final summary = await service.run();
          expect(summary.writtenRows, 0, reason: 'round $round');
        }
        expect(judgment.rows.length, identityCount);
      },
    );

    test('the continuity counter follows observations, not runs', () async {
      final judgment = InMemoryJudgmentRepository();
      // A fact exists, and the stored observation has no field in common.
      judgment.rows['src\u0000comic-1'] = JudgmentState(
        sourceKey: 'src',
        comicId: 'comic-1',
        factJson: '{"update":{"updatedAt":"2026-09-01T00:00:00Z"}}',
        factObservedAtMs: 1789036800000,
        evidenceSchema: labelA,
        lastDecision: JudgmentConclusion.rebaseline,
        lastReason: JudgmentReason.noPreviousEvidence,
        decidedAtMs: 1789041600000,
      );
      final scans = InMemoryScanItemStore(
        items: [
          const ObservationSpec(chapterCount: 42).toStoredItem(
            sourceKey: 'src',
            comicId: 'comic-1',
            evidenceSchema: labelA,
          ),
        ],
      );
      final service = serviceFor(judgment, scans);

      await service.run();
      var state = await judgment.readFor('src', 'comic-1');
      expect(state!.noCommonStreak, 1);
      expect(state.lastReason, JudgmentReason.noCommonEvidence);

      // Re-running without a new observation must not advance the streak.
      for (var round = 0; round < 5; round++) {
        await service.run();
      }
      state = await judgment.readFor('src', 'comic-1');
      expect(state!.noCommonStreak, 1);
    });
  });

  group('re-entry (FR-042)', () {
    test('a concurrent run is rejected rather than queued', () async {
      final judgment = InMemoryJudgmentRepository();
      final scans = InMemoryScanItemStore(
        items: [
          const ObservationSpec(
            latestChapterId: 'c-1',
          ).toStoredItem(sourceKey: 'src', comicId: 'comic-1'),
        ],
      );
      final service = serviceFor(judgment, scans);

      final futures = [service.run(), service.run(), service.run()];
      final results = await Future.wait(futures);
      final rejected = results.where((r) => r.rejectedAsRunning).length;
      expect(rejected, 2);
      expect(results.where((r) => !r.rejectedAsRunning).single.writtenRows, 1);
    });

    test('the running flag is exposed while a run is in flight', () async {
      final judgment = InMemoryJudgmentRepository();
      final scans = InMemoryScanItemStore();
      final service = serviceFor(judgment, scans);
      expect(service.isRunning, isFalse);
      await service.run();
      expect(service.isRunning, isFalse);
    });
  });

  group('snapshot verification before write (FR-023)', () {
    test(
      'an identity replaced mid-run is skipped and handled next time',
      () async {
        final judgment = InMemoryJudgmentRepository();
        final original = const ObservationSpec(latestChapterId: 'c-1')
            .toStoredItem(
              sourceKey: 'src',
              comicId: 'comic-1',
              attemptId: 'attempt-1',
              evidenceSchema: labelA,
            );
        final replacement = const ObservationSpec(latestChapterId: 'c-2')
            .toStoredItem(
              sourceKey: 'src',
              comicId: 'comic-1',
              attemptId: 'attempt-2',
              evidenceSchema: labelA,
            );
        final scans = InMemoryScanItemStore(items: [original]);
        // Land the replacement immediately after the read phase freezes its
        // snapshot and before the write phase re-checks the identity.
        scans.onAfterReadAllItems = () => scans.replace(replacement);

        final service = JudgmentService(
          repository: judgment,
          scanRepository: scans,
          clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
        );

        final first = await service.run();
        // The frozen snapshot still points at attempt-1, so this run refuses to
        // absorb the replacement it never read.
        expect(first.skippedStale, 1);
        expect(first.writtenRows, 0);
        expect(judgment.rows, isEmpty);

        scans.onAfterReadAllItems = null;
        final second = await service.run();
        expect(second.writtenRows, 1);
        final state = await judgment.readFor('src', 'comic-1');
        expect(state!.processedAttemptId, 'attempt-2');
        expect(state.factJson, contains('c-2'));
      },
    );
  });

  group('clearUnreadForSource (FR-027)', () {
    test('only the visible flag moves', () async {
      final judgment = InMemoryJudgmentRepository();
      judgment.rows['src-a\u0000comic-1'] = _seededState(
        sourceKey: 'src-a',
        comicId: 'comic-1',
        hasNewUpdate: true,
      );
      judgment.rows['src-a\u0000comic-2'] = _seededState(
        sourceKey: 'src-a',
        comicId: 'comic-2',
        hasNewUpdate: true,
      );
      judgment.rows['src-b\u0000comic-1'] = _seededState(
        sourceKey: 'src-b',
        comicId: 'comic-1',
        hasNewUpdate: true,
      );
      final before = judgment.rows['src-a\u0000comic-1']!;

      final affected = await serviceFor(
        judgment,
        InMemoryScanItemStore(),
      ).clearUnreadForSource('src-a');

      expect(affected, 2);
      final after = judgment.rows['src-a\u0000comic-1']!;
      expect(after.hasNewUpdate, isFalse);
      // Content facts and decision columns are account independent.
      expect(after.factJson, before.factJson);
      expect(after.factObservedAtMs, before.factObservedAtMs);
      expect(after.evidenceSchema, before.evidenceSchema);
      expect(after.lastDecision, before.lastDecision);
      expect(after.lastEvidence, before.lastEvidence);
      expect(after.lastPreviousValue, before.lastPreviousValue);
      expect(after.lastCurrentValue, before.lastCurrentValue);
      expect(after.lastReason, before.lastReason);
      expect(after.decidedAtMs, before.decidedAtMs);
      expect(after.noCommonStreak, before.noCommonStreak);
      expect(after.processedAttemptId, before.processedAttemptId);
      // Another source is untouched.
      expect(judgment.rows['src-b\u0000comic-1']!.hasNewUpdate, isTrue);
    });

    test('a source with no flagged comics writes nothing', () async {
      final judgment = InMemoryJudgmentRepository();
      judgment.rows['src-a\u0000comic-1'] = _seededState(
        sourceKey: 'src-a',
        comicId: 'comic-1',
        hasNewUpdate: false,
      );
      final before = judgment.applyBatchCalls;

      expect(
        await serviceFor(
          judgment,
          InMemoryScanItemStore(),
        ).clearUnreadForSource('src-a'),
        0,
      );
      expect(judgment.applyBatchCalls, before);
    });
  });

  group('clear (Contract U4.1)', () {
    test('cancels an in-flight scan before emptying the state', () async {
      final order = <String>[];
      final judgment = _OrderedJudgmentRepository(order);
      judgment.rows['src\u0000comic-1'] = _seededState(
        sourceKey: 'src',
        comicId: 'comic-1',
      );
      final service = serviceFor(
        judgment,
        InMemoryScanItemStore(),
        cancelInFlightScan: () async => order.add('cancel'),
      );

      await service.clear();

      expect(order, ['cancel', 'clear']);
      expect(judgment.rows, isEmpty);
    });
  });

  group('storage failures', () {
    test('a failed batch surfaces as a judgment storage error', () async {
      final judgment = InMemoryJudgmentRepository()
        ..failNextBatch = StateError('disk full');
      final scans = InMemoryScanItemStore(
        items: [
          const ObservationSpec(
            latestChapterId: 'c-1',
          ).toStoredItem(sourceKey: 'src', comicId: 'comic-1'),
        ],
      );

      await expectLater(
        serviceFor(judgment, scans).run(),
        throwsA(isA<JudgmentStorageException>()),
      );
      expect(judgment.rows, isEmpty);
    });
  });
}

JudgmentState _seededState({
  required String sourceKey,
  required String comicId,
  bool hasNewUpdate = false,
}) => JudgmentState(
  sourceKey: sourceKey,
  comicId: comicId,
  factJson: '{"update":{"latestChapterId":"chapter-1"}}',
  factObservedAtMs: 1757000000000,
  evidenceSchema: labelA,
  lastDecision: JudgmentConclusion.changed,
  lastEvidence: JudgmentEvidence.latestChapterId,
  lastPreviousValue: 'chapter-0',
  lastCurrentValue: 'chapter-1',
  lastReason: JudgmentReason.different,
  decidedAtMs: 1758000000000,
  noCommonStreak: 2,
  hasNewUpdate: hasNewUpdate,
  processedAttemptId: 'attempt-1',
);

/// Records the order of cancellation and clearing.
class _OrderedJudgmentRepository extends InMemoryJudgmentRepository {
  _OrderedJudgmentRepository(this.order) : super(initial: null);

  final List<String> order;

  @override
  Future<void> clear() {
    order.add('clear');
    return super.clear();
  }
}
