import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/store.dart';

void main() {
  test('candidate cannot be finalized without every declared file', () async {
    final dir = await Directory.systemTemp.createTemp('catalog-store-');
    addTearDown(() => dir.delete(recursive: true));
    final pointer = CatalogPointer(
      catalogId: 'owner/repo',
      revision: 'b' * 40,
      indexUrl:
          'https://raw.githubusercontent.com/owner/repo/${'b' * 40}/index.json',
    );
    final index = CatalogIndex.fromJson([
      {'name': 'A', 'key': 'A', 'fileName': 'a.js', 'version': '1'},
    ]);
    final candidate = await CatalogStore(dir).createCandidate(
      pointer: pointer,
      indexBytes: const [91, 93],
      index: index,
      attemptId: 'missing',
    );
    expect(
      () => CatalogStore(dir).finalizeCandidate(candidate),
      throwsA(isA<CatalogStorageException>()),
    );
  });
}
