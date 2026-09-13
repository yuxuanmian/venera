import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/scan/execution_guard.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_call_lease.dart';
import 'package:venera/foundation/scan/js_source_adapter.dart';
import 'package:venera/foundation/scan/source_adapter.dart';

void main() {
  ScanExecutionGuard guard() => ScanExecutionGuard(
    sourceKey: 'source',
    sourceInstance: Object(),
    cacheGeneration: 0,
  );

  ScanCapabilities comicCapabilities(ScanComicLoader loader) =>
      ScanCapabilities.supported(
        primary: ScanProducer.comic,
        comic: ScanCapability.comic(loader),
      );

  test('passes the same lease to the host request and closes it', () async {
    ScanCallLease? seen;
    final adapter = JsScanSourceAdapter(
      sourceKey: 'source',
      definitionRevision: 'rev',
      capabilities: comicCapabilities((id, request) async {
        final response = await request({
          'method': 'GET',
          'url': 'https://example.invalid/$id',
        });
        expect(response['ok'], isTrue);
        return {
          'observation': {'sourceUnread': false},
        };
      }),
      requestFactory: (lease) {
        seen = lease;
        return (request) async => {'ok': true, 'response': request};
      },
    );
    final lease = ScanCallLease(guard: guard());
    final result = await adapter.loadComic('comic', lease);
    expect((result as Map)['observation'], isNotNull);
    expect(identical(seen, lease), isTrue);
    expect(lease.isClosed, isTrue);
    expect(lease.closeReason, ScanLeaseCloseReason.completed);
  });

  test('maps a host failure but preserves control cancellation', () async {
    final adapter = JsScanSourceAdapter(
      sourceKey: 'source',
      definitionRevision: 'rev',
      capabilities: comicCapabilities((id, request) async {
        await request({'method': 'GET', 'url': 'https://example.invalid'});
        return null;
      }),
      requestFactory: (lease) =>
          (request) async => throw const ScanHostRequestException(
            ScanFailure(httpStatus: 503, message: 'upstream failed'),
          ),
    );
    final lease = ScanCallLease(guard: guard());
    final result = await adapter.loadComic('comic', lease) as Map;
    expect((result['failure'] as Map)['httpStatus'], 503);
    expect(lease.isClosed, isTrue);

    final canceledGuard = guard()..cancel(ScanControlReason.userCanceled);
    final canceledLease = ScanCallLease(guard: canceledGuard);
    await expectLater(
      adapter.loadComic('comic', canceledLease),
      throwsA(isA<ScanControlException>()),
    );
  });

  test('unavailable capabilities still close the call lease', () async {
    final adapter = JsScanSourceAdapter(
      sourceKey: 'source',
      definitionRevision: 'rev',
      capabilities: const ScanCapabilities.absent(),
      requestFactory: (lease) =>
          (request) async => const {},
    );
    final lease = ScanCallLease(guard: guard());
    final result = await adapter.loadComic('comic', lease) as Map;
    expect(result['failure'], isNotNull);
    expect(lease.isClosed, isTrue);
  });
}
