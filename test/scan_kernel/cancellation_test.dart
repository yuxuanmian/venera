import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_debug_service.dart';
import 'package:venera/foundation/scan/scan_limits.dart';
import 'package:venera/foundation/scan/full_scan_planner.dart';
import 'package:venera/foundation/scan/target_provider.dart';

import 'fakes.dart';

void main() {
  test(
    'cancel keeps an already committed item and does not create a late item',
    () async {
      final source = makeScanTestSource('source');
      final secondStarted = Completer<void>();
      final adapter = FakeScanAdapter(
        sourceKey: source.key,
        comicLoader: (comicId, lease) {
          if (comicId == 'one') {
            return Future.value(const {
              'observation': {'sourceUnread': false},
            });
          }
          secondStarted.complete();
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
      final repository = FakeScanResultRepository();
      final service = ScanDebugService(
        repository: repository,
        targetProvider: FakeTargetProvider(
          ScanTargetSnapshot(
            works: [
              ScanWorkSpec.comic(
                source: source,
                adapter: adapter,
                comicId: 'one',
              ),
              ScanWorkSpec.comic(
                source: source,
                adapter: adapter,
                comicId: 'two',
              ),
            ],
            cacheGeneration: 0,
          ),
        ),
        limits: const ScanLimits(maxWorkers: 1, maxWorksPerSource: 1),
      );

      final running = service.startFullScan();
      await secondStarted.future;
      service.cancel();
      final summary = await running;

      expect(summary.disposition, FullScanDisposition.canceled);
      expect(repository.items.keys.toList(), ['source\u0000one']);
      expect(
        (await repository.readLatestScope(
          'source',
          ScanProducer.comic,
          'two',
        ))!.status,
        ScanScopeStatus.canceled,
      );
    },
  );
}
