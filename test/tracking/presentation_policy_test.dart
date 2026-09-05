import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tracking/comparator.dart';
import 'package:venera/foundation/tracking/presentation.dart';

import 'tracking_fixture.dart';

void main() {
  late Map<String, dynamic> fixture;

  setUpAll(() {
    fixture = loadTrackingFixture();
  });

  test('resolves the complete sticky presentation matrix', () {
    final cases = trackingFixtureCases(fixture, 'presentationCases');
    expect(cases, hasLength(24));
    for (final testCase in cases) {
      final contentChange = ContentChange.values.byName(
        testCase['contentChange'] as String,
      );
      final actual = resolveHasNewUpdate(
        previousHasNewUpdate: testCase['previousHasNewUpdate'] as bool,
        sourceUnread: testCase['sourceUnread'] as bool?,
        contentChange: contentChange,
      );
      expect(
        actual,
        testCase['expectedHasNewUpdate'],
        reason: testCase['id'] as String,
      );
    }
  });
}
