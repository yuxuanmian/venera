import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tracking/comparability.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';

import 'fakes.dart';

/// The two declarations a `primary` switch would plausibly produce.
final String labelComicBranch = ComparableLabel.of(const {
  'updatedAt': 'updated_at@instant',
});
final String labelCollectionBranch = ComparableLabel.of(const {
  'latestChapterId': 'last_chapter.id',
  'sourceUnread': 'is_new|full_is_new',
});

void main() {
  group('SC-004: a label change rebuilds the baseline and reports no update', () {
    test('the engine reports labelChanged, not noPreviousEvidence', () {
      final outcome = decide(
        previousFactJson: const ObservationSpec(
          latestChapterId: 'chapter-41',
        ).json,
        recordedLabel: labelCollectionBranch,
        currentObservationJson: const ObservationSpec(
          updatedAt: '2026-09-02',
        ).json,
        currentLabel: labelComicBranch,
        currentObservedAtMs: 1789036800000,
        decidedAtMs: 1789041600000,
        previousHasNewUpdate: false,
        previousNoCommonStreak: 0,
      );

      expect(outcome.conclusion, JudgmentConclusion.rebaseline);
      expect(outcome.reason, JudgmentReason.labelChanged);
      expect(outcome.reason, isNot(JudgmentReason.noPreviousEvidence));
      // The fact is replaced and the recorded label moves with it.
      expect(outcome.factAdvanced, isTrue);
      expect(outcome.factJson, contains('2026-09-02'));
      expect(outcome.evidenceSchema, labelComicBranch);
      // A rebuild is not an update.
      expect(outcome.hasNewUpdate, isFalse);
      expect(outcome.noCommonStreak, 0);
    });

    test('the service records no update across a full branch switch', () async {
      final judgment = InMemoryJudgmentRepository();
      final scans = InMemoryScanItemStore(
        items: [
          const ObservationSpec(latestChapterId: 'chapter-41').toStoredItem(
            sourceKey: 'src',
            comicId: 'comic-1',
            evidenceSchema: labelCollectionBranch,
          ),
        ],
      );
      final service = JudgmentService(
        repository: judgment,
        scanRepository: scans,
        clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
      );

      await service.run();
      final first = await judgment.readFor('src', 'comic-1');
      expect(first!.lastReason, JudgmentReason.noPreviousEvidence);
      expect(first.evidenceSchema, labelCollectionBranch);

      // The maintainer switches `primary`: a new observation arrives carrying
      // the other branch's label.
      scans.replace(
        const ObservationSpec(updatedAt: '2026-09-02').toStoredItem(
          sourceKey: 'src',
          comicId: 'comic-1',
          attemptId: 'attempt-branch-2',
          evidenceSchema: labelComicBranch,
        ),
      );

      final summary = await service.run();
      expect(summary.changed, 0, reason: 'a label change is not an update');
      final after = await judgment.readFor('src', 'comic-1');
      expect(after!.lastDecision, JudgmentConclusion.rebaseline);
      expect(after.lastReason, JudgmentReason.labelChanged);
      expect(after.evidenceSchema, labelComicBranch);
      expect(after.factJson, contains('2026-09-02'));
      expect(after.hasNewUpdate, isFalse);
      expect(after.processedAttemptId, 'attempt-branch-2');
    });

    test('identical branch declarations compare normally', () {
      // Two branches declaring the same mapping produce one label, so no
      // rebuild is triggered and comparison proceeds as usual.
      final shared = ComparableLabel.of(const {
        'latestChapterId': 'last_chapter.id',
      });
      expect(
        ComparableLabel.of(const {'latestChapterId': 'last_chapter.id'}),
        shared,
      );

      final outcome = decide(
        previousFactJson: const ObservationSpec(
          latestChapterId: 'chapter-41',
        ).json,
        recordedLabel: shared,
        currentObservationJson: const ObservationSpec(
          latestChapterId: 'chapter-42',
        ).json,
        currentLabel: shared,
        currentObservedAtMs: 1789036800000,
        decidedAtMs: 1789041600000,
        previousHasNewUpdate: false,
        previousNoCommonStreak: 0,
      );
      expect(outcome.conclusion, JudgmentConclusion.changed);
      expect(outcome.reason, JudgmentReason.different);
      expect(outcome.selectedEvidence, JudgmentEvidence.latestChapterId);
    });

    test('first judgment reports noPreviousEvidence, not labelChanged', () {
      final outcome = decide(
        previousFactJson: null,
        recordedLabel: null,
        currentObservationJson: const ObservationSpec(
          latestChapterId: 'chapter-1',
        ).json,
        currentLabel: labelComicBranch,
        currentObservedAtMs: 1789036800000,
        decidedAtMs: 1789041600000,
        previousHasNewUpdate: false,
        previousNoCommonStreak: 0,
      );
      expect(outcome.reason, JudgmentReason.noPreviousEvidence);
      expect(outcome.reason, isNot(JudgmentReason.labelChanged));
    });

    test('a recorded label with no fact still reports noPreviousEvidence', () {
      // Should not happen in practice, but the engine must not confuse the two
      // situations when it does.
      final outcome = decide(
        previousFactJson: null,
        recordedLabel: labelComicBranch,
        currentObservationJson: const ObservationSpec(
          latestChapterId: 'chapter-1',
        ).json,
        currentLabel: labelComicBranch,
        currentObservedAtMs: 1789036800000,
        decidedAtMs: 1789041600000,
        previousHasNewUpdate: false,
        previousNoCommonStreak: 0,
      );
      expect(outcome.reason, JudgmentReason.noPreviousEvidence);
    });

    test(
      'a reverted label change rebuilds again rather than reporting',
      () async {
        final judgment = InMemoryJudgmentRepository();
        final scans = InMemoryScanItemStore(
          items: [
            const ObservationSpec(latestChapterId: 'chapter-41').toStoredItem(
              sourceKey: 'src',
              comicId: 'comic-1',
              evidenceSchema: labelCollectionBranch,
            ),
          ],
        );
        final service = JudgmentService(
          repository: judgment,
          scanRepository: scans,
          clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
        );

        await service.run();
        scans.replace(
          const ObservationSpec(updatedAt: '2026-09-02').toStoredItem(
            sourceKey: 'src',
            comicId: 'comic-1',
            attemptId: 'attempt-2',
            evidenceSchema: labelComicBranch,
          ),
        );
        await service.run();
        expect(
          (await judgment.readFor('src', 'comic-1'))!.lastReason,
          JudgmentReason.labelChanged,
        );

        // Switch back.
        scans.replace(
          const ObservationSpec(latestChapterId: 'chapter-42').toStoredItem(
            sourceKey: 'src',
            comicId: 'comic-1',
            attemptId: 'attempt-3',
            evidenceSchema: labelCollectionBranch,
          ),
        );
        final summary = await service.run();
        expect(summary.changed, 0);
        final after = await judgment.readFor('src', 'comic-1');
        expect(after!.lastReason, JudgmentReason.labelChanged);
        expect(after.evidenceSchema, labelCollectionBranch);
        expect(after.hasNewUpdate, isFalse);
      },
    );
  });

  group('an upgraded database rebuilds without a false update', () {
    test('a first run over pre-upgrade evidence reports zero updates', () async {
      // After the `scan_item_state.evidence_schema` migration, existing items
      // carry a NULL label.  `ComparableLabel.matches(null, current)` is false
      // by design, so the first post-upgrade run rebuilds every baseline.
      expect(ComparableLabel.matches(null, labelCollectionBranch), isFalse);

      final judgment = InMemoryJudgmentRepository();
      final scans = InMemoryScanItemStore(
        items: [
          const ObservationSpec(latestChapterId: 'chapter-42').toStoredItem(
            sourceKey: 'src',
            comicId: 'comic-1',
            attemptId: 'attempt-after-upgrade',
            // No label: this row predates the migration.
          ),
        ],
      );

      final summary = await JudgmentService(
        repository: judgment,
        scanRepository: scans,
        clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
      ).run();

      // Rebasing is not an update: no false red dots after an upgrade.
      expect(summary.changed, 0);
      expect(summary.writtenRows, 1);
      final after = await judgment.readFor('src', 'comic-1');
      expect(after!.lastDecision, JudgmentConclusion.rebaseline);
      // The first decision is still "never compared", because there was no
      // prior judgment state to carry the old fact.
      expect(after.lastReason, JudgmentReason.noPreviousEvidence);
      expect(after.hasNewUpdate, isFalse);
      // The empty label the scan carried is recorded as-is; the next run will
      // see it as a change and rebuild once more, which is still not an update.
      expect(after.evidenceSchema, '');

      scans.replace(
        const ObservationSpec(latestChapterId: 'chapter-43').toStoredItem(
          sourceKey: 'src',
          comicId: 'comic-1',
          attemptId: 'attempt-2',
          evidenceSchema: labelCollectionBranch,
        ),
      );
      final second = await JudgmentService(
        repository: judgment,
        scanRepository: scans,
        clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
      ).run();
      expect(second.changed, 0);
      expect(
        (await judgment.readFor('src', 'comic-1'))!.lastReason,
        JudgmentReason.labelChanged,
      );
    });
  });
}
