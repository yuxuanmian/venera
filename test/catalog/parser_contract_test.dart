import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';

void main() {
  test('preparation helpers do not permit malformed source selections', () {
    expect(
      () => SourcePreferences.normalizeSelection(['not-valid/key']),
      throwsA(isA<Exception>()),
    );
  });
}
