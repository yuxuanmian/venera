import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/image.dart';

void main() {
  group('isLikelyImageBytes', () {
    test('accepts common image magic numbers', () {
      expect(
        isLikelyImageBytes(
          Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0]),
        ),
        isTrue,
        reason: 'JPEG',
      );
      expect(
        isLikelyImageBytes(
          Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        ),
        isTrue,
        reason: 'PNG',
      );
      expect(
        isLikelyImageBytes(
          Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0, 0]),
        ),
        isTrue,
        reason: 'GIF',
      );
      expect(
        isLikelyImageBytes(
          Uint8List.fromList([
            0x52,
            0x49,
            0x46,
            0x46,
            0,
            0,
            0,
            0,
            0x57,
            0x45,
            0x42,
            0x50,
          ]),
        ),
        isTrue,
        reason: 'WebP',
      );
      expect(
        isLikelyImageBytes(
          Uint8List.fromList([
            0,
            0,
            0,
            0,
            0x66,
            0x74,
            0x79,
            0x70,
            0x61,
            0x76,
            0x69,
            0x66,
          ]),
        ),
        isTrue,
        reason: 'AVIF',
      );
    });

    test('rejects HTML and JSON error pages', () {
      final html = Uint8List.fromList(
        '<html><head><title>403 Forbidden</title></head><body>blocked</body></html>'
            .codeUnits,
      );
      expect(isLikelyImageBytes(html), isFalse);

      final json = Uint8List.fromList(
        '{"error":"hotlink protection","code":403}'.codeUnits,
      );
      expect(isLikelyImageBytes(json), isFalse);
    });

    test('rejects empty and too-short data', () {
      expect(isLikelyImageBytes(Uint8List(0)), isFalse);
      expect(isLikelyImageBytes(Uint8List.fromList([1, 2, 3])), isFalse);
    });

    test('treats unknown binary content as an image', () {
      // A binary blob with no known magic must not be rejected: the check is
      // permissive by design to avoid false positives.
      final binary = Uint8List.fromList(
        List.generate(64, (i) => i % 3 == 0 ? 0x00 : 0xA0 + (i % 16)),
      );
      expect(isLikelyImageBytes(binary), isTrue);
    });
  });
}
