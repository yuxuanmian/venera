import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/follow_update_availability.dart';

void main() {
  test('follow update scanner exposes the fixed unavailable contract', () {
    expect(followUpdateScannerAvailable, isFalse);
    expect(followUpdateScannerUnavailableCode, 'scanner_unavailable');
    expect(
      followUpdateScannerUnavailableMessage,
      'Follow update scanner is temporarily unavailable',
    );
    expect(followUpdateScannerUnavailableExitCode, 3);
  });
}
