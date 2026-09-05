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

    expect(fixture['fixtureVersion'], 'tracking-v1-fixtures-1');
    expect(fixture['contractVersion'], '1.0.0');
    expect(
      sha256.convert(bytes).toString(),
      '4cd03455994582d6c400fc8b32e8c6721869680a50b66644a176919086fc4db8',
    );
    expect(trackingFixtureCases(fixture, 'comparisonCases'), hasLength(20));
    expect(trackingFixtureCases(fixture, 'presentationCases'), hasLength(24));
  });

  test('fixture remains valid JSON at the byte level', () {
    final decoded = jsonDecode(
      File('test/fixtures/tracking-v1.json').readAsStringSync(),
    );
    expect(decoded, isA<Map<String, dynamic>>());
  });
}
