import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';

void main() {
  final index = CatalogIndex.fromJson([
    {'name': 'K', 'key': 'Komiic', 'fileName': 'k.js', 'version': '1'},
    {'name': 'A', 'key': 'example_source', 'fileName': 'a.js', 'version': '1'},
  ]);

  test('null, empty, case and unknown selections retain their meaning', () {
    expect(SourcePreferences.normalizeSelection(null), isNull);
    expect(SourcePreferences.normalizeSelection([]), isEmpty);
    expect(SourcePreferences.normalizeSelection(['Komiic', 'Komiic']), [
      'Komiic',
    ]);
    expect(
      SourcePreferences(initial: ['unknown']).effectiveKeys(index),
      isEmpty,
    );
  });

  test('authority removal is the only transition that prunes old keys', () {
    final old = index;
    final next = CatalogIndex.fromJson([
      {'name': 'K', 'key': 'Komiic', 'fileName': 'k.js', 'version': '1'},
    ]);
    expect(
      SourcePreferences.afterCatalogTransition(
        enabled: ['Komiic', 'example_source'],
        oldIndex: old,
        newIndex: next,
        isAuthorityTransition: true,
      ),
      ['Komiic'],
    );
    expect(
      SourcePreferences.afterCatalogTransition(
        enabled: ['Komiic', 'example_source'],
        oldIndex: old,
        newIndex: next,
        isAuthorityTransition: false,
      ),
      ['Komiic', 'example_source'],
    );
  });

  test('an explicit empty selection survives unrelated settings changes', () {
    final preferences = SourcePreferences(initial: []);
    addTearDown(preferences.dispose);
    final previous = appdata.settings['readerMode'];
    addTearDown(() => appdata.settings['readerMode'] = previous);
    appdata.settings['readerMode'] = 'galleryRightToLeft';
    expect(preferences.enabledSources, isEmpty);
  });

  test('an invalid replacement keeps the previous valid selection', () async {
    final writes = <List<String>?>[];
    final preferences = SourcePreferences(
      initial: ['Komiic'],
      writer: (value) async => writes.add(value),
    );
    addTearDown(preferences.dispose);

    await preferences.replace(['not a valid key']);

    expect(preferences.enabledSources, ['Komiic']);
    expect(writes, isEmpty);
  });
}
