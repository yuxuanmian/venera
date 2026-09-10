import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_debug_service.dart';
import 'package:venera/foundation/scan/scan_limits.dart';
import 'package:venera/foundation/scan/scan_result_repository.dart';
import 'package:venera/foundation/scan/full_scan_planner.dart';
import 'package:venera/foundation/scan/target_provider.dart';

import 'fakes.dart';

void main() {
  test(
    'runs a frozen target snapshot through one persistent consumer',
    () async {
      final source = makeScanTestSource('source');
      final adapter = FakeScanAdapter(
        sourceKey: source.key,
        comicLoader: (comicId, _) async => comicId == 'bad'
            ? const {
                'failure': {'httpStatus': 403},
              }
            : const {
                'observation': {
                  'update': {'latestChapterId': 'chapter-1'},
                },
              },
      );
      final provider = FakeTargetProvider(
        ScanTargetSnapshot(
          works: [
            ScanWorkSpec.comic(
              source: source,
              adapter: adapter,
              comicId: 'bad',
            ),
            ScanWorkSpec.comic(
              source: source,
              adapter: adapter,
              comicId: 'good',
            ),
          ],
          cacheGeneration: 0,
        ),
      );
      final repository = FakeScanResultRepository();
      final service = ScanDebugService(
        repository: repository,
        targetProvider: provider,
        limits: const ScanLimits(maxWorkers: 2, maxWorksPerSource: 1),
      );

      final summary = await service.startFullScan();

      expect(summary.disposition, FullScanDisposition.completed);
      expect(summary.progress.discoveredWorks, 2);
      expect(summary.progress.succeededWorks, 1);
      expect(summary.progress.failedWorks, 1);
      expect(summary.progress.persistedItems, 2);
      expect(summary.progress.activeWorks, 0);
      expect(service.isRunning, isFalse);
      expect(adapter.comicLeases, hasLength(2));
      expect(adapter.comicLeases.every((lease) => lease.isClosed), isTrue);
      expect(
        repository.items.keys,
        containsAll(<String>['source\u0000bad', 'source\u0000good']),
      );
    },
  );

  test(
    'rejects re-entry and cancellation preserves only committed work',
    () async {
      final source = makeScanTestSource('source');
      final started = Completer<void>();
      final adapter = FakeScanAdapter(
        sourceKey: source.key,
        comicLoader: (_, lease) {
          started.complete();
          final result = Completer<Object?>();
          lease.addCloseListener(() {
            if (!result.isCompleted) {
              result.complete(const {
                'observation': {
                  'update': {'latestChapterId': 'late'},
                },
              });
            }
          });
          return result.future;
        },
      );
      final provider = FakeTargetProvider(
        ScanTargetSnapshot(
          works: [
            ScanWorkSpec.comic(
              source: source,
              adapter: adapter,
              comicId: 'one',
            ),
          ],
          cacheGeneration: 0,
        ),
      );
      final repository = FakeScanResultRepository();
      final service = ScanDebugService(
        repository: repository,
        targetProvider: provider,
      );

      final running = service.startFullScan();
      await started.future;
      final reentry = await service.startFullScan();
      expect(reentry.disposition, FullScanDisposition.alreadyRunning);

      service.cancel();
      final canceled = await running;
      expect(canceled.disposition, FullScanDisposition.canceled);
      expect(repository.items, isEmpty);
      expect(
        (await repository.readLatestScope(
          'source',
          ScanProducer.comic,
          'one',
        ))!.status,
        ScanScopeStatus.canceled,
      );
      expect(service.isRunning, isFalse);
    },
  );

  test('a storage error stops the run and reports failure', () async {
    final source = makeScanTestSource('source');
    final adapter = FakeScanAdapter(sourceKey: source.key);
    final provider = FakeTargetProvider(
      ScanTargetSnapshot(
        works: [
          ScanWorkSpec.comic(source: source, adapter: adapter, comicId: 'one'),
        ],
        cacheGeneration: 0,
      ),
    );
    final service = ScanDebugService(
      repository: _StorageFailingRepository(),
      targetProvider: provider,
    );

    final summary = await service.startFullScan();

    expect(summary.disposition, FullScanDisposition.failed);
    expect(summary.errorMessage, contains('synthetic storage fault'));
    expect(summary.progress.persistedItems, 0);
    expect(service.isRunning, isFalse);
  });

  test(
    'queued work rejects an account changed after snapshot capture',
    () async {
      final source = makeScanTestSource('snapshot-account')
        ..data = <String, dynamic>{
          'account': ['new-account', 'new-secret'],
        };
      final adapter = FakeScanAdapter(
        sourceKey: source.key,
        comicLoader: (_, __) async => const {
          'observation': {'sourceUnread': false},
        },
      );
      final provider = FakeTargetProvider(
        ScanTargetSnapshot(
          works: [
            ScanWorkSpec.comic(
              source: source,
              adapter: adapter,
              comicId: 'comic',
              sourceSnapshot: ScanSourceSnapshot(
                managed: false,
                accountIdentity: ['old-account'],
              ),
            ),
          ],
          cacheGeneration: 0,
        ),
      );
      final repository = FakeScanResultRepository();
      final summary = await ScanDebugService(
        repository: repository,
        targetProvider: provider,
      ).startFullScan();

      expect(summary.disposition, FullScanDisposition.completed);
      expect(summary.progress.canceledWorks, 1);
      expect(adapter.comicLeases, isEmpty);
      expect(repository.items, isEmpty);
    },
  );

  test('managed source removal rejects a frozen queued work', () async {
    final source = makeScanTestSource('snapshot-managed');
    final replacement = makeScanTestSource('snapshot-managed');
    final manager = ComicSourceManager();
    manager.add(source);
    addTearDown(() => manager.remove(replacement.key));
    final adapter = FakeScanAdapter(sourceKey: source.key);
    final provider = FakeTargetProvider(
      ScanTargetSnapshot(
        works: [
          ScanWorkSpec.comic(
            source: source,
            adapter: adapter,
            comicId: 'comic',
            sourceSnapshot: ScanSourceSnapshot(managed: true),
          ),
        ],
        cacheGeneration: 0,
      ),
    );
    manager.remove(source.key);
    manager.add(replacement);

    final repository = FakeScanResultRepository();
    final summary = await ScanDebugService(
      repository: repository,
      targetProvider: provider,
    ).startFullScan();

    expect(summary.progress.canceledWorks, 1);
    expect(adapter.comicLeases, isEmpty);
    expect(repository.items, isEmpty);
  });
}

class _StorageFailingRepository extends FakeScanResultRepository {
  @override
  Future<ScanItemWriteResult> saveItem(
    ScanIngestionContext context,
    ScanItemResult item, {
    DateTime? committedAt,
  }) {
    throw const ScanStorageException('synthetic storage fault');
  }
}
