import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tracking/source_revision_manager.dart';
import 'package:venera/foundation/tracking/source_revision_store.dart';
import 'package:venera/foundation/tracking/trusted_catalog.dart';

void main() {
  const revisionA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const revisionB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  test(
    'migrates custom scripts and activates pinned revisions atomically',
    () async {
      final root = await Directory.systemTemp.createTemp('venera-revision-');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/legacy.js').writeAsString('''
class Legacy extends ComicSource {
  name = "Legacy";
  key = "legacy";
  version = "1.0.0";
  minAppVersion = "1.0.0";
}
''');
      final store = SourceRevisionStore(root);
      final manager = SourceRevisionManager(store: store);

      await store.loadOrMigrate(cloudEnabled: true);
      var registry = await manager.current();
      expect(
        registry.find('legacy', 'legacy.js')?.origin,
        ArtifactOrigin.custom,
      );

      final artifact = const TrustedArtifact(
        sourceKey: 'manwa',
        fileName: 'manwa.js',
      );
      registry = await manager.activate(
        revision: revisionA,
        artifacts: [artifact],
        fetch: (uri) async {
          expect(uri.path, contains('/$revisionA/manwa.js'));
          return utf8.encode('module.exports = {version: "a"};');
        },
        validate: (source, path) async {
          expect(source, contains('version'));
          expect(path, contains(revisionA));
        },
      );
      final managed = registry.find('manwa', 'manwa.js');
      expect(managed?.revision, revisionA);
      expect(managed?.origin, ArtifactOrigin.managedCatalog);
      expect(
        await store.fileForRelativePath(managed!.relativePath).exists(),
        isTrue,
      );

      await expectLater(
        manager.activate(
          revision: revisionB,
          artifacts: [artifact],
          fetch: (_) async => throw const FormatException('candidate failed'),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        (await manager.current()).find('manwa', 'manwa.js')!.revision,
        revisionA,
      );

      registry = await manager.activate(
        revision: revisionB,
        artifacts: [artifact],
        fetch: (_) async => utf8.encode('module.exports = {version: "b"};'),
      );
      expect(registry.find('manwa', 'manwa.js')!.revision, revisionB);
      expect(
        await store
            .fileForRelativePath('.managed/$revisionA/manwa.js')
            .exists(),
        isTrue,
      );
    },
  );

  test(
    'detaches managed source before edit and recovers last-known-good pointer',
    () async {
      final root = await Directory.systemTemp.createTemp('venera-revision-');
      addTearDown(() => root.delete(recursive: true));
      final store = SourceRevisionStore(root);
      final manager = SourceRevisionManager(store: store);
      const artifact = TrustedArtifact(
        sourceKey: 'manwa',
        fileName: 'manwa.js',
      );
      await manager.activate(
        revision: revisionA,
        artifacts: [artifact],
        fetch: (_) async => utf8.encode('module.exports = {};'),
      );

      final detached = await manager.detachForEdit(artifact);
      final custom = detached.find('manwa', 'manwa.js');
      expect(custom?.origin, ArtifactOrigin.custom);
      expect(custom?.revision, isNull);
      expect(await File('${root.path}/manwa.js').exists(), isTrue);
      expect(
        await File('${root.path}/.managed/$revisionA/manwa.js').exists(),
        isTrue,
      );

      await store.registryFile.writeAsString('{invalid');
      final recovered = await manager.current();
      expect(
        recovered.find('manwa', 'manwa.js')?.origin,
        ArtifactOrigin.managedCatalog,
      );
    },
  );

  test('rejects unsafe catalog paths and revisions', () {
    expect(
      () => TrustedCatalog.safeRelativePath('../scanner.js'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => TrustedCatalog().artifactUri('short', 'manwa.js'),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'derives exact artifact identity and capability from the pinned index',
    () async {
      final root = await Directory.systemTemp.createTemp('venera-revision-');
      addTearDown(() => root.delete(recursive: true));
      final manager = SourceRevisionManager(store: SourceRevisionStore(root));
      final capableBytes = utf8.encode('module.exports = {key: "variant"};');
      final capableHash = sha256.convert(capableBytes).toString();
      final index = jsonEncode([
        {'key': 'duplicate-source', 'fileName': 'variant-a.js'},
        {
          'key': 'duplicate-source',
          'fileName': 'variant-b.js',
          'sha256': capableHash,
          'cloudTracking': {'scanner': 'extensions/scanner.js'},
          'parserVersion': '1',
          'runtime': 'venera-js-v1',
        },
      ]);

      Future<List<int>> fetch(Uri uri) async {
        if (uri.path.endsWith('/index.json')) return utf8.encode(index);
        if (uri.path.endsWith('/variant-b.js')) return capableBytes;
        return utf8.encode('module.exports = {};');
      }

      final registry = await manager.activateFromIndex(
        revision: revisionA,
        fileName: 'variant-b.js',
        fetch: fetch,
        resolveSourceKey: (source, _) async => 'duplicate-source',
      );
      expect(
        registry.find('duplicate-source', 'variant-b.js')?.cloudCapable,
        isTrue,
      );

      await expectLater(
        manager.activateFromIndex(
          revision: revisionB,
          fileName: 'variant-b.js',
          fetch: (_) async => utf8.encode('tampered'),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        (await manager.current())
            .find('duplicate-source', 'variant-b.js')
            ?.revision,
        revisionA,
      );

      expect(
        () => const TrustedCatalog().parseIndex([
          {'key': 'duplicate-source', 'fileName': 'variant-a.js'},
          {'key': 'duplicate-source', 'fileName': 'variant-a.js'},
        ]),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => const TrustedCatalog().parseIndex([
          {'key': 'duplicate-source', 'fileName': '../unsafe.js'},
        ]),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('keeps the actual pre-activation registry as durable LKG', () async {
    final root = await Directory.systemTemp.createTemp('venera-revision-');
    addTearDown(() => root.delete(recursive: true));
    const hash =
        '0000000000000000000000000000000000000000000000000000000000000000';
    ActiveArtifact artifact(String sourceKey) => ActiveArtifact(
      sourceKey: sourceKey,
      fileName: '$sourceKey.js',
      revision: null,
      relativePath: '$sourceKey.js',
      origin: ArtifactOrigin.custom,
      sha256: hash,
    );
    final first = ActiveArtifactRegistry(artifacts: [artifact('first')]);
    final second = ActiveArtifactRegistry(artifacts: [artifact('second')]);
    final store = SourceRevisionStore(root);
    await store.save(first);
    await store.save(second);

    expect(
      (await store.loadLastKnownGood())?.find('first', 'first.js'),
      isNotNull,
    );
    await store.registryFile.writeAsString('{interrupted');
    expect((await store.load())?.find('first', 'first.js'), isNotNull);

    final failingRoot = await Directory.systemTemp.createTemp(
      'venera-revision-failing-',
    );
    addTearDown(() => failingRoot.delete(recursive: true));
    var replacements = 0;
    final failingStore = SourceRevisionStore(
      failingRoot,
      atomicReplace: (source, target) async {
        replacements++;
        if (replacements == 2) {
          throw StateError('injected pointer interruption');
        }
        await source.rename(target.path);
      },
    );
    await failingStore.save(first);
    await expectLater(failingStore.save(second), throwsStateError);
    expect((await failingStore.load())?.find('first', 'first.js'), isNotNull);
  });

  test(
    'pointer and LKG restore failures keep the affected selection blocked',
    () async {
      ActiveArtifact artifact(String sourceKey) => ActiveArtifact(
        sourceKey: sourceKey,
        fileName: '$sourceKey.js',
        revision: null,
        relativePath: '$sourceKey.js',
        origin: ArtifactOrigin.custom,
        sha256:
            '0000000000000000000000000000000000000000000000000000000000000000',
      );

      Future<void> exercise({required bool failLkg}) async {
        final root = await Directory.systemTemp.createTemp('venera-restore-');
        addTearDown(() => root.delete(recursive: true));
        final first = ActiveArtifactRegistry(artifacts: [artifact('first')]);
        final second = ActiveArtifactRegistry(artifacts: [artifact('second')]);
        var fail = false;
        final store = SourceRevisionStore(
          root,
          atomicReplace: (source, target) async {
            if (fail &&
                (failLkg
                    ? target.path.endsWith('active-artifacts.json.lkg')
                    : target.path.endsWith('active-artifacts.json'))) {
              throw StateError('injected restore interruption');
            }
            await source.rename(target.path);
          },
        );
        await store.save(first);
        await store.save(second);
        fail = true;
        await expectLater(store.restore(first), throwsStateError);
        expect((await store.load())?.find('second', 'second.js'), isNotNull);
        expect(
          (await store.loadLastKnownGood())?.find('first', 'first.js'),
          isNotNull,
        );

        fail = false;
        final blocked = await store.setActivationBlocked(
          const TrustedArtifact(sourceKey: 'second', fileName: 'second.js'),
          true,
          preserveLastKnownGood: true,
        );
        expect(blocked.artifacts.single.activationBlocked, isTrue);
        expect(
          (await store.loadLastKnownGood())?.find('first', 'first.js'),
          isNotNull,
        );
      }

      await exercise(failLkg: false);
      await exercise(failLkg: true);
    },
  );
}
