import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';

import 'fakes.dart';

void main() {
  group('SC-002: repeated runs write nothing and change nothing', () {
    test(
      '100 consecutive runs over fixed evidence leave state byte-identical',
      () async {
        final judgment = InMemoryJudgmentRepository();
        final scans = InMemoryScanItemStore(
          items: [
            const ObservationSpec(latestChapterId: 'chapter-1').toStoredItem(
              sourceKey: 'src',
              comicId: 'comic-1',
              evidenceSchema: labelA,
            ),
            const ObservationSpec(
              updatedAt: '2026-09-01T00:00:00Z',
            ).toStoredItem(
              sourceKey: 'src',
              comicId: 'comic-2',
              evidenceSchema: labelB,
            ),
          ],
        );
        final service = JudgmentService(
          repository: judgment,
          scanRepository: scans,
          clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
        );

        await service.run();
        final baseline = Map<String, JudgmentState>.from(judgment.rows);
        expect(baseline, hasLength(2));

        for (var round = 0; round < 100; round++) {
          final summary = await service.run();
          expect(summary.writtenRows, 0, reason: 'round $round');
        }

        expect(judgment.rows.length, baseline.length);
        for (final identity in baseline.keys) {
          final before = baseline[identity]!;
          final after = judgment.rows[identity]!;
          _expectSameState(after, before, identity);
        }
      },
    );
  });

  group('SC-005: an interrupted run leaves the previous state intact', () {
    test('a mid-batch failure rolls judgement state back', () async {
      final judgment = InMemoryJudgmentRepository();
      final scans = InMemoryScanItemStore(
        items: [
          const ObservationSpec(latestChapterId: 'chapter-1').toStoredItem(
            sourceKey: 'src',
            comicId: 'comic-1',
            evidenceSchema: labelA,
          ),
        ],
      );
      final service = JudgmentService(
        repository: judgment,
        scanRepository: scans,
        clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
      );

      await service.run();
      final before = await judgment.readFor('src', 'comic-1');

      // A new observation arrives, and the write fails.
      scans.replace(
        const ObservationSpec(latestChapterId: 'chapter-2').toStoredItem(
          sourceKey: 'src',
          comicId: 'comic-1',
          attemptId: 'attempt-2',
          evidenceSchema: labelA,
        ),
      );
      judgment.failNextBatch = StateError('injected crash');
      await expectLater(service.run(), throwsA(isA<Object>()));

      final after = await judgment.readFor('src', 'comic-1');
      _expectSameState(after!, before!, 'src/comic-1');

      // The retry then succeeds and processes the new observation.
      final retry = await service.run();
      expect(retry.writtenRows, 1);
      final recovered = await judgment.readFor('src', 'comic-1');
      expect(recovered!.processedAttemptId, 'attempt-2');
      expect(recovered.factJson, contains('chapter-2'));
    });
  });

  group('SC-005: already-processed observations survive a restart', () {
    test(
      'a rebuilt service instance does not reprocess stored state',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'venera-judgment-restart-',
        );
        addTearDown(() => tempDirectory.delete(recursive: true));
        final path = '${tempDirectory.path}${Platform.pathSeparator}state.db';

        final scans = InMemoryScanItemStore(
          items: [
            const ObservationSpec(latestChapterId: 'chapter-1').toStoredItem(
              sourceKey: 'src',
              comicId: 'comic-1',
              evidenceSchema: labelA,
            ),
          ],
        );

        // First "process": a fresh repository and service.
        final firstRepository = SqliteJudgmentRepository(databasePath: path);
        final firstService = JudgmentService(
          repository: firstRepository,
          scanRepository: scans,
          clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
        );
        expect((await firstService.run()).writtenRows, 1);
        final beforeRestart = await firstRepository.readFor('src', 'comic-1');
        await firstRepository.close();

        // Restart: brand new instances over the same database file.
        final secondRepository = SqliteJudgmentRepository(databasePath: path);
        addTearDown(secondRepository.close);
        final secondService = JudgmentService(
          repository: secondRepository,
          scanRepository: scans,
          clock: FixedClock(DateTime.utc(2026, 9, 11, 12)).call,
        );
        final afterRestart = await secondService.run();
        expect(afterRestart.writtenRows, 0);
        expect(afterRestart.processed, 0);

        final after = await secondRepository.readFor('src', 'comic-1');
        _expectSameState(after!, beforeRestart!, 'src/comic-1');
      },
    );
  });

  group('the processed mark, not the fact time, drives skipping', () {
    test('an unknown conclusion still advances the processed mark', () async {
      final judgment = InMemoryJudgmentRepository();
      // A fact exists; the observation shares no field with it, so the
      // conclusion is `unknown` and the fact is deliberately held.
      judgment.rows['src\u0000comic-1'] = JudgmentState(
        sourceKey: 'src',
        comicId: 'comic-1',
        factJson: '{"update":{"latestChapterId":"chapter-old"}}',
        factObservedAtMs: 1789036800000,
        evidenceSchema: labelA,
        lastDecision: JudgmentConclusion.rebaseline,
        lastReason: JudgmentReason.noPreviousEvidence,
        decidedAtMs: 1789036800000,
      );
      final scans = InMemoryScanItemStore(
        items: [
          const ObservationSpec(chapterCount: 7).toStoredItem(
            sourceKey: 'src',
            comicId: 'comic-1',
            attemptId: 'attempt-new',
            evidenceSchema: labelA,
          ),
        ],
      );
      final service = JudgmentService(
        repository: judgment,
        scanRepository: scans,
        clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
      );

      final first = await service.run();
      expect(first.writtenRows, 1);
      final state = await judgment.readFor('src', 'comic-1');
      expect(state!.lastReason, JudgmentReason.noCommonEvidence);
      expect(
        state.factJson,
        '{"update":{"latestChapterId":"chapter-old"}}',
        reason: 'an unknown conclusion advances nothing',
      );
      expect(state.processedAttemptId, 'attempt-new');

      // The second run must skip on the processed mark, not on the (stale)
      // fact time.
      final second = await service.run();
      expect(second.writtenRows, 0);
      expect(second.processed, 0);
      expect((await judgment.readFor('src', 'comic-1'))!.noCommonStreak, 1);
    });
  });

  group('T064: the recorded algorithm version gates recomputation', () {
    test(
      'a stored row is stamped with the current algorithm version',
      () async {
        final judgment = InMemoryJudgmentRepository();
        final scans = InMemoryScanItemStore(
          items: [
            const ObservationSpec(latestChapterId: 'chapter-1').toStoredItem(
              sourceKey: 'src',
              comicId: 'comic-1',
              evidenceSchema: labelA,
            ),
          ],
        );
        await JudgmentService(
          repository: judgment,
          scanRepository: scans,
          clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
        ).run();

        final state = await judgment.readFor('src', 'comic-1');
        expect(state!.algorithmVersion, judgmentAlgorithmVersion);
        expect(state.isCurrentAlgorithm, isTrue);
      },
    );

    test('an unchanged version keeps the second run at zero writes', () async {
      final judgment = InMemoryJudgmentRepository();
      final scans = InMemoryScanItemStore(
        items: [
          const ObservationSpec(latestChapterId: 'chapter-1').toStoredItem(
            sourceKey: 'src',
            comicId: 'comic-1',
            evidenceSchema: labelA,
          ),
        ],
      );
      final service = JudgmentService(
        repository: judgment,
        scanRepository: scans,
        clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
      );

      await service.run();
      final before = await judgment.readFor('src', 'comic-1');

      // The version mechanism must not turn ordinary re-runs into rewrites.
      for (var round = 0; round < 10; round++) {
        final summary = await service.run();
        expect(summary.writtenRows, 0, reason: 'round $round');
        expect(summary.processed, 0, reason: 'round $round');
      }
      _expectSameState(
        (await judgment.readFor('src', 'comic-1'))!,
        before!,
        'src/comic-1',
      );
    });

    test(
      'a version bump recomputes every stored judgement without a source request',
      () async {
        final judgment = InMemoryJudgmentRepository();
        const identityCount = 12;
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

        // Seed every row as if an older algorithm had produced it.  Using a
        // different integer is the only faithful simulation available: the
        // version constant is compiled in, exactly as it is in production.
        const staleVersion = judgmentAlgorithmVersion + 1;
        for (var index = 0; index < identityCount; index++) {
          judgment.rows['src\u0000comic-$index'] = JudgmentState(
            sourceKey: 'src',
            comicId: 'comic-$index',
            factJson: '{"update":{"latestChapterId":"stale-$index"}}',
            factObservedAtMs: 1700000000000,
            evidenceSchema: labelA,
            lastDecision: JudgmentConclusion.rebaseline,
            lastReason: JudgmentReason.noPreviousEvidence,
            decidedAtMs: 1700000000000,
            processedAttemptId: 'attempt-unchanged',
            algorithmVersion: staleVersion,
          );
        }
        final service = JudgmentService(
          repository: judgment,
          scanRepository: scans,
          clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
        );

        final summary = await service.run();

        // Every stale row is reprocessed even though no observation changed.
        expect(summary.processed, identityCount);
        expect(summary.writtenRows, identityCount);
        // Recompute reads the frozen evidence and never touches the network:
        // the service was handed no source at all, and the scan store is the
        // only other collaborator it has.
        expect(scans.readAllCalls, greaterThan(0));

        for (var index = 0; index < identityCount; index++) {
          final state = await judgment.readFor('src', 'comic-$index');
          expect(state!.algorithmVersion, judgmentAlgorithmVersion);
          expect(state.isCurrentAlgorithm, isTrue);
          expect(
            state.factJson,
            isNot(contains('stale-')),
            reason: 'comic-$index must have been recomputed from live evidence',
          );
          expect(state.factJson, contains('chapter-$index'));
        }
      },
    );

    test('a null stored version is treated as stale and recomputed', () async {
      final judgment = InMemoryJudgmentRepository();
      // This is the exact shape the `algorithm_version` migration leaves
      // behind: a perfectly valid row that predates the column.
      judgment.rows['src\u0000comic-1'] = JudgmentState(
        sourceKey: 'src',
        comicId: 'comic-1',
        factJson: '{"update":{"latestChapterId":"pre-migration"}}',
        factObservedAtMs: 1700000000000,
        evidenceSchema: labelA,
        lastDecision: JudgmentConclusion.rebaseline,
        lastReason: JudgmentReason.noPreviousEvidence,
        decidedAtMs: 1700000000000,
        processedAttemptId: 'attempt-1',
        algorithmVersion: null,
      );
      final scans = InMemoryScanItemStore(
        items: [
          const ObservationSpec(latestChapterId: 'chapter-1').toStoredItem(
            sourceKey: 'src',
            comicId: 'comic-1',
            attemptId: 'attempt-1',
            evidenceSchema: labelA,
          ),
        ],
      );

      final summary = await JudgmentService(
        repository: judgment,
        scanRepository: scans,
        clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
      ).run();

      expect(summary.writtenRows, 1);
      final state = await judgment.readFor('src', 'comic-1');
      expect(state!.algorithmVersion, judgmentAlgorithmVersion);
      expect(state.factJson, contains('chapter-1'));
    });

    test('recompute is idempotent once the version is current', () async {
      final judgment = InMemoryJudgmentRepository();
      final scans = InMemoryScanItemStore(
        items: [
          const ObservationSpec(latestChapterId: 'chapter-1').toStoredItem(
            sourceKey: 'src',
            comicId: 'comic-1',
            evidenceSchema: labelA,
          ),
        ],
      );
      final service = JudgmentService(
        repository: judgment,
        scanRepository: scans,
        clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
      );

      await service.run();
      // A second bump-free run must settle at zero, proving the mechanism is a
      // one-shot repair and not a permanent rewrite loop.
      expect((await service.run()).writtenRows, 0);
      expect((await service.run()).writtenRows, 0);
    });
  });

  group('T064: the algorithm_version column survives a real migration', () {
    late Directory tempDirectory;

    setUp(() async {
      tempDirectory = await Directory.systemTemp.createTemp(
        'venera-judgment-version-',
      );
    });

    tearDown(() async => tempDirectory.delete(recursive: true));

    test('an existing database gains the column and self-heals', () async {
      final path = '${tempDirectory.path}${Platform.pathSeparator}state.db';

      // Build the pre-T064 table by hand: no algorithm_version column.
      final legacy = sqlite3.open(path);
      try {
        legacy.execute('''
          CREATE TABLE judgment_state (
            source_key TEXT NOT NULL,
            comic_id   TEXT NOT NULL,
            fact_json            TEXT,
            fact_observed_at_ms  INTEGER,
            evidence_schema      TEXT,
            last_decision   TEXT NOT NULL
                            CHECK (last_decision IN ('changed','unchanged','rebaseline','unknown')),
            last_evidence   TEXT,
            last_previous_value TEXT,
            last_current_value  TEXT,
            last_reason     TEXT NOT NULL,
            decided_at_ms     INTEGER NOT NULL,
            no_common_streak  INTEGER NOT NULL DEFAULT 0,
            has_new_update        INTEGER NOT NULL DEFAULT 0,
            processed_attempt_id  TEXT,
            PRIMARY KEY (source_key, comic_id)
          )
        ''');
        legacy.execute(
          '''INSERT INTO judgment_state
             (source_key, comic_id, fact_json, fact_observed_at_ms,
              evidence_schema, last_decision, last_reason, decided_at_ms,
              no_common_streak, has_new_update, processed_attempt_id)
             VALUES ('src', 'comic-1',
                     '{"update":{"latestChapterId":"pre-migration"}}',
                     1700000000000, '$labelA', 'rebaseline',
                     'noPreviousEvidence', 1700000000000, 0, 0, 'attempt-1')''',
        );
      } finally {
        legacy.dispose();
      }

      final repository = SqliteJudgmentRepository(databasePath: path);
      addTearDown(repository.close);
      await repository.ensureOpen();

      final columns = repository.database
          .select('PRAGMA table_info(judgment_state)')
          .map((row) => row['name'] as String)
          .toSet();
      expect(columns, contains('algorithm_version'));

      // The pre-existing row is readable and reports a null version.
      final migrated = await repository.readFor('src', 'comic-1');
      expect(migrated!.algorithmVersion, isNull);
      expect(migrated.isCurrentAlgorithm, isFalse);

      // Running judgment stamps the current version and refreshes the fact
      // from the still-untouched scan evidence.
      final scans = InMemoryScanItemStore(
        items: [
          const ObservationSpec(latestChapterId: 'chapter-1').toStoredItem(
            sourceKey: 'src',
            comicId: 'comic-1',
            attemptId: 'attempt-1',
            evidenceSchema: labelA,
          ),
        ],
      );
      final summary = await JudgmentService(
        repository: repository,
        scanRepository: scans,
        clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
      ).run();

      expect(summary.writtenRows, 1);
      final healed = await repository.readFor('src', 'comic-1');
      expect(healed!.algorithmVersion, judgmentAlgorithmVersion);
      expect(healed.factJson, contains('chapter-1'));

      // And it settles: the next run writes nothing.
      expect(
        (await JudgmentService(
          repository: repository,
          scanRepository: scans,
          clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
        ).run()).writtenRows,
        0,
      );
    });

    test('repeated opens do not re-add the column', () async {
      final path = '${tempDirectory.path}${Platform.pathSeparator}reopen.db';
      for (var index = 0; index < 3; index++) {
        final opened = SqliteJudgmentRepository(databasePath: path);
        await opened.ensureOpen();
        expect(
          opened.database
              .select('PRAGMA table_info(judgment_state)')
              .where((row) => row['name'] == 'algorithm_version'),
          hasLength(1),
        );
        await opened.close();
      }
    });
  });
}

void _expectSameState(
  JudgmentState actual,
  JudgmentState expected,
  String identity,
) {
  expect(actual.factJson, expected.factJson, reason: identity);
  expect(actual.factObservedAtMs, expected.factObservedAtMs, reason: identity);
  expect(actual.evidenceSchema, expected.evidenceSchema, reason: identity);
  expect(actual.lastDecision, expected.lastDecision, reason: identity);
  expect(actual.lastEvidence, expected.lastEvidence, reason: identity);
  expect(
    actual.lastPreviousValue,
    expected.lastPreviousValue,
    reason: identity,
  );
  expect(actual.lastCurrentValue, expected.lastCurrentValue, reason: identity);
  expect(actual.lastReason, expected.lastReason, reason: identity);
  expect(actual.decidedAtMs, expected.decidedAtMs, reason: identity);
  expect(actual.noCommonStreak, expected.noCommonStreak, reason: identity);
  expect(actual.hasNewUpdate, expected.hasNewUpdate, reason: identity);
  expect(
    actual.processedAttemptId,
    expected.processedAttemptId,
    reason: identity,
  );
  expect(actual.algorithmVersion, expected.algorithmVersion, reason: identity);
}
