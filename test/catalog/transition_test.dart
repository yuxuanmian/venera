import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';

void main() {
  test('new sources are never automatically enabled', () {
    final old = CatalogIndex.fromJson([
      {'name': 'A', 'key': 'a', 'fileName': 'a.js', 'version': '1'},
    ]);
    final next = CatalogIndex.fromJson([
      {'name': 'A', 'key': 'a', 'fileName': 'a.js', 'version': '1'},
      {'name': 'B', 'key': 'b', 'fileName': 'b.js', 'version': '1'},
    ]);
    expect(
      SourcePreferences.afterCatalogTransition(
        enabled: ['a'],
        oldIndex: old,
        newIndex: next,
        isAuthorityTransition: true,
      ),
      ['a'],
    );
  });
}
