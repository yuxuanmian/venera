import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/follow_update_availability.dart';
import 'package:venera/headless.dart';

void main() {
  test('only the updatesubscribe headless command is intercepted', () {
    expect(unavailableHeadlessScanResult(const []), isNull);
    expect(unavailableHeadlessScanResult(const ['--headless']), isNull);
    expect(
      unavailableHeadlessScanResult(const ['--headless', 'webdav', 'up']),
      isNull,
    );
    final result = unavailableHeadlessScanResult(const [
      '--headless',
      'updatesubscribe',
    ]);
    expect(result?.exitCode, followUpdateScannerUnavailableExitCode);
    expect(result?.payload, {
      'status': 'error',
      'code': followUpdateScannerUnavailableCode,
      'message': followUpdateScannerUnavailableMessage,
    });
  });

  test('non-scanning headless and argument shapes are not intercepted', () {
    for (final args in [
      const ['--headless', 'webdav', 'up'],
      const ['--headless', 'webdav', 'down'],
      const ['--headless', 'webdav', 'other'],
      const ['--headless', 'unknown-command'],
      const ['--headless', 'unknown-command', 'updatesubscribe'],
      const ['updatesubscribe'],
      const ['--other', 'updatesubscribe'],
      const ['--headless'],
      const <String>[],
    ]) {
      expect(unavailableHeadlessScanResult(args), isNull, reason: '$args');
    }
  });

  test('valid single-comic shape has the same unavailable contract', () {
    final result = unavailableHeadlessScanResult(const [
      '--headless',
      'updatesubscribe',
      '--update-comic-by-id-type',
      'comic-1',
      'source-a',
    ]);

    expect(result?.exitCode, followUpdateScannerUnavailableExitCode);
    expect(result?.payload, {
      'status': 'error',
      'code': followUpdateScannerUnavailableCode,
      'message': followUpdateScannerUnavailableMessage,
    });
    expect(result?.payload.containsKey('data'), isFalse);
    expect(result?.payload.containsKey('updated'), isFalse);
    expect(result?.payload.containsKey('success'), isFalse);
  });

  test('missing single-comic arguments retain the old exit-one error', () {
    for (final args in [
      const ['--headless', 'updatesubscribe', '--update-comic-by-id-type'],
      const [
        '--headless',
        'updatesubscribe',
        '--update-comic-by-id-type',
        'comic-1',
      ],
    ]) {
      final result = unavailableHeadlessScanResult(args);
      expect(result?.exitCode, 1);
      expect(result?.payload, {
        'status': 'error',
        'message': 'Missing comic id or source key.',
      });
    }
  });
}
