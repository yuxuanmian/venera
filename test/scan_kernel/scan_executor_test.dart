import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/scan/execution_guard.dart';
import 'package:venera/foundation/scan/full_scan_planner.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_call_lease.dart';
import 'package:venera/foundation/scan/scan_emission.dart';
import 'package:venera/foundation/scan/scan_executor.dart';
import 'package:venera/foundation/scan/scan_result_repository.dart';
import 'package:venera/foundation/scan/source_adapter.dart';

import 'fakes.dart';

void main() {
  test('ComicWork persists one successful item and terminal scope', () async {
    final source = makeScanTestSource('comic-source');
    final adapter = FakeScanAdapter(
      sourceKey: source.key,
      comicLoader: (_, __) async => const {
        'observation': {
          'update': {'updatedAt': '2026-09-10'},
          'sourceUnread': false,
        },
      },
    );
    final repository = FakeScanResultRepository();
    final work = _comicWork(source, adapter, 'comic-1');
    final outcome = await _execute(repository, work);

    expect(outcome.status, ScanWorkOutcomeStatus.completed);
    expect(outcome.persistedItems, 1);
    final item = repository.items['comic-source\u0000comic-1'];
    expect(item!.result.observation!.sourceUnread, isFalse);
    final scope = await repository.readLatestScope(
      'comic-source',
      ScanProducer.comic,
      'comic-1',
    );
    expect(scope!.status, ScanScopeStatus.completed);
    expect(scope.itemCount, 1);
  });

  test('ComicWork stores a source failure without classifying it', () async {
    final source = makeScanTestSource('comic-source');
    final adapter = FakeScanAdapter(
      sourceKey: source.key,
      comicLoader: (_, __) async => const {
        'failure': {'httpStatus': 403, 'sourceCode': 'AUTH_REQUIRED'},
      },
    );
    final repository = FakeScanResultRepository();
    final outcome = await _execute(
      repository,
      _comicWork(source, adapter, 'comic-1'),
    );

    expect(outcome.status, ScanWorkOutcomeStatus.failed);
    expect(outcome.failure!.httpStatus, 403);
    final item = repository.items['comic-source\u0000comic-1'];
    expect(item!.result.failure!.httpStatus, 403);
    expect(item.result.failure!.sourceCode, 'AUTH_REQUIRED');
    final scope = await repository.readLatestScope(
      'comic-source',
      ScanProducer.comic,
      'comic-1',
    );
    expect(scope!.status, ScanScopeStatus.failed);
    expect(scope.itemCount, 1);
  });

  test('a malformed collection page commits no item from that page', () async {
    final source = makeScanTestSource('collection-source');
    var calls = 0;
    final adapter = FakeScanAdapter(
      sourceKey: source.key,
      collectionLoader: (_, cursor, __) async {
        calls++;
        if (calls == 1) {
          return const {
            'items': [
              {
                'comicId': 'first',
                'observation': {
                  'update': {'latestChapterId': 'ch-1'},
                },
              },
              {
                'comicId': 'second',
                'observation': {'sourceUnread': true},
              },
            ],
            'next': 'page-2',
          };
        }
        return const {
          'items': [
            {
              'comicId': 'third',
              'observation': {
                'update': {'latestChapterId': 'ch-3'},
              },
            },
            {'comicId': 42, 'observation': {}},
          ],
          'next': null,
        };
      },
    );
    final repository = FakeScanResultRepository();
    final outcome = await _execute(
      repository,
      _collectionWork(source, adapter, 'default'),
    );

    expect(calls, 2);
    expect(outcome.status, ScanWorkOutcomeStatus.failed);
    expect(outcome.persistedItems, 2);
    expect(
      repository.items.keys,
      containsAll(<String>[
        'collection-source\u0000first',
        'collection-source\u0000second',
      ]),
    );
    expect(
      repository.items.keys,
      isNot(contains('collection-source\u0000third')),
    );
    final scope = await repository.readLatestScope(
      'collection-source',
      ScanProducer.collection,
      'default',
    );
    expect(scope!.status, ScanScopeStatus.failed);
    expect(scope.itemCount, 2);
  });

  test(
    'collection reads the next page only after item acknowledgement',
    () async {
      final source = makeScanTestSource('collection-source');
      final pageRead = <Object?>[];
      final adapter = FakeScanAdapter(
        sourceKey: source.key,
        collectionLoader: (_, cursor, __) async {
          pageRead.add(cursor);
          return cursor == null
              ? const {
                  'items': [
                    {
                      'comicId': 'first',
                      'observation': {
                        'update': {'latestChapterId': 'ch-1'},
                      },
                    },
                  ],
                  'next': 'page-2',
                }
              : const {
                  'items': [
                    {
                      'comicId': 'second',
                      'observation': {
                        'update': {'latestChapterId': 'ch-2'},
                      },
                    },
                  ],
                  'next': null,
                };
        },
      );
      final repository = _BlockingRepository();
      final executeFuture = _execute(
        repository,
        _collectionWork(source, adapter, 'default'),
      );
      await repository.firstSaveStarted.future;
      expect(pageRead, <Object?>[null]);
      expect(repository.items, isEmpty);

      repository.releaseFirst.complete();
      final outcome = await executeFuture;
      expect(outcome.status, ScanWorkOutcomeStatus.completed);
      expect(pageRead, <Object?>[null, 'page-2']);
      expect(repository.items.length, 2);
    },
  );

  test(
    'guard cancellation after acquisition produces no canceled item',
    () async {
      final source = makeScanTestSource('comic-source');
      final adapter = _CancelAwareAdapter(source.key);
      final repository = FakeScanResultRepository();
      final work = _comicWork(source, adapter, 'comic-1');
      final executeFuture = _execute(repository, work);
      await adapter.started.future;
      work.guard.cancel(ScanControlReason.userCanceled);
      adapter.lease!.close(
        reason: ScanLeaseCloseReason.controlCanceled,
        controlReason: ScanControlReason.userCanceled,
      );

      final outcome = await executeFuture;
      expect(outcome.status, ScanWorkOutcomeStatus.canceled);
      expect(repository.items, isEmpty);
      final scope = await repository.readLatestScope(
        'comic-source',
        ScanProducer.comic,
        'comic-1',
      );
      expect(scope!.status, ScanScopeStatus.canceled);
    },
  );
}

Future<ScanWorkOutcome> _execute(
  FakeScanResultRepository repository,
  ScanWork work,
) {
  final consumer = ScanEmissionConsumer(repository: repository);
  final executor = ScanExecutor(repository: repository);
  return executor.execute(
    work,
    emit: (emission, context) => consumer.consume(emission, context),
  );
}

ScanWork _comicWork(
  ComicSource source,
  ScanSourceAdapter adapter,
  String comicId,
) => ScanWorkSpec.comic(
  source: source,
  adapter: adapter,
  comicId: comicId,
).toWork(_guard(source));

ScanWork _collectionWork(
  ComicSource source,
  ScanSourceAdapter adapter,
  String key,
) => ScanWorkSpec.collection(
  source: source,
  adapter: adapter,
  collectionKey: key,
).toWork(_guard(source));

ScanExecutionGuard _guard(ComicSource source) => ScanExecutionGuard(
  sourceKey: source.key,
  sourceInstance: source,
  cacheGeneration: 0,
);

class _BlockingRepository extends FakeScanResultRepository {
  final firstSaveStarted = Completer<void>();
  final releaseFirst = Completer<void>();
  var saveCount = 0;

  @override
  Future<ScanItemWriteResult> saveItem(
    ScanIngestionContext context,
    ScanItemResult item, {
    DateTime? committedAt,
  }) async {
    saveCount++;
    if (saveCount == 1) {
      firstSaveStarted.complete();
      await releaseFirst.future;
    }
    return super.saveItem(context, item, committedAt: committedAt);
  }
}

class _CancelAwareAdapter extends FakeScanAdapter {
  _CancelAwareAdapter(String sourceKey) : super(sourceKey: sourceKey);

  final started = Completer<void>();
  ScanCallLease? lease;

  @override
  Future<Object?> loadComic(String comicId, ScanCallLease callLease) {
    lease = callLease;
    started.complete();
    final result = Completer<Object?>();
    callLease.addCloseListener(() {
      if (!result.isCompleted) {
        result.complete(const {
          'observation': {'sourceUnread': true},
        });
      }
    });
    return result.future;
  }
}
