import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';

import '../tracking/fakes.dart';

/// Contract: `specs/006-local-follow-up-loop/contracts/judgment-event-v1.md` E5
/// — incremental consumption MUST NOT change any judgment semantics.
///
/// The point of this file is *negative*: it asserts that the things incremental
/// consumption could plausibly have disturbed are untouched.  005's own suite in
/// `test/tracking/` guards the same ground from the other direction, and it is
/// deliberately not modified.
void main() {
  const sourceKey = 'src';
  late InMemoryJudgmentRepository repository;
  late InMemoryScanItemStore scans;
  late JudgmentService service;

  setUp(() {
    repository = InMemoryJudgmentRepository();
    scans = InMemoryScanItemStore();
    service = JudgmentService(
      repository: repository,
      scanRepository: scans,
      clock: () => DateTime.utc(2026, 9, 10, 12),
    );
  });

  void observe(String comicId, {required ObservationSpec spec}) {
    scans.replace(spec.toStoredItem(sourceKey: sourceKey, comicId: comicId));
  }

  group('first observation produces a baseline, never a false update', () {
    test('a newly favorited comic is not reported as updated', () async {
      // The comic was never seen before, so this is its first observation.  The
      // judgment is `rebaseline` / `noPreviousEvidence` and the visible flag
      // stays down — "first seen" is not "changed" (US3).
      observe('new', spec: const ObservationSpec(latestChapterId: 'chapter-1'));
      await service.run();

      final state = (await repository.readSnapshot())['src\u0000new']!;
      expect(state.lastDecision, JudgmentConclusion.rebaseline);
      expect(state.lastReason, JudgmentReason.noPreviousEvidence);
      expect(state.hasNewUpdate, isFalse);
      expect(state.factJson, isNotNull);
      expect(state.factObservedAtMs, isNotNull);
    });

    test(
      'the baseline exists, so the next check compares instead of rebuilding',
      () async {
        final first = const ObservationSpec(latestChapterId: 'chapter-1');
        observe('a', spec: first);
        await service.run();

        // The same observation again is skipped as already processed.
        final second = await service.run();
        expect(second.writtenRows, 0);

        // A genuinely newer observation is compared against the stored fact and
        // *is* reported, which proves a baseline was kept rather than rebuilt.
        scans.replace(
          const ObservationSpec(latestChapterId: 'chapter-2').toStoredItem(
            sourceKey: sourceKey,
            comicId: 'a',
            attemptId: 'attempt-2',
          ),
        );
        await service.run();

        final state = (await repository.readSnapshot())['src\u0000a']!;
        expect(state.lastDecision, JudgmentConclusion.changed);
        expect(state.lastReason, JudgmentReason.different);
        expect(state.hasNewUpdate, isTrue);
        expect(state.lastPreviousValue, 'chapter-1');
        expect(state.lastCurrentValue, 'chapter-2');
      },
    );

    test('the flag is sticky across an unchanged observation', () async {
      // Raise it, then observe the same thing again: the flag must survive.
      observe('a', spec: const ObservationSpec(latestChapterId: 'c1'));
      await service.run();
      final baseline = (await repository.readSnapshot())['src\u0000a']!;
      await repository.applyBatch([baseline.copyWith(hasNewUpdate: true)]);

      scans.replace(
        const ObservationSpec(latestChapterId: 'c2').toStoredItem(
          sourceKey: sourceKey,
          comicId: 'a',
          attemptId: 'attempt-2',
        ),
      );
      await service.run();
      expect(
        (await repository.readSnapshot())['src\u0000a']!.hasNewUpdate,
        isTrue,
      );

      scans.replace(
        const ObservationSpec(latestChapterId: 'c2').toStoredItem(
          sourceKey: sourceKey,
          comicId: 'a',
          attemptId: 'attempt-3',
        ),
      );
      await service.run();
      expect(
        (await repository.readSnapshot())['src\u0000a']!.hasNewUpdate,
        isTrue,
        reason: 'an unchanged observation must not clear the flag',
      );
    });
  });

  group('the skip condition still has both halves (E5)', () {
    test(
      'the same observation is skipped once processed by current rules',
      () async {
        observe('a', spec: const ObservationSpec(latestChapterId: 'c1'));
        expect((await service.run()).writtenRows, 1);
        expect((await service.run()).writtenRows, 0);
      },
    );

    test('a row from a different rule version is recomputed', () async {
      observe('a', spec: const ObservationSpec(latestChapterId: 'c1'));
      await service.run();
      final state = (await repository.readSnapshot())['src\u0000a']!;
      // Simulate a row written by older rules on the same observation.
      await repository.applyBatch([
        JudgmentState(
          sourceKey: state.sourceKey,
          comicId: state.comicId,
          factJson: state.factJson,
          factObservedAtMs: state.factObservedAtMs,
          evidenceSchema: state.evidenceSchema,
          lastDecision: state.lastDecision,
          lastEvidence: state.lastEvidence,
          lastPreviousValue: state.lastPreviousValue,
          lastCurrentValue: state.lastCurrentValue,
          lastReason: state.lastReason,
          decidedAtMs: state.decidedAtMs,
          noCommonStreak: state.noCommonStreak,
          hasNewUpdate: state.hasNewUpdate,
          processedAttemptId: state.processedAttemptId,
          algorithmVersion: judgmentAlgorithmVersion - 1,
        ),
      ]);

      expect(
        (await service.run()).writtenRows,
        1,
        reason:
            'a decision produced by rules that no longer apply cannot be '
            'trusted, even though its observation is unchanged',
      );
    });
  });

  group('column ownership is untouched by incremental consumption (E5)', () {
    test('the repository still owns exactly its declared columns', () {
      expect(SqliteJudgmentRepository.ownedColumns, hasLength(13));
      expect(SqliteJudgmentRepository.ownedColumns, contains('has_new_update'));
      expect(
        SqliteJudgmentRepository.ownedColumns,
        contains('algorithm_version'),
      );
    });

    test('the reason vocabulary is still exactly its 14 values', () {
      expect(JudgmentReason.values, hasLength(14));
      expect(JudgmentConclusion.values, hasLength(4));
      expect(JudgmentEvidence.values, hasLength(4));
    });

    test('the visible flag still lets an explicit source signal win', () async {
      // `sourceUnread == false` clears the flag no matter the conclusion.
      observe('a', spec: const ObservationSpec(latestChapterId: 'c1'));
      await service.run();
      final baseline = (await repository.readSnapshot())['src\u0000a']!;
      await repository.applyBatch([baseline.copyWith(hasNewUpdate: true)]);

      scans.replace(
        const ObservationSpec(
          latestChapterId: 'c1',
          sourceUnread: false,
        ).toStoredItem(
          sourceKey: sourceKey,
          comicId: 'a',
          attemptId: 'attempt-2',
        ),
      );
      await service.run();
      expect(
        (await repository.readSnapshot())['src\u0000a']!.hasNewUpdate,
        isFalse,
      );
    });
  });
}
