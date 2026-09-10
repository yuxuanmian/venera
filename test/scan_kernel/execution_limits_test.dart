import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as file_path;
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/execution_guard.dart';
import 'package:venera/foundation/scan/full_scan_planner.dart';
import 'package:venera/foundation/scan/scan_emission.dart';
import 'package:venera/foundation/scan/scan_executor.dart';
import 'package:venera/foundation/scan/scan_limits.dart';
import 'package:venera/foundation/scan/js_source_adapter.dart';
import 'package:venera/foundation/scan/source_adapter.dart';
import 'package:venera/foundation/scan/sqlite_scan_result_repository.dart';

import 'fakes.dart';

void main() {
  test('page limit fails after the committed prefix', () async {
    var calls = 0;
    final source = makeScanTestSource('limited');
    final adapter = FakeScanAdapter(
      sourceKey: source.key,
      collectionLoader: (_, __, ___) async {
        calls++;
        return const {
          'items': [
            {
              'comicId': 'first',
              'observation': {
                'update': {'latestChapterId': 'ch-1'},
              },
            },
          ],
          'next': 'second-page',
        };
      },
    );
    final repository = FakeScanResultRepository();
    final outcome = await _execute(
      repository,
      ScanWorkSpec.collection(
        source: source,
        adapter: adapter,
        collectionKey: 'default',
      ).toWork(_guard(source)),
      limits: const ScanLimits(maxPagesPerScope: 1),
    );

    expect(outcome.status, ScanWorkOutcomeStatus.failed);
    expect(outcome.failure!.exceptionType, 'ScanLimitExceeded');
    expect(outcome.persistedItems, 1);
    expect(calls, 1);
    expect(repository.items, hasLength(1));
  });

  test('item limit rejects a whole oversized page before writing', () async {
    final source = makeScanTestSource('limited');
    final adapter = FakeScanAdapter(
      sourceKey: source.key,
      collectionLoader: (_, __, ___) async => const {
        'items': [
          {
            'comicId': 'first',
            'observation': {'sourceUnread': false},
          },
          {
            'comicId': 'second',
            'observation': {'sourceUnread': true},
          },
        ],
        'next': null,
      },
    );
    final repository = FakeScanResultRepository();
    final outcome = await _execute(
      repository,
      ScanWorkSpec.collection(
        source: source,
        adapter: adapter,
        collectionKey: 'default',
      ).toWork(_guard(source)),
      limits: const ScanLimits(maxItemsPerScope: 1),
    );

    expect(outcome.status, ScanWorkOutcomeStatus.failed);
    expect(outcome.failure!.exceptionType, 'ScanLimitExceeded');
    expect(repository.items, isEmpty);
  });

  test(
    'repeated opaque cursor fails without emitting the repeated page',
    () async {
      var calls = 0;
      final source = makeScanTestSource('limited');
      final adapter = FakeScanAdapter(
        sourceKey: source.key,
        collectionLoader: (_, __, ___) async {
          calls++;
          return calls == 1
              ? const {
                  'items': [
                    {
                      'comicId': 'first',
                      'observation': {'sourceUnread': false},
                    },
                  ],
                  'next': 'same',
                }
              : const {
                  'items': [
                    {
                      'comicId': 'second',
                      'observation': {'sourceUnread': true},
                    },
                  ],
                  'next': 'same',
                };
        },
      );
      final repository = FakeScanResultRepository();
      final outcome = await _execute(
        repository,
        ScanWorkSpec.collection(
          source: source,
          adapter: adapter,
          collectionKey: 'default',
        ).toWork(_guard(source)),
      );

      expect(outcome.status, ScanWorkOutcomeStatus.failed);
      expect(outcome.failure!.exceptionType, 'ScanLimitExceeded');
      expect(calls, 2);
      expect(repository.items.keys, ['limited\u0000first']);
    },
  );

  test(
    'comic load deadline persists one timeout item and failed scope',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'venera-timeout-',
      );
      final repository = SqliteScanResultRepository(
        databasePath: file_path.join(directory.path, 'scan_results.db'),
      );
      addTearDown(() async {
        await repository.close();
        if (directory.existsSync()) await directory.delete(recursive: true);
      });
      final source = makeScanTestSource('timeout');
      final first = FakeScanAdapter(
        sourceKey: source.key,
        comicLoader: (_, __) async => const {
          'observation': {
            'update': {'latestChapterId': 'old-success'},
          },
        },
      );
      final consumer = ScanEmissionConsumer(repository: repository);
      final limits = const ScanLimits(
        jsCallTimeout: Duration(milliseconds: 10),
        requestTimeout: Duration(milliseconds: 20),
      );
      final guard = _guard(source);

      final success = await ScanExecutor(repository: repository, limits: limits)
          .execute(
            ScanWorkSpec.comic(
              source: source,
              adapter: first,
              comicId: 'comic',
            ).toWork(guard),
            emit: (emission, context) => consumer.consume(emission, context),
          );
      expect(success.status, ScanWorkOutcomeStatus.completed);

      final capabilities = ScanCapabilities.supported(
        primary: ScanProducer.comic,
        comic: ScanCapability.comic((_, __) async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return const {
            'observation': {
              'update': {'latestChapterId': 'late-success'},
            },
          };
        }),
      );
      final timeoutAdapter = JsScanSourceAdapter(
        sourceKey: source.key,
        definitionRevision: 'timeout-revision',
        capabilities: capabilities,
        limits: limits,
        requestFactory: (_) =>
            (_) async => const {
              'ok': true,
              'response': {
                'status': 200,
                'headers': <String, String>{},
                'body': '',
              },
            },
      );
      final outcome = await ScanExecutor(repository: repository, limits: limits)
          .execute(
            ScanWorkSpec.comic(
              source: source,
              adapter: timeoutAdapter,
              comicId: 'comic',
            ).toWork(_guard(source)),
            emit: (emission, context) => consumer.consume(emission, context),
          );

      expect(outcome.status, ScanWorkOutcomeStatus.failed);
      expect(outcome.persistedItems, 1);
      final stored = await repository.readLatestItem(source.key, 'comic');
      expect(stored!.result.failure!.exceptionType, 'ScanCallTimeout');
      expect(stored.result.observation, isNull);
      final scope = await repository.readLatestScope(
        source.key,
        ScanProducer.comic,
        'comic',
      );
      expect(scope!.status, ScanScopeStatus.failed);
      expect(scope.failure, stored.result.failure);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      final reread = await repository.readLatestItem(source.key, 'comic');
      expect(reread!.result.failure!.exceptionType, 'ScanCallTimeout');
      expect(reread.result.observation, isNull);
      expect(timeoutAdapter.capabilities.isSupported, isTrue);
    },
  );
}

ScanExecutionGuard _guard(Object source) => ScanExecutionGuard(
  sourceKey: 'limited',
  sourceInstance: source,
  cacheGeneration: 0,
);

Future<ScanWorkOutcome> _execute(
  FakeScanResultRepository repository,
  ScanWork work, {
  ScanLimits limits = const ScanLimits(),
}) {
  final consumer = ScanEmissionConsumer(repository: repository);
  return ScanExecutor(repository: repository, limits: limits).execute(
    work,
    emit: (emission, context) => consumer.consume(emission, context),
  );
}
