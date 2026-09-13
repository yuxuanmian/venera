import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/source_adapter.dart';

void main() {
  test('distinguishes absent, invalid, and supported capabilities', () {
    const absent = ScanCapabilities.absent();
    const invalid = ScanCapabilities.invalid('bad declaration');
    final supported = ScanCapabilities.supported(
      primary: ScanProducer.comic,
      comic: ScanCapability.comic(
        (id, request) async => {
          'observation': {'sourceUnread': false},
        },
      ),
    );

    expect(absent.state, ScanCapabilitiesState.absent);
    expect(absent.isSupported, isFalse);
    expect(invalid.state, ScanCapabilitiesState.invalid);
    expect(invalid.reason, 'bad declaration');
    expect(supported.isSupported, isTrue);
    expect(supported.selected!.producer, ScanProducer.comic);
  });

  test(
    'validates host requests to only GET/POST HTTP(S) without credentials',
    () {
      expect(
        ScanHttpRequest.fromJson({
          'method': 'get',
          'url': 'https://example.invalid/a',
        }).method,
        'GET',
      );
      expect(
        () => ScanHttpRequest.fromJson({
          'method': 'DELETE',
          'url': 'https://example.invalid/a',
        }),
        throwsFormatException,
      );
      expect(
        () => ScanHttpRequest.fromJson({
          'method': 'GET',
          'url': 'https://user:pass@example.invalid/a',
        }),
        throwsFormatException,
      );
    },
  );
}
