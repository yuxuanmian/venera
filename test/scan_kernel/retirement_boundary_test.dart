import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/follow_update_availability.dart';
import 'package:venera/headless.dart';

void main() {
  test('formal follow-up and headless entry points remain unavailable', () {
    expect(followUpdateScannerAvailable, isFalse);
    final result = unavailableHeadlessScanResult([
      '--headless',
      'updatesubscribe',
    ]);
    expect(result!.exitCode, followUpdateScannerUnavailableExitCode);
    expect(result.payload['code'], followUpdateScannerUnavailableCode);
  });
}
