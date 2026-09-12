import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_repository.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';

JudgmentState row({
  String sourceKey = 'source',
  String comicId = 'comic-1',
  String? factJson = '{"update":{"latestChapterId":"c-1"}}',
  int? factObservedAtMs = 1757000000000,
  String? evidenceSchema = '{"latestchapterid":"last_chapter.id"}',
  JudgmentConclusion decision = JudgmentConclusion.changed,
  JudgmentEvidence? evidence = JudgmentEvidence.latestChapterId,
  String? previousValue = 'c-0',
  String? currentValue = 'c-1',
  JudgmentReason reason = JudgmentReason.different,
  int decidedAtMs = 1758000000000,
  int noCommonStreak = 0,
  bool hasNewUpdate = true,
  String? processedAttemptId = 'attempt-1',
}) => JudgmentState(
  sourceKey: sourceKey,
  comicId: comicId,
  factJson: factJson,
  factObservedAtMs: factObservedAtMs,
  evidenceSchema: evidenceSchema,
  lastDecision: decision,
  lastEvidence: evidence,
  lastPreviousValue: previousValue,
  lastCurrentValue: currentValue,
  lastReason: reason,
  decidedAtMs: decidedAtMs,
  noCommonStreak: noCommonStreak,
  hasNewUpdate: hasNewUpdate,
  processedAttemptId: processedAttemptId,
);

void main() {
  late Directory tempDirectory;
  late SqliteJudgmentRepository repository;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('venera-judgment-');
    repository = SqliteJudgmentRepository(
      databasePath: '${tempDirectory.path}${Platform.pathSeparator}state.db',
    );
    await repository.ensureOpen();
  });

  tearDown(() async {
    await repository.close();
    await tempDirectory.delete(recursive: true);
  });

  group('schema (contracts/state-schema.sql)', () {
    test('creates one table, the two fact checks, and schema version 1', () {
      final tables = repository.database
          .select(
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
          )
          .map((r) => r['name']);
      expect(tables, contains('judgment_state'));
      expect(
        repository.database.select('PRAGMA journal_mode').single.values.first,
        'wal',
      );
      expect(
        repository.database.select('PRAGMA user_version').single.values.first,
        SqliteJudgmentRepository.schemaVersion,
      );
      final ddl =
          repository.database
                  .select(
                    "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'judgment_state'",
                  )
                  .single['sql']
              as String;
      expect(
        ddl,
        contains('(fact_json IS NULL) = (fact_observed_at_ms IS NULL)'),
      );
      expect(ddl, contains('fact_json IS NULL OR evidence_schema IS NOT NULL'));
    });

    test('the column set matches the ownership list exactly', () {
      final columns = repository.database
          .select('PRAGMA table_info(judgment_state)')
          .map((r) => r['name'] as String)
          .toList();
      for (final owned in SqliteJudgmentRepository.ownedColumns) {
        expect(columns, contains(owned));
      }
      // Identity columns plus the owned ones.
      expect(columns.length, SqliteJudgmentRepository.ownedColumns.length + 2);
    });

    test('the declared columns match contracts/state-schema.sql exactly', () {
      // This is the guard that would have caught T066 before a reviewer did:
      // the DDL attachment and the implementation drifted apart once already.
      // The list below is transcribed from the attachment's CREATE TABLE, in
      // declaration order, so any add/remove/rename on either side fails here.
      const contractColumns = <String>[
        // Identity.
        'source_key',
        'comic_id',
        // Fact (watermark).
        'fact_json',
        'fact_observed_at_ms',
        'evidence_schema',
        // Decision result.
        'last_decision',
        'last_evidence',
        'last_previous_value',
        'last_current_value',
        'last_reason',
        'decided_at_ms',
        'no_common_streak',
        // Visible flag and idempotency.
        'has_new_update',
        'processed_attempt_id',
        'algorithm_version',
      ];

      final actual = repository.database
          .select('PRAGMA table_info(judgment_state)')
          .map((r) => r['name'] as String)
          .toList();
      expect(
        actual,
        contractColumns,
        reason:
            'the implementation DDL must match the contract attachment; '
            'update both together',
      );

      // The ownership list is the contract's "13 owned columns" claim, and it
      // must be exactly the declared set minus the two identity columns.
      expect(
        SqliteJudgmentRepository.ownedColumns,
        contractColumns.sublist(2),
        reason: 'every non-identity column is owned by judgment',
      );
      expect(SqliteJudgmentRepository.ownedColumns, hasLength(13));
    });
  });

  group('applyBatch', () {
    test('an empty batch writes zero rows', () async {
      expect(await repository.applyBatch(const []), 0);
      expect(
        repository.database
            .select('SELECT COUNT(*) AS n FROM judgment_state')
            .single['n'],
        0,
      );
    });

    test('writing the same batch twice yields identical state', () async {
      final batch = [row()];
      expect(await repository.applyBatch(batch), 1);
      final first = await repository.readFor('source', 'comic-1');
      expect(await repository.applyBatch(batch), 1);
      final second = await repository.readFor('source', 'comic-1');
      expect(second!.sourceKey, first!.sourceKey);
      expect(second.comicId, first.comicId);
      expect(second.factJson, first.factJson);
      expect(second.factObservedAtMs, first.factObservedAtMs);
      expect(second.evidenceSchema, first.evidenceSchema);
      expect(second.lastDecision, first.lastDecision);
      expect(second.lastEvidence, first.lastEvidence);
      expect(second.lastPreviousValue, first.lastPreviousValue);
      expect(second.lastCurrentValue, first.lastCurrentValue);
      expect(second.lastReason, first.lastReason);
      expect(second.decidedAtMs, first.decidedAtMs);
      expect(second.noCommonStreak, first.noCommonStreak);
      expect(second.hasNewUpdate, first.hasNewUpdate);
      expect(second.processedAttemptId, first.processedAttemptId);
    });

    test('clear empties the table but leaves the schema in place', () async {
      await repository.applyBatch([row()]);
      await repository.clear();
      expect(await repository.readSnapshot(), isEmpty);
      expect(
        repository.database
            .select(
              "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'judgment_state'",
            )
            .length,
        1,
      );
    });

    test('clear resolves with no rows present', () async {
      await repository.clear();
      expect(await repository.readSnapshot(), isEmpty);
    });
  });

  group('CHECK constraints', () {
    test('rejects a fact without its observation time', () async {
      await expectLater(
        repository.applyBatch([row(factObservedAtMs: null)]),
        throwsA(isA<JudgmentStorageException>()),
      );
      expect(await repository.readSnapshot(), isEmpty);
    });

    test('rejects a fact without a comparable label', () async {
      await expectLater(
        repository.applyBatch([row(evidenceSchema: null)]),
        throwsA(isA<JudgmentStorageException>()),
      );
      expect(await repository.readSnapshot(), isEmpty);
    });

    test('accepts a null fact with null time and null label', () async {
      await repository.applyBatch([
        row(
          factJson: null,
          factObservedAtMs: null,
          evidenceSchema: null,
          decision: JudgmentConclusion.unknown,
          evidence: null,
          previousValue: null,
          currentValue: null,
          reason: JudgmentReason.noUsableEvidence,
        ),
      ]);
      final state = await repository.readFor('source', 'comic-1');
      expect(state!.factJson, isNull);
      expect(state.factObservedAtMs, isNull);
      expect(state.evidenceSchema, isNull);
      expect(state.hasFact, isFalse);
    });

    test('rejects an unknown conclusion or reason value', () async {
      expect(
        () => repository.database.execute('''INSERT INTO judgment_state
             (source_key, comic_id, last_decision, last_reason, decided_at_ms)
             VALUES ('s', 'c', 'maybe', 'equal', 1)'''),
        throwsA(isA<SqliteException>()),
      );
      expect(
        () => repository.database.execute('''INSERT INTO judgment_state
             (source_key, comic_id, last_decision, last_reason, decided_at_ms)
             VALUES ('s', 'c', 'changed', 'because', 1)'''),
        throwsA(isA<SqliteException>()),
      );
    });

    test('rejects a retired marker evidence value', () async {
      expect(
        () => repository.database.execute('''INSERT INTO judgment_state
             (source_key, comic_id, last_decision, last_evidence, last_reason, decided_at_ms)
             VALUES ('s', 'c', 'changed', 'marker', 'equal', 1)'''),
        throwsA(isA<SqliteException>()),
      );
    });
  });

  group('column ownership (research R-05)', () {
    test(
      'a batch write never clears columns owned by another writer',
      () async {
        // Simulate the future scheduling/health writers by adding their columns
        // and populating them; the DDL attachment deliberately has neither.
        repository.database.execute(
          'ALTER TABLE judgment_state ADD COLUMN next_check_at_ms INTEGER',
        );
        repository.database.execute(
          'ALTER TABLE judgment_state ADD COLUMN failure_streak INTEGER',
        );
        await repository.applyBatch([row()]);
        repository.database.execute('''UPDATE judgment_state
           SET next_check_at_ms = 4242, failure_streak = 7
           WHERE source_key = 'source' AND comic_id = 'comic-1' ''');

        await repository.applyBatch([
          row(
            currentValue: 'c-3',
            factJson: '{"update":{"latestChapterId":"c-3"}}',
            processedAttemptId: 'attempt-2',
          ),
        ]);

        final raw = repository.database.select(
          '''SELECT next_check_at_ms, failure_streak, last_current_value
               FROM judgment_state
               WHERE source_key = 'source' AND comic_id = 'comic-1' ''',
        ).single;
        expect(raw['next_check_at_ms'], 4242);
        expect(raw['failure_streak'], 7);
        // The judgment-owned column did move.
        expect(raw['last_current_value'], 'c-3');
      },
    );
  });

  group('comparison pair round trip', () {
    test(
      'null and non-null previous/current values survive verbatim',
      () async {
        await repository.applyBatch([
          row(
            comicId: 'with-values',
            previousValue: 'chapter-41',
            currentValue: '["chapter-43","chapter-42"]',
          ),
          row(
            comicId: 'without-values',
            previousValue: null,
            currentValue: null,
            decision: JudgmentConclusion.unknown,
            evidence: null,
            reason: JudgmentReason.noUsableEvidence,
          ),
        ]);

        final withValues = await repository.readFor('source', 'with-values');
        expect(withValues!.lastPreviousValue, 'chapter-41');
        expect(withValues.lastCurrentValue, '["chapter-43","chapter-42"]');

        final withoutValues = await repository.readFor(
          'source',
          'without-values',
        );
        expect(withoutValues!.lastPreviousValue, isNull);
        expect(withoutValues.lastCurrentValue, isNull);
      },
    );

    test('a time value keeps its original string representation', () async {
      const original = '2026-09-02T16:15:30.123+08:00';
      await repository.applyBatch([
        row(
          factJson: '{"update":{"updatedAt":"$original"}}',
          previousValue: null,
          currentValue: original,
        ),
      ]);
      final state = await repository.readFor('source', 'comic-1');
      expect(state!.factJson, contains(original));
      expect(state.lastCurrentValue, original);
      expect(state.lastCurrentValue, isNot(contains('2026-09-02T08:15:30')));
    });
  });

  group('identity isolation (FR-039)', () {
    test('the same comicId under two sources never overwrites', () async {
      await repository.applyBatch([
        row(sourceKey: 'source-a', currentValue: 'a-value'),
        row(sourceKey: 'source-b', currentValue: 'b-value'),
      ]);

      final a = await repository.readFor('source-a', 'comic-1');
      final b = await repository.readFor('source-b', 'comic-1');
      expect(a!.lastCurrentValue, 'a-value');
      expect(b!.lastCurrentValue, 'b-value');

      await repository.applyBatch([
        row(sourceKey: 'source-a', currentValue: 'a-updated'),
      ]);
      expect(
        (await repository.readFor('source-a', 'comic-1'))!.lastCurrentValue,
        'a-updated',
      );
      expect(
        (await repository.readFor('source-b', 'comic-1'))!.lastCurrentValue,
        'b-value',
      );
      expect((await repository.readSnapshot()).length, 2);
    });
  });

  group('failure handling', () {
    test('a failed batch leaves the previous state intact', () async {
      await repository.applyBatch([row()]);
      final before = await repository.readFor('source', 'comic-1');

      // A second row in the batch violates a CHECK, so the whole transaction
      // must roll back rather than keep the first row's new value.
      await expectLater(
        repository.applyBatch([
          row(currentValue: 'c-9'),
          row(comicId: 'comic-2', evidenceSchema: null),
        ]),
        throwsA(isA<JudgmentStorageException>()),
      );

      final after = await repository.readFor('source', 'comic-1');
      expect(after!.lastCurrentValue, before!.lastCurrentValue);
      expect(after.processedAttemptId, before.processedAttemptId);
    });

    test('reopening an existing database keeps its rows', () async {
      await repository.applyBatch([row()]);
      await repository.close();
      final reopened = SqliteJudgmentRepository(
        databasePath: repository.databasePath,
      );
      addTearDown(reopened.close);
      await reopened.ensureOpen();
      expect(
        (await reopened.readFor('source', 'comic-1'))!.lastCurrentValue,
        'c-1',
      );
    });
  });
}
