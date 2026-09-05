import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tracking/comparator.dart';
import 'package:venera/foundation/tracking/update_state.dart';

import 'tracking_fixture.dart';

UpdateState? _state(Object? value) {
  if (value is! Map) return null;
  return UpdateState.fromJson(Map<String, dynamic>.from(value));
}

void main() {
  late Map<String, dynamic> fixture;

  setUpAll(() {
    fixture = loadTrackingFixture();
  });

  test('normalizes every canonical UpdateState fixture independently', () {
    for (final testCase in trackingFixtureCases(
      fixture,
      'normalizationCases',
    )) {
      final actual = UpdateState.fromJson(testCase['input'] as Map);
      final expected = Map<String, dynamic>.from(testCase['expected'] as Map);
      expect(actual?.toJson() ?? const {}, expected, reason: testCase['id']);
      if (testCase.containsKey('usable')) {
        expect(
          actual?.isUsable ?? false,
          testCase['usable'],
          reason: testCase['id'],
        );
      }
    }
  });

  test('selects the strongest common evidence for every fixture', () {
    for (final testCase in trackingFixtureCases(fixture, 'comparisonCases')) {
      final previous = Map<String, dynamic>.from(testCase['previous'] as Map);
      final current = Map<String, dynamic>.from(testCase['current'] as Map);
      final previousState = _state(previous['state']);
      final currentState = _state(current['state']);
      final decision = compareTrackingEvidence(
        previousState: previousState,
        previousMarker: previous['marker'] as String?,
        currentState: currentState,
        currentMarker: current['marker'] as String?,
      );
      final expected = Map<String, dynamic>.from(testCase['expected'] as Map);
      expect(
        decision.contentChange.name,
        expected['contentChange'],
        reason: testCase['id'],
      );
      expect(
        decision.selectedEvidence?.name,
        expected['selectedEvidence'],
        reason: testCase['id'],
      );
      expect(decision.reason, expected['reason'], reason: testCase['id']);
    }
  });
}
