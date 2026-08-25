import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/follow_update_marker.dart';

void main() {
  test('keeps the existing v2 marker bytes unchanged', () {
    expect(
      encodeFollowUpdateMarker('v2', 'time:2026|chapters:3'),
      'v2|time:2026|chapters:3',
    );
  });

  test('encodes and decodes only the first marker separator', () {
    final encoded = encodeFollowUpdateMarker('manwa-list-time-v1', 'a|b');
    expect(encoded, 'manwa-list-time-v1|a|b');
    final decoded = decodeFollowUpdateMarker(encoded);
    expect(decoded.scheme, 'manwa-list-time-v1');
    expect(decoded.value, 'a|b');
  });

  test('legacy values without a valid scheme remain whole v1 markers', () {
    final decoded = decodeFollowUpdateMarker('time:2026-08-03|chapters:12');
    expect(decoded.scheme, 'v1');
    expect(decoded.value, 'time:2026-08-03|chapters:12');
    expect(
      hasSameSchemeMarkerChanged(
        'time:2026-08-03|chapters:12',
        'time:2026-08-03|chapters:13',
      ),
      isTrue,
    );
  });

  test(
    'empty baselines and scheme changes do not report a same-scheme change',
    () {
      expect(hasSameSchemeMarkerChanged(null, 'v2|new'), isFalse);
      expect(hasSameSchemeMarkerChanged('', 'v2|new'), isFalse);
      expect(hasSameSchemeMarkerChanged('v1|old', 'v2|new'), isFalse);
      expect(hasSameSchemeMarkerChanged('v2|old', 'v2|new'), isTrue);
    },
  );
}
