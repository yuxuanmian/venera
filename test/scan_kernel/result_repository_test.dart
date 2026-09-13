import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_result_repository.dart';
import 'package:venera/foundation/scan/sqlite_scan_result_repository.dart';

void main() {
  late Directory tempDirectory;
  late SqliteScanResultRepository repository;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('venera-scan-repo-');
    repository = SqliteScanResultRepository(
      databasePath: '${tempDirectory.path}${Platform.pathSeparator}scan.db',
      clock: () => DateTime.utc(2026, 9, 10, 1),
    );
    await repository.ensureOpen();
  });

  tearDown(() async {
    await repository.close();
    await tempDirectory.delete(recursive: true);
  });

  ScanItemResult observed(
    ScanScopeHandle scope,
    String comicId, {
    String? chapter,
    int? count,
    String sourceKey = 'source',
  }) => ScanItemResult.observed(
    attemptId: scanUuidV5(scope.scopeAttemptId, '$sourceKey\u0000$comicId'),
    scopeAttemptId: scope.scopeAttemptId,
    sourceKey: sourceKey,
    comicId: comicId,
    producer: scope.producer,
    definitionRevision: scope.definitionRevision,
    observedAt: '2026-09-10T00:00:00.000Z',
    observation: ScanObservation(
      update: UpdateDescriptor(latestChapterId: chapter, chapterCount: count),
      sourceUnread: chapter == null ? false : null,
    ),
  );

  ScanItemResult failed(
    ScanScopeHandle scope,
    String comicId, {
    String sourceKey = 'source',
  }) => ScanItemResult.failed(
    attemptId: scanUuidV5(scope.scopeAttemptId, '$sourceKey\u0000$comicId'),
    scopeAttemptId: scope.scopeAttemptId,
    sourceKey: sourceKey,
    comicId: comicId,
    producer: scope.producer,
    definitionRevision: scope.definitionRevision,
    observedAt: '2026-09-10T00:00:00.000Z',
    failure: const ScanFailure(httpStatus: 403, message: 'forbidden'),
  );

  test(
    'creates the three-table schema and commits item/count atomically',
    () async {
      expect(
        repository.database
            .select(
              "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
            )
            .map((row) => row['name']),
        containsAll(<Object>[
          'scan_meta',
          'scan_scope_state',
          'scan_item_state',
        ]),
      );
      expect(
        repository.database.select('PRAGMA journal_mode').single.values.first,
        'wal',
      );
      expect(
        repository.database.select('PRAGMA synchronous').single.values.first,
        2,
      );

      final scope = await repository.beginScope(
        sourceKey: 'source',
        producer: ScanProducer.comic,
        scopeKey: 'comic-1',
        definitionRevision: 'rev-1',
      );
      final context = ScanIngestionContext(scope: scope);
      final item = observed(scope, 'comic-1', chapter: 'chapter-1');
      expect(
        (await repository.saveItem(context, item)).disposition,
        ScanItemWriteDisposition.written,
      );
      expect(
        (await repository.saveItem(context, item)).disposition,
        ScanItemWriteDisposition.duplicate,
      );
      final running = await repository.readLatestScope(
        'source',
        ScanProducer.comic,
        'comic-1',
      );
      expect(running!.itemCount, 1);
      expect(
        (await repository.finishScope(
          context,
          ScanScopeStatus.completed,
        )).finished,
        isTrue,
      );
      final stored = await repository.readLatestItem('source', 'comic-1');
      expect(stored!.result.observation!.update!.latestChapterId, 'chapter-1');
      expect(
        (await repository.readLatestScope(
          'source',
          ScanProducer.comic,
          'comic-1',
        ))!.status,
        ScanScopeStatus.completed,
      );
    },
  );

  test('new ordinal wins and old item/scope arrivals are stale', () async {
    final first = await repository.beginScope(
      sourceKey: 'source',
      producer: ScanProducer.collection,
      scopeKey: 'default',
      definitionRevision: 'rev-1',
    );
    final firstContext = ScanIngestionContext(scope: first);
    final firstItem = observed(first, 'comic-1', chapter: 'old');
    await repository.saveItem(firstContext, firstItem);

    final second = await repository.beginScope(
      sourceKey: 'source',
      producer: ScanProducer.collection,
      scopeKey: 'default',
      definitionRevision: 'rev-2',
    );
    final secondContext = ScanIngestionContext(scope: second);
    expect(
      (await repository.saveItem(firstContext, firstItem)).disposition,
      ScanItemWriteDisposition.stale,
    );
    expect(
      (await repository.finishScope(
        firstContext,
        ScanScopeStatus.completed,
      )).disposition,
      ScanScopeWriteDisposition.stale,
    );

    final newer = observed(second, 'comic-1', chapter: 'new');
    expect((await repository.saveItem(secondContext, newer)).written, isTrue);
    final failedItem = failed(second, 'comic-1');
    expect(
      () => repository.saveItem(secondContext, failedItem),
      throwsA(isA<ScanResultConflictException>()),
      reason:
          'same ordinal and identity cannot silently replace a committed result',
    );
    final latest = await repository.readLatestItem('source', 'comic-1');
    expect(latest!.result.observation!.update!.latestChapterId, 'new');
  });

  test('a newer attempt can replace a comic with a failure', () async {
    final first = await repository.beginScope(
      sourceKey: 'source',
      producer: ScanProducer.comic,
      scopeKey: 'comic-1',
      definitionRevision: 'rev-1',
    );
    await repository.saveItem(
      ScanIngestionContext(scope: first),
      observed(first, 'comic-1', chapter: 'old'),
    );
    final second = await repository.beginScope(
      sourceKey: 'source',
      producer: ScanProducer.comic,
      scopeKey: 'comic-1',
      definitionRevision: 'rev-2',
    );
    final context = ScanIngestionContext(scope: second);
    await repository.saveItem(context, failed(second, 'comic-1'));
    final item = await repository.readLatestItem('source', 'comic-1');
    expect(item!.result.failure!.httpStatus, 403);
    expect(item.result.observation, isNull);
  });

  test('reopening the database interrupts only遗留 running scopes', () async {
    final scope = await repository.beginScope(
      sourceKey: 'source',
      producer: ScanProducer.comic,
      scopeKey: 'comic-1',
      definitionRevision: 'rev-1',
    );
    await repository.close();
    final reopened = SqliteScanResultRepository(
      databasePath: repository.databasePath,
    );
    addTearDown(reopened.close);
    await reopened.ensureOpen();
    final state = await reopened.readLatestScope(
      'source',
      ScanProducer.comic,
      'comic-1',
    );
    expect(state!.scopeAttemptId, scope.scopeAttemptId);
    expect(state.status, ScanScopeStatus.interrupted);
    expect(state.finishedAtMs, isNotNull);
  });

  test('transaction errors roll back without publishing an item', () async {
    final scope = await repository.beginScope(
      sourceKey: 'source',
      producer: ScanProducer.comic,
      scopeKey: 'comic-1',
      definitionRevision: 'rev-1',
    );
    var failWrite = false;
    await repository.close();
    repository = SqliteScanResultRepository(
      databasePath: '${tempDirectory.path}${Platform.pathSeparator}rollback.db',
      clock: () => DateTime.utc(2026, 9, 10, 1),
      operationHook: (operation) {
        if (failWrite && operation == 'saveItem.beforeWrite') {
          throw StateError('synthetic storage fault');
        }
      },
    );
    await repository.ensureOpen();
    final newScope = await repository.beginScope(
      sourceKey: 'source',
      producer: ScanProducer.comic,
      scopeKey: 'comic-2',
      definitionRevision: 'rev-1',
    );
    failWrite = true;
    expect(
      () => repository.saveItem(
        ScanIngestionContext(scope: newScope),
        observed(newScope, 'comic-2', chapter: 'chapter'),
      ),
      throwsA(isA<ScanStorageException>()),
    );
    expect(await repository.readLatestItem('source', 'comic-2'), isNull);
    final scopeState = await repository.readLatestScope(
      'source',
      ScanProducer.comic,
      'comic-2',
    );
    expect(scopeState!.itemCount, 0);
    // Keep the original scope variable used as an explicit test of the first
    // connection's lifecycle; no item was committed before the close.
    expect(scope.scopeKey, 'comic-1');
  });

  group('readAllItems', () {
    test('an empty table returns an empty list', () async {
      expect(await repository.readAllItems(), isEmpty);
    });

    test('enumerates every source and comic, including failures', () async {
      final comicScope = await repository.beginScope(
        sourceKey: 'source-a',
        producer: ScanProducer.comic,
        scopeKey: 'comic-1',
        definitionRevision: 'rev-1',
      );
      final comicContext = ScanIngestionContext(scope: comicScope);
      await repository.saveItem(
        comicContext,
        observed(
          comicScope,
          'comic-1',
          chapter: 'chapter-1',
          sourceKey: 'source-a',
        ),
      );

      final collectionScope = await repository.beginScope(
        sourceKey: 'source-a',
        producer: ScanProducer.collection,
        scopeKey: 'default',
        definitionRevision: 'rev-1',
      );
      final collectionContext = ScanIngestionContext(scope: collectionScope);
      await repository.saveItem(
        collectionContext,
        ScanItemResult.observed(
          attemptId: scanUuidV5(
            collectionScope.scopeAttemptId,
            'source-a\u0000comic-2',
          ),
          scopeAttemptId: collectionScope.scopeAttemptId,
          sourceKey: 'source-a',
          comicId: 'comic-2',
          producer: ScanProducer.collection,
          definitionRevision: 'rev-1',
          observedAt: '2026-09-10T00:00:00.000Z',
          observation: ScanObservation(
            update: UpdateDescriptor(latestChapterId: 'chapter-2'),
          ),
        ),
      );
      await repository.saveItem(
        collectionContext,
        ScanItemResult.failed(
          attemptId: scanUuidV5(
            collectionScope.scopeAttemptId,
            'source-a\u0000comic-3',
          ),
          scopeAttemptId: collectionScope.scopeAttemptId,
          sourceKey: 'source-a',
          comicId: 'comic-3',
          producer: ScanProducer.collection,
          definitionRevision: 'rev-1',
          observedAt: '2026-09-10T00:00:00.000Z',
          failure: const ScanFailure(httpStatus: 403, message: 'forbidden'),
        ),
      );

      final otherScope = await repository.beginScope(
        sourceKey: 'source-b',
        producer: ScanProducer.comic,
        scopeKey: 'comic-1',
        definitionRevision: 'rev-1',
      );
      await repository.saveItem(
        ScanIngestionContext(scope: otherScope),
        ScanItemResult.observed(
          attemptId: scanUuidV5(
            otherScope.scopeAttemptId,
            'source-b\u0000comic-1',
          ),
          scopeAttemptId: otherScope.scopeAttemptId,
          sourceKey: 'source-b',
          comicId: 'comic-1',
          producer: ScanProducer.comic,
          definitionRevision: 'rev-1',
          observedAt: '2026-09-10T00:00:00.000Z',
          observation: ScanObservation(
            update: UpdateDescriptor(latestChapterId: 'chapter-b1'),
          ),
        ),
      );

      final items = await repository.readAllItems();
      expect(items, hasLength(4));
      expect(
        items.map((i) => '${i.result.sourceKey}/${i.result.comicId}').toSet(),
        {
          'source-a/comic-1',
          'source-a/comic-2',
          'source-a/comic-3',
          'source-b/comic-1',
        },
      );
      // A failure payload is enumerated too: the judgment service, not the
      // store, decides to skip it.
      final failedItem = items.firstWhere((i) => i.result.comicId == 'comic-3');
      expect(failedItem.result.isSuccess, isFalse);
      expect(failedItem.result.failure!.httpStatus, 403);
    });

    test('round-trips attemptId and evidenceSchema verbatim', () async {
      final scope = await repository.beginScope(
        sourceKey: 'source',
        producer: ScanProducer.comic,
        scopeKey: 'comic-1',
        definitionRevision: 'rev-1',
      );
      const schema = '{"latestchapterid":"last_chapter.id"}';
      final item = ScanItemResult.observed(
        attemptId: 'fixed-attempt-id',
        scopeAttemptId: scope.scopeAttemptId,
        sourceKey: 'source',
        comicId: 'comic-1',
        producer: ScanProducer.comic,
        definitionRevision: 'rev-1',
        observedAt: '2026-09-10T00:00:00.000Z',
        evidenceSchema: schema,
        observation: ScanObservation(
          update: UpdateDescriptor(latestChapterId: 'chapter-1'),
        ),
      );
      await repository.saveItem(ScanIngestionContext(scope: scope), item);

      final stored = (await repository.readAllItems()).single;
      expect(stored.result.attemptId, 'fixed-attempt-id');
      expect(stored.result.evidenceSchema, schema);
      // The observable fields live on the result, not on the stored wrapper.
      expect(stored.result.definitionRevision, 'rev-1');
    });
  });

  group('evidence_schema migration (T042)', () {
    test(
      'adds the column to a pre-existing database and keeps old rows',
      () async {
        await repository.close();
        final path =
            '${tempDirectory.path}${Platform.pathSeparator}legacy_scan.db';
        final legacy = sqlite3.open(path);
        try {
          // The pre-005 DDL: no evidence_schema column.
          legacy.execute('''
          CREATE TABLE scan_item_state (
            source_key TEXT NOT NULL,
            comic_id TEXT NOT NULL,
            attempt_id TEXT NOT NULL UNIQUE,
            scope_attempt_id TEXT NOT NULL,
            attempt_ordinal INTEGER NOT NULL CHECK (attempt_ordinal > 0),
            access_context_key TEXT,
            producer TEXT NOT NULL CHECK (producer IN ('comic', 'collection')),
            definition_revision TEXT NOT NULL,
            observed_at_ms INTEGER NOT NULL,
            committed_at_ms INTEGER NOT NULL,
            observation_json TEXT,
            failure_json TEXT,
            PRIMARY KEY (source_key, comic_id),
            CHECK ((observation_json IS NOT NULL AND failure_json IS NULL) OR
                   (observation_json IS NULL AND failure_json IS NOT NULL))
          )
        ''');
          legacy.execute(
            '''INSERT INTO scan_item_state
             (source_key, comic_id, attempt_id, scope_attempt_id, attempt_ordinal,
              access_context_key, producer, definition_revision, observed_at_ms,
              committed_at_ms, observation_json, failure_json)
             VALUES ('source', 'comic-1', 'legacy-attempt', 'legacy-scope', 1,
                     NULL, 'comic', 'rev-1', 1757000000000, 1757000000000,
                     '{"update":{"latestChapterId":"chapter-legacy"}}', NULL)''',
          );
        } finally {
          legacy.dispose();
        }

        final migrated = SqliteScanResultRepository(databasePath: path);
        addTearDown(migrated.close);
        await migrated.ensureOpen();

        final columns = migrated.database
            .select('PRAGMA table_info(scan_item_state)')
            .map((row) => row['name'] as String)
            .toSet();
        expect(columns, contains('evidence_schema'));

        final stored = await migrated.readLatestItem('source', 'comic-1');
        expect(stored!.result.comicId, 'comic-1');
        expect(
          stored.result.observation!.update!.latestChapterId,
          'chapter-legacy',
        );
        // Existing rows keep a null label, which judgment reads as "no recorded
        // label" and therefore rebuilds the baseline without a false update.
        expect(stored.result.evidenceSchema, isNull);
        expect(
          (await migrated.readAllItems()).single.result.evidenceSchema,
          isNull,
        );
      },
    );

    test('is idempotent across repeated opens', () async {
      await repository.close();
      final path =
          '${tempDirectory.path}${Platform.pathSeparator}repeat_open.db';
      for (var index = 0; index < 3; index++) {
        final opened = SqliteScanResultRepository(databasePath: path);
        await opened.ensureOpen();
        final columns = opened.database
            .select('PRAGMA table_info(scan_item_state)')
            .where((row) => row['name'] == 'evidence_schema');
        expect(columns, hasLength(1));
        await opened.close();
      }
    });
  });
}
