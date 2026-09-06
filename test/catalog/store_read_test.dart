import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/store.dart';

void main() {
  final pointer = CatalogPointer(
    catalogId: 'yuxuanmian/venera-configs',
    revision: 'a' * 40,
    indexUrl:
        'https://raw.githubusercontent.com/yuxuanmian/venera-configs/${'a' * 40}/index.json',
  );
  final indexBytes = utf8.encode(
    '[{"name":"A","key":"A","fileName":"a.js","version":"1"}]',
  );

  test('promotes and verifies a complete snapshot', () async {
    final dir = await Directory.systemTemp.createTemp('catalog-store-');
    addTearDown(() => dir.delete(recursive: true));
    final store = CatalogStore(dir);
    final index = CatalogIndex.fromBytes(indexBytes);
    final candidate = await store.createCandidate(
      pointer: pointer,
      indexBytes: indexBytes,
      index: index,
      attemptId: 'attempt-a',
    );
    await store.writeCandidateSource(
      candidate,
      index.entries.single,
      utf8.encode('source'),
    );
    final complete = await store.finalizeCandidate(candidate);
    final snapshot = await store.promoteCandidate(complete);
    expect((await store.readSnapshot(pointer))?.index.entries.single.key, 'A');
    expect(
      snapshot.manifest.files.single.sha256,
      sha256Hex(utf8.encode('source')),
    );
  });

  test('rejects a locally modified source instead of re-hashing it', () async {
    final dir = await Directory.systemTemp.createTemp('catalog-store-');
    addTearDown(() => dir.delete(recursive: true));
    final store = CatalogStore(dir);
    final index = CatalogIndex.fromBytes(indexBytes);
    final candidate = await store.createCandidate(
      pointer: pointer,
      indexBytes: indexBytes,
      index: index,
      attemptId: 'attempt-b',
    );
    await store.writeCandidateSource(
      candidate,
      index.entries.single,
      utf8.encode('source'),
    );
    final complete = await store.finalizeCandidate(candidate);
    await store.promoteCandidate(complete);
    await File(
      '${store.snapshotDirectory(pointer).path}/sources/a.js',
    ).writeAsString('tampered');
    expect(
      () => store.readSnapshot(pointer),
      throwsA(isA<CatalogStorageException>()),
    );
  });
}
