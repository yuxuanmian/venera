import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as file_path;
import 'package:venera/foundation/scan/execution_guard.dart';
import 'package:venera/foundation/scan/full_scan_planner.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_emission.dart';
import 'package:venera/foundation/scan/scan_executor.dart';
import 'package:venera/foundation/scan/sqlite_scan_result_repository.dart';

import 'fakes.dart';

void main() {
  test('multi-page collection commits each remote item into SQLite', () async {
    final directory = await Directory.systemTemp.createTemp(
      'venera-collection-',
    );
    final repository = SqliteScanResultRepository(
      databasePath: file_path.join(directory.path, 'scan_results.db'),
    );
    addTearDown(() async {
      await repository.close();
      if (directory.existsSync()) await directory.delete(recursive: true);
    });
    final source = makeScanTestSource('manwa');
    final adapter = FakeScanAdapter(
      sourceKey: source.key,
      collectionLoader: (_, cursor, __) async => cursor == null
          ? const {
              'items': [
                {
                  'comicId': 'remote-1',
                  'observation': {
                    'update': {'latestChapterId': 'chapter-1'},
                  },
                },
              ],
              'next': 'page-2',
            }
          : const {
              'items': [
                {
                  'comicId': 'remote-2',
                  'observation': {'sourceUnread': false},
                },
              ],
              'next': null,
            },
    );
    final guard = ScanExecutionGuard(
      sourceKey: source.key,
      sourceInstance: source,
      cacheGeneration: 0,
    );
    final consumer = ScanEmissionConsumer(repository: repository);

    final outcome = await ScanExecutor(repository: repository).execute(
      ScanWorkSpec.collection(
        source: source,
        adapter: adapter,
        collectionKey: 'default',
      ).toWork(guard),
      emit: (emission, context) => consumer.consume(emission, context),
    );

    expect(outcome.status, ScanWorkOutcomeStatus.completed);
    expect(await repository.readLatestItem('manwa', 'remote-1'), isNotNull);
    expect(await repository.readLatestItem('manwa', 'remote-2'), isNotNull);
    final scope = await repository.readLatestScope(
      'manwa',
      ScanProducer.collection,
      'default',
    );
    expect(scope!.status, ScanScopeStatus.completed);
    expect(scope.itemCount, 2);
  });

  test('a later page failure preserves the committed prefix only', () async {
    final directory = await Directory.systemTemp.createTemp(
      'venera-collection-',
    );
    final repository = SqliteScanResultRepository(
      databasePath: file_path.join(directory.path, 'scan_results.db'),
    );
    addTearDown(() async {
      await repository.close();
      if (directory.existsSync()) await directory.delete(recursive: true);
    });
    final source = makeScanTestSource('manwa');
    final adapter = FakeScanAdapter(
      sourceKey: source.key,
      collectionLoader: (_, cursor, __) async => cursor == null
          ? const {
              'items': [
                {
                  'comicId': 'remote-1',
                  'observation': {'sourceUnread': true},
                },
              ],
              'next': 'page-2',
            }
          : const {
              'failure': {'httpStatus': 403, 'message': 'denied'},
            },
    );
    final consumer = ScanEmissionConsumer(repository: repository);
    final outcome = await ScanExecutor(repository: repository).execute(
      ScanWorkSpec.collection(
        source: source,
        adapter: adapter,
        collectionKey: 'default',
      ).toWork(
        ScanExecutionGuard(
          sourceKey: source.key,
          sourceInstance: source,
          cacheGeneration: 0,
        ),
      ),
      emit: (emission, context) => consumer.consume(emission, context),
    );

    expect(outcome.status, ScanWorkOutcomeStatus.failed);
    expect(await repository.readLatestItem('manwa', 'remote-1'), isNotNull);
    expect(await repository.readLatestItem('manwa', 'remote-2'), isNull);
    final scope = await repository.readLatestScope(
      'manwa',
      ScanProducer.collection,
      'default',
    );
    expect(scope!.status, ScanScopeStatus.failed);
    expect(scope.itemCount, 1);
  });
}
