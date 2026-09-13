import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/scan/execution_guard.dart';
import 'package:venera/foundation/scan/full_scan_planner.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_emission.dart';
import 'package:venera/foundation/scan/scan_executor.dart';
import 'package:venera/foundation/scan/scan_result_repository.dart';

import 'fakes.dart';

void main() {
  test(
    'a slow item acknowledgement blocks the next collection request',
    () async {
      final source = makeScanTestSource('barrier');
      final reads = <Object?>[];
      final adapter = FakeScanAdapter(
        sourceKey: source.key,
        collectionLoader: (_, cursor, __) async {
          reads.add(cursor);
          return cursor == null
              ? const {
                  'items': [
                    {
                      'comicId': 'first',
                      'observation': {'sourceUnread': false},
                    },
                  ],
                  'next': 'second',
                }
              : const {'items': [], 'next': null};
        },
      );
      final repository = _BlockingRepository();
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
      final execution = ScanExecutor(repository: repository).execute(
        work,
        emit: (emission, context) => consumer.consume(emission, context),
      );

      await repository.firstSaveStarted.future;
      expect(reads, [null]);
      repository.release.complete();
      final outcome = await execution;

      expect(outcome.status, ScanWorkOutcomeStatus.completed);
      expect(reads, [null, 'second']);
    },
  );
}

class _BlockingRepository extends FakeScanResultRepository {
  final firstSaveStarted = Completer<void>();
  final release = Completer<void>();
  var saves = 0;

  @override
  Future<ScanItemWriteResult> saveItem(
    ScanIngestionContext context,
    ScanItemResult item, {
    DateTime? committedAt,
  }) async {
    saves++;
    if (saves == 1) {
      firstSaveStarted.complete();
      await release.future;
    }
    return super.saveItem(context, item, committedAt: committedAt);
  }
}
