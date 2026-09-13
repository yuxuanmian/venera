import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/scan/execution_guard.dart';
import 'package:venera/foundation/scan/full_scan_planner.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_emission.dart';
import 'package:venera/foundation/scan/scan_executor.dart';

import 'fakes.dart';

void main() {
  test('collection executor treats false as a continuation cursor', () async {
    final source = makeScanTestSource('collection');
    final cursors = <Object?>[];
    final adapter = FakeScanAdapter(
      sourceKey: source.key,
      collectionLoader: (_, cursor, __) async {
        cursors.add(cursor);
        return cursor == null
            ? const {
                'items': [
                  {
                    'comicId': 'first',
                    'observation': {'sourceUnread': false},
                  },
                ],
                'next': false,
              }
            : const {'items': [], 'next': null};
      },
    );
    final repository = FakeScanResultRepository();
    final consumer = ScanEmissionConsumer(repository: repository);
    final work =
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
        );

    final outcome = await ScanExecutor(repository: repository).execute(
      work,
      emit: (emission, context) => consumer.consume(emission, context),
    );

    expect(outcome.status, ScanWorkOutcomeStatus.completed);
    expect(cursors, [null, false]);
    expect(repository.items, hasLength(1));
    expect(
      (await repository.readLatestScope(
        source.key,
        ScanProducer.collection,
        'default',
      ))!.itemCount,
      1,
    );
  });

  test(
    'collection failure envelope does not become an empty completed page',
    () async {
      final source = makeScanTestSource('collection');
      final adapter = FakeScanAdapter(
        sourceKey: source.key,
        collectionLoader: (_, __, ___) async => const {
          'failure': {'httpStatus': 503, 'message': 'upstream unavailable'},
        },
      );
      final repository = FakeScanResultRepository();
      final consumer = ScanEmissionConsumer(repository: repository);
      final work =
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
          );

      final outcome = await ScanExecutor(repository: repository).execute(
        work,
        emit: (emission, context) => consumer.consume(emission, context),
      );

      expect(outcome.status, ScanWorkOutcomeStatus.failed);
      expect(outcome.failure!.httpStatus, 503);
      expect(repository.items, isEmpty);
      expect(
        (await repository.readLatestScope(
          source.key,
          ScanProducer.collection,
          'default',
        ))!.status,
        ScanScopeStatus.failed,
      );
    },
  );
}
