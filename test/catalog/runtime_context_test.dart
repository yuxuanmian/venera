import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/runtime_context.dart';

void main() {
  test('preparing data writes remain isolated until publish', () async {
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
    var persisted = 0;
    final context = ManagedSourceContext(
      snapshot: snapshot,
      sourceKey: 'a',
      data: {
        'x': {'n': 1},
      },
      persistData: (_) async => persisted++,
    );
    await context.writeData('x', {'n': 2});
    expect(persisted, 0);
    expect(
      () => context.requirePublished(),
      throwsA(isA<CatalogRuntimeDenied>()),
    );
    context.publish();
    expect(() => context.requirePublished(), returnsNormally);
    await context.writeData('x', {'n': 3});
    expect(persisted, 1);
    var revokedCallbacks = 0;
    final removeListener = context.addRevokeListener(() {
      revokedCallbacks++;
    });
    removeListener();
    expect(context.revokeListenerCount, 0);
    context.revoke();
    expect(revokedCallbacks, 0);
    var immediateCallbacks = 0;
    final removeImmediate = context.addRevokeListener(() {
      immediateCallbacks++;
    });
    expect(immediateCallbacks, 1);
    removeImmediate();
    expect(() => context.readData('x'), throwsStateError);
  });
}
