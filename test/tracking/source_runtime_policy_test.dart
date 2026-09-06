import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/runtime_context.dart';

void main() {
  test('managed source context is isolated until publish and revocable',
      () async {
    final snapshot = CatalogSnapshot(
      manifest: CatalogSnapshotManifest(
        pointer: CatalogPointer(
          catalogId: 'owner/repo',
          revision: 'a' * 40,
          indexUrl:
              'https://raw.githubusercontent.com/owner/repo/${'a' * 40}/index.json',
        ),
        indexSha256: '0' * 64,
        files: const [],
      ),
      indexBytes: const [],
      index: CatalogIndex.fromJson([]),
      rootPath: Directory.systemTemp.path,
    );
    var writes = 0;
    final context = ManagedSourceContext(
      snapshot: snapshot,
      sourceKey: 'managed',
      persistData: (_) async => writes++,
    );

    await context.writeData('value', 1);
    expect(writes, 0);
    context.publish();
    await context.writeData('value', 2);
    expect(writes, 1);
    context.revoke();
    expect(() => managedRuntimeBridge.require(context),
        throwsA(isA<CatalogRuntimeDenied>()));
  });
}
