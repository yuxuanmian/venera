import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tracking_fixture.dart';

void main() {
  test('loads the canonical tracking fixture version and checksum', () {
    final fixtureFile = File('test/fixtures/tracking-v1.json');
    final bytes = fixtureFile.readAsBytesSync();
    final fixture = loadTrackingFixture();

    expect(fixture['fixtureVersion'], 'tracking-v1-fixtures-2');
    expect(fixture['contractVersion'], '1.0.0');
    expect(
      sha256.convert(bytes).toString(),
      '95e75630d5d16f0e43f1d27496ea6b4924598b89a64b9f8c5eb867370757b8fd',
    );
    expect(trackingFixtureCases(fixture, 'comparisonCases'), hasLength(17));
    expect(trackingFixtureCases(fixture, 'presentationCases'), hasLength(24));
  });

  test('fixture remains valid JSON at the byte level', () {
    final decoded = jsonDecode(
      File('test/fixtures/tracking-v1.json').readAsStringSync(),
    );
    expect(decoded, isA<Map<String, dynamic>>());
  });
}
