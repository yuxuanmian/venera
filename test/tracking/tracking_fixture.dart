import 'dart:convert';
import 'dart:io';

/// Loads the canonical cross-runtime tracking fixture from this repository.
///
/// The fixture is deliberately read from the test checkout instead of being
/// embedded in Dart so the checksum test can prove that the App copy is byte
/// identical to the contract copy.
Map<String, dynamic> loadTrackingFixture() {
  final file = File('test/fixtures/tracking-v1.json');
  if (!file.existsSync()) {
    throw StateError('Missing canonical tracking fixture: ${file.path}');
  }
  final decoded = jsonDecode(file.readAsStringSync()) as Map<dynamic, dynamic>;
  return Map<String, dynamic>.from(decoded);
}

List<Map<String, dynamic>> trackingFixtureCases(
  Map<String, dynamic> fixture,
  String key,
) {
  final value = fixture[key];
  if (value is! List) {
    throw StateError('Tracking fixture field $key must be an array');
  }
  return value
      .map((item) => Map<String, dynamic>.from(item as Map<dynamic, dynamic>))
      .toList(growable: false);
}
