import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/runtime_loader.dart';
import 'package:venera/foundation/catalog/runtime_context.dart';
import 'package:venera/foundation/catalog/store.dart';
import 'package:venera/foundation/js_engine.dart';

const _revision = '0123456789012345678901234567890123456789';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('all checked-in catalog sources prepare and publish with QJS', (
    _,
  ) async {
    final configsRoot = _findConfigsRoot();
    final indexBytes = await File(
      p.join(configsRoot, 'index.json'),
    ).readAsBytes();
    final index = CatalogIndex.fromBytes(indexBytes);
    final pointer = CatalogPointer(
      catalogId: 'venera-app/venera-configs',
      revision: _revision,
      indexUrl:
          'https://raw.githubusercontent.com/venera-app/venera-configs/'
          '$_revision/index.json',
    );

    final temporaryRoot = await Directory.systemTemp.createTemp(
      'venera-catalog-runtime-smoke-',
    );
    final oldDataPath = App.isInitialized ? App.dataPath : null;
    App.dataPath = temporaryRoot.path;
    try {
      await JsEngine().init();
      final store = CatalogStore(
        Directory(p.join(temporaryRoot.path, 'store')),
      );
      final candidate = await store.createCandidate(
        pointer: pointer,
        indexBytes: indexBytes,
        index: index,
        attemptId: 'integration-smoke',
      );
      for (final entry in index.entries) {
        final source = await File(
          p.join(configsRoot, entry.fileName),
        ).readAsBytes();
        await store.writeCandidateSource(candidate, entry, source);
      }
      final complete = await store.finalizeCandidate(candidate);
      final snapshot = complete.snapshot;
      final loader = CatalogRuntimeLoader.forComicSources();

      final failures = <String, Object>{};
      for (final entry in index.entries) {
        final single = _singleEntrySnapshot(snapshot, entry);
        try {
          final runtime = await loader.prepare(single);
          expect(runtime.sources, hasLength(1));
          expect(runtime.sources.single.entry.key, entry.key);
          expect(
            runtime.sources.single.context.phase,
            ManagedSourcePhase.preparing,
          );
          runtime.dispose();
          expect(
            runtime.sources.single.context.phase,
            ManagedSourcePhase.revoked,
          );
        } catch (error) {
          failures[entry.key] = error;
        }
      }
      expect(failures, isEmpty, reason: _formatFailures(failures));

      final runtime = await loader.prepare(snapshot);
      expect(runtime.sources, hasLength(index.entries.length));
      expect(
        runtime.sources.every(
          (source) => source.context.phase == ManagedSourcePhase.preparing,
        ),
        isTrue,
      );
      runtime.publish();
      expect(
        runtime.sources.every(
          (source) => source.context.phase == ManagedSourcePhase.published,
        ),
        isTrue,
      );
      runtime.dispose();
      expect(
        runtime.sources.every(
          (source) => source.context.phase == ManagedSourcePhase.revoked,
        ),
        isTrue,
      );
      await complete.discard();
    } finally {
      if (oldDataPath != null) App.dataPath = oldDataPath;
      if (await temporaryRoot.exists()) {
        await temporaryRoot.delete(recursive: true);
      }
    }
  });
}

CatalogSnapshot _singleEntrySnapshot(
  CatalogSnapshot snapshot,
  CatalogSourceEntry entry,
) {
  final file = snapshot.manifest.files.firstWhere(
    (candidate) => candidate.sourceKey == entry.key,
  );
  return CatalogSnapshot(
    manifest: CatalogSnapshotManifest(
      pointer: snapshot.manifest.pointer,
      indexSha256: snapshot.manifest.indexSha256,
      files: [file],
    ),
    indexBytes: snapshot.indexBytes,
    index: CatalogIndex([entry]),
    rootPath: snapshot.rootPath,
  );
}

String _findConfigsRoot() {
  final configured = Platform.environment['VENERA_CONFIGS_ROOT'];
  final candidates = <String>[
    if (configured != null && configured.isNotEmpty) configured,
    Directory.current.path,
    Directory.current.parent.path,
    Directory.current.parent.parent.path,
  ];
  for (final candidate in candidates) {
    final root = File(p.join(candidate, 'index.json'));
    if (root.existsSync() &&
        File(p.join(candidate, 'copy_manga.js')).existsSync()) {
      return candidate;
    }
    final nested = Directory(p.join(candidate, 'venera-configs'));
    if (File(p.join(nested.path, 'index.json')).existsSync()) {
      return nested.path;
    }
  }
  throw StateError(
    'Cannot locate venera-configs; set VENERA_CONFIGS_ROOT for the smoke test.',
  );
}

String _formatFailures(Map<String, Object> failures) =>
    failures.entries.map((entry) => '${entry.key}: ${entry.value}').join('\n');
