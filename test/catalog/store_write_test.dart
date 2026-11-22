import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/store.dart';

void main() {
  test(
    'verified catalog minimum can be recorded on a legacy snapshot',
    () async {
      final dir = await Directory.systemTemp.createTemp('catalog-store-');
      addTearDown(() => dir.delete(recursive: true));
      final pointer = CatalogRepositorySource.defaults.pointerForRevision(
        'a' * 40,
      );
      final store = CatalogStore(dir);
      final candidate = await store.createCandidate(
        pointer: pointer,
        indexBytes: const [91, 93],
        index: CatalogIndex.fromJson([]),
      );
      final snapshot = await store.promoteCandidate(
        await store.finalizeCandidate(candidate),
      );
      expect(snapshot.manifest.minAppVersion, isNull);
      final updated = await store.recordMinimumAppVersion(
        snapshot,
        '2.0.0-beta.8',
        replaceAtomically: (source, target) async {
          await source.rename(target.path);
        },
      );
      final reopened = await store.readSnapshot(pointer);
      expect(updated.manifest.minAppVersion, '2.0.0-beta.8');
      expect(reopened?.manifest.minAppVersion, '2.0.0-beta.8');
      expect(reopened?.manifest.indexSha256, snapshot.manifest.indexSha256);
    },
  );

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
