import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/scan/execution_guard.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_debug_service.dart';
import 'package:venera/foundation/scan/full_scan_planner.dart';
import 'package:venera/foundation/scan/target_provider.dart';

import 'fakes.dart';

void main() {
  test(
    'source replacement invalidates even when the source key is unchanged',
    () {
      var current = Object();
      final guard = ScanExecutionGuard(
        sourceKey: 'source',
        sourceInstance: current,
        cacheGeneration: 0,
        sourceIsCurrent: () => true,
      );
      expect(guard.isValid, isTrue);
      current = Object();
      var currentSource = current;
      final replacementGuard = ScanExecutionGuard(
        sourceKey: 'source',
        sourceInstance: currentSource,
        cacheGeneration: 0,
        sourceIsCurrent: () => identical(currentSource, current),
      );
      current = Object();
      expect(
        () => replacementGuard.check(),
        throwsA(
          isA<ScanControlException>().having(
            (error) => error.reason,
            'reason',
            ScanControlReason.sourceInvalidated,
          ),
        ),
      );
    },
  );

  test(
    'same account token refresh does not invalidate a service work',
    () async {
      final source =
          makeScanTestSource(
              'account-source',
              account: AccountConfig(
                null,
                null,
                null,
                () {},
                null,
                null,
                null,
                null,
              ),
            )
            ..data = {
              'account': ['user', 'old-secret'],
            };
      final adapter = FakeScanAdapter(
        sourceKey: source.key,
        comicLoader: (_, __) async {
          source.data['account'] = ['user', 'new-secret'];
          return const {
            'observation': {'sourceUnread': false},
          };
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
                comicId: 'comic',
              ),
            ],
            cacheGeneration: 0,
          ),
        ),
      );

      final summary = await service.startFullScan();

      expect(summary.disposition, FullScanDisposition.completed);
      expect(repository.items, hasLength(1));
    },
  );
}
