import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
  }) => ScanItemResult.observed(
    attemptId: scanUuidV5(scope.scopeAttemptId, 'source\u0000$comicId'),
    scopeAttemptId: scope.scopeAttemptId,
    sourceKey: 'source',
    comicId: comicId,
    producer: scope.producer,
    definitionRevision: scope.definitionRevision,
    observedAt: '2026-09-10T00:00:00.000Z',
    observation: ScanObservation(
      update: UpdateDescriptor(latestChapterId: chapter, chapterCount: count),
      sourceUnread: chapter == null ? false : null,
    ),
  );

  ScanItemResult failed(ScanScopeHandle scope, String comicId) =>
      ScanItemResult.failed(
        attemptId: scanUuidV5(scope.scopeAttemptId, 'source\u0000$comicId'),
        scopeAttemptId: scope.scopeAttemptId,
        sourceKey: 'source',
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
}
