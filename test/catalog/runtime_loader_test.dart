import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/runtime_context.dart';
import 'package:venera/foundation/catalog/runtime_loader.dart';
import 'package:venera/foundation/catalog/store.dart';

void main() {
  test('a failed source preparation disposes every earlier context', () async {
    final dir = await Directory.systemTemp.createTemp('catalog-loader-');
    addTearDown(() => dir.delete(recursive: true));
    final pointer = CatalogPointer(
      catalogId: 'owner/repo',
      revision: 'a' * 40,
      indexUrl:
          'https://raw.githubusercontent.com/owner/repo/${'a' * 40}/index.json',
    );
    final index = CatalogIndex.fromJson([
      {'name': 'A', 'key': 'a', 'fileName': 'a.js', 'version': '1'},
      {'name': 'B', 'key': 'b', 'fileName': 'b.js', 'version': '1'},
    ]);
    final store = CatalogStore(dir);
    final candidate = await store.createCandidate(
      pointer: pointer,
      indexBytes: utf8.encode(jsonEncode(index.toJson())),
      index: index,
      attemptId: 'load',
    );
    for (final entry in index.entries) {
      await store.writeCandidateSource(
        candidate,
        entry,
        utf8.encode(entry.key),
      );
    }
    final snapshot = await store.promoteCandidate(
      await store.finalizeCandidate(candidate),
    );
    ManagedSourceContext? first;
    final loader = CatalogRuntimeLoader(
      factory: (entry, source, context) {
        first ??= context;
        if (entry.key == 'b') throw StateError('bad source');
        return source;
      },
    );
    await expectLater(loader.prepare(snapshot), throwsStateError);
    expect(first?.phase, ManagedSourcePhase.revoked);
  });

  test('a factory failure revokes the current context as well', () async {
    final dir = await Directory.systemTemp.createTemp(
      'catalog-loader-current-',
    );
    addTearDown(() => dir.delete(recursive: true));
    final pointer = CatalogPointer(
      catalogId: 'owner/repo',
      revision: 'b' * 40,
      indexUrl:
          'https://raw.githubusercontent.com/owner/repo/${'b' * 40}/index.json',
    );
    final index = CatalogIndex.fromJson([
      {'name': 'A', 'key': 'a', 'fileName': 'a.js', 'version': '1'},
      {'name': 'B', 'key': 'b', 'fileName': 'b.js', 'version': '1'},
    ]);
    final store = CatalogStore(dir);
    final candidate = await store.createCandidate(
      pointer: pointer,
      indexBytes: utf8.encode(jsonEncode(index.toJson())),
      index: index,
      attemptId: 'current',
    );
    for (final entry in index.entries) {
      await store.writeCandidateSource(
        candidate,
        entry,
        utf8.encode(entry.key),
      );
    }
    final snapshot = await store.promoteCandidate(
      await store.finalizeCandidate(candidate),
    );
    ManagedSourceContext? current;
    final loader = CatalogRuntimeLoader(
      factory: (entry, source, context) {
        if (entry.key == 'b') {
          current = context;
          throw StateError('current source failed');
        }
        return source;
      },
    );

    await expectLater(loader.prepare(snapshot), throwsStateError);
    expect(current?.phase, ManagedSourcePhase.revoked);
  });
}
