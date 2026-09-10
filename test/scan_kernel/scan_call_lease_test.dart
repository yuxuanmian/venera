import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/scan/execution_guard.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_call_lease.dart';

void main() {
  ScanExecutionGuard guard() => ScanExecutionGuard(
    sourceKey: 'source',
    sourceInstance: Object(),
    cacheGeneration: 0,
  );

  test('closes idempotently and cancels every registered request', () {
    final lease = ScanCallLease(guard: guard());
    final request = CancelToken();
    expect(lease.registerRequest(request), isTrue);
    lease.close(
      reason: ScanLeaseCloseReason.controlCanceled,
      controlReason: ScanControlReason.userCanceled,
    );
    expect(request.isCancelled, isTrue);
    expect(lease.cancelToken.isCancelled, isTrue);
    expect(lease.isControlCanceled, isTrue);
    lease.close(reason: ScanLeaseCloseReason.deadline);
    expect(lease.closeReason, ScanLeaseCloseReason.controlCanceled);
    expect(() => lease.checkOpen(), throwsA(isA<ScanControlException>()));
  });

  test('deadline is distinct from control cancellation', () async {
    final lease = ScanCallLease(
      guard: guard(),
      timeout: const Duration(milliseconds: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(lease.isDeadline, isTrue);
    expect(
      () => lease.checkOpen(),
      throwsA(
        isA<ScanLeaseException>().having(
          (error) => error.reason,
          'reason',
          ScanLeaseCloseReason.deadline,
        ),
      ),
    );
  });

  test('guard reports source, cache, and account invalidation distinctly', () {
    var current = true;
    var generation = 0;
    var account = <String>['user'];
    final guard = ScanExecutionGuard(
      sourceKey: 'source',
      sourceInstance: Object(),
      accountSnapshot: const ['user'],
      cacheGeneration: 0,
      sourceIsCurrent: () => current,
      currentCacheGeneration: () => generation,
      currentAccount: () => account,
    );
    current = false;
    expect(() => guard.check(), throwsA(isA<ScanControlException>()));

    current = true;
    generation = 1;
    expect(
      () => guard.check(),
      throwsA(
        isA<ScanControlException>().having(
          (error) => error.reason,
          'reason',
          ScanControlReason.cacheInvalidated,
        ),
      ),
    );

    generation = 0;
    account = ['other'];
    expect(
      () => guard.check(),
      throwsA(
        isA<ScanControlException>().having(
          (error) => error.reason,
          'reason',
          ScanControlReason.accountChanged,
        ),
      ),
    );
  });
}
