import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/models.dart';

void main() {
  test('Catalog identity is pinned to the immutable revision and index URL',
      () {
    final pointer = CatalogPointer(
      catalogId: 'owner/repo',
      revision: 'a' * 40,
      indexUrl:
          'https://raw.githubusercontent.com/owner/repo/${'a' * 40}/index.json',
    );
    expect(CatalogPointer.fromJson(jsonDecode(jsonEncode(pointer.toJson()))),
        pointer);
    expect(
      () => CatalogPointer(
        catalogId: 'owner/repo',
        revision: 'short',
        indexUrl:
            'https://raw.githubusercontent.com/owner/repo/short/index.json',
      ).validate(),
      throwsA(isA<CatalogFormatException>()),
    );
  });

  test('Catalog index rejects duplicate keys and case-insensitive filenames',
      () {
    expect(
      () => CatalogIndex.fromJson([
        {'name': 'A', 'key': 'same', 'fileName': 'a.js', 'version': '1'},
        {'name': 'B', 'key': 'same', 'fileName': 'b.js', 'version': '1'},
      ]),
      throwsA(isA<CatalogFormatException>()),
    );
    expect(
      () => CatalogIndex.fromJson([
        {'name': 'A', 'key': 'a', 'fileName': 'Source.js', 'version': '1'},
        {'name': 'B', 'key': 'b', 'fileName': 'source.JS', 'version': '1'},
      ]),
      throwsA(isA<CatalogFormatException>()),
    );
  });
}
