import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';

void main() {
  test('aggregate consumers can derive one effective source set', () {
    final index = CatalogIndex.fromJson([
      {'name': 'A', 'key': 'alpha', 'fileName': 'a.js', 'version': '1.0.0'},
      {'name': 'B', 'key': 'Beta', 'fileName': 'b.js', 'version': '1.0.0'},
    ]);
    final preferences = SourcePreferences(initial: ['Beta', 'missing']);

    expect(preferences.effectiveKeys(index), {'Beta'});
    expect(index.keys, {'alpha', 'Beta'});
  });
}
