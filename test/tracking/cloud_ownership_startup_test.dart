import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/tracking/cloud_tracking_coordinator.dart';
import 'package:venera/foundation/tracking/source_revision_store.dart';
import 'package:venera/foundation/tracking/source_runtime_policy.dart';
import 'package:venera/foundation/tracking/trusted_catalog.dart';

void main() {
  late Directory root;
  late Directory sourceDirectory;

  const capable = TrustedArtifact(
    sourceKey: 'startup_capable',
    fileName: 'startup_capable.js',
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-ownership-startup-');
    sourceDirectory = Directory(p.join(root.path, 'comic_source'))
      ..createSync(recursive: true);
    sourceRuntimePolicy
      ..revokeAll()
      ..registry = null
      ..sourceDirectoryPath = null
      ..authorityRevision = null
      ..pendingCloudEnable = false
      ..admissionReady = true
      ..operationEpoch = 0
      ..cloudEnabled = false;
  });

  tearDown(() async {
    sourceRuntimePolicy
      ..revokeAll()
      ..registry = null
      ..sourceDirectoryPath = null
      ..authorityRevision = null
      ..pendingCloudEnable = false
      ..admissionReady = true
      ..operationEpoch = 0
      ..cloudEnabled = false;
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'startup prepares admission before Cloud-owned source loading',
    () async {
      final store = SourceRevisionStore(sourceDirectory);
      final bytes = [1, 2, 3];
      final active = ActiveArtifact(
        sourceKey: capable.sourceKey,
        fileName: capable.fileName,
        revision: null,
        relativePath: capable.fileName,
        origin: ArtifactOrigin.custom,
        sha256: sha256.convert([1, 2, 3]).toString(),
        activationBlocked: true,
      );
      await store.save(ActiveArtifactRegistry(artifacts: [active]));
      final rootScript = File(p.join(sourceDirectory.path, 'root.js'))
        ..writeAsBytesSync(bytes);

      // This is the production bootstrap order: persisted settings/app data,
      // no-execution registry discovery, then runtime admission.
      final events = <String>[];
      events.add('appdata-loaded');
      final registry = await store.loadOrMigrate(cloudEnabled: true);
      events.add('registry-discovered');
      sourceRuntimePolicy.prepare(
        cloudEnabled: true,
        registry: registry,
        sourceDirectoryPath: sourceDirectory.path,
        authorityRevision: null,
      );
      sourceRuntimePolicy.requestMode(cloudEnabled: true, operationEpoch: 0);
      events.add('admission-prepared');

      expect(events, [
        'appdata-loaded',
        'registry-discovered',
        'admission-prepared',
      ]);
      expect(sourceRuntimePolicy.allowUnmanagedRoot(rootScript.path), isFalse);
      expect(sourceRuntimePolicy.canLoadPath(rootScript.path), isFalse);
      expect(await rootScript.readAsBytes(), bytes);
      expect(
        sourceRuntimePolicy.canLoadPath(
          store.fileForRelativePath(active.relativePath).path,
        ),
        isFalse,
      );
    },
  );

  test('Cloud-on does not fall back to an unregistered root script', () async {
    final store = SourceRevisionStore(sourceDirectory);
    final rootScript = File(p.join(sourceDirectory.path, capable.fileName))
      ..writeAsStringSync('class Root extends ComicSource {}');
    final registry = ActiveArtifactRegistry(
      artifacts: [
        ActiveArtifact(
          sourceKey: capable.sourceKey,
          fileName: capable.fileName,
          revision: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          relativePath: '.managed/a/${capable.fileName}',
          origin: ArtifactOrigin.managedCatalog,
          sha256:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          activationBlocked: true,
        ),
      ],
    );
    sourceRuntimePolicy.prepare(
      cloudEnabled: true,
      registry: registry,
      sourceDirectoryPath: sourceDirectory.path,
      authorityRevision: registry.artifacts.single.revision,
    );

    expect(sourceRuntimePolicy.allowUnmanagedRoot(rootScript.path), isFalse);
    expect(sourceRuntimePolicy.canLoadPath(rootScript.path), isFalse);
    expect(
      sourceRuntimePolicy.canLoadPath(
        store.fileForRelativePath(registry.artifacts.single.relativePath).path,
      ),
      isFalse,
    );
  });

  test('Cloud-off only admits the verified pinned selection', () async {
    final store = SourceRevisionStore(sourceDirectory);
    final managed = await store.writeManagedArtifact(
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      capable.fileName,
      [1, 2, 3],
      sourceKey: capable.sourceKey,
    );
    final registry = ActiveArtifactRegistry(artifacts: [managed]);
    sourceRuntimePolicy.prepare(
      cloudEnabled: false,
      registry: registry,
      sourceDirectoryPath: sourceDirectory.path,
    );

    expect(
      sourceRuntimePolicy.canLoadPath(
        store.fileForRelativePath(managed.relativePath).path,
      ),
      isTrue,
    );
    expect(
      sourceRuntimePolicy.allowUnmanagedRoot(
        p.join(sourceDirectory.path, 'new.js'),
      ),
      isTrue,
    );

    final blocked = managed.copyWith(activationBlocked: true);
    sourceRuntimePolicy.updateRegistry(
      ActiveArtifactRegistry(artifacts: [blocked]),
    );
    expect(
      sourceRuntimePolicy.canLoadPath(
        store.fileForRelativePath(blocked.relativePath).path,
      ),
      isFalse,
    );
  });

  test(
    'runtime admission persists the Cloud takeover block before source init',
    () async {
      final store = SourceRevisionStore(sourceDirectory);
      final bytes = [1, 2, 3];
      final custom = ActiveArtifact(
        sourceKey: capable.sourceKey,
        fileName: capable.fileName,
        revision: null,
        relativePath: capable.fileName,
        origin: ArtifactOrigin.custom,
        sha256: sha256.convert(bytes).toString(),
      );
      await File(
        p.join(sourceDirectory.path, capable.fileName),
      ).writeAsBytes(bytes);
      await store.save(ActiveArtifactRegistry(artifacts: [custom]));

      final previousCloud = appdata.settings['cloudTrackingEnabled'];
      appdata.settings['cloudTrackingEnabled'] = true;
      final coordinator = CloudTrackingCoordinator(
        favorites: NetworkFavoriteCacheManager.forTesting(),
        sourceDirectory: sourceDirectory,
      );
      addTearDown(() {
        coordinator.dispose();
        appdata.settings['cloudTrackingEnabled'] = previousCloud;
      });

      await coordinator.prepareRuntimeAdmission();
      final prepared = await store.load();
      expect(prepared?.artifacts.single.activationBlocked, isTrue);
      expect(prepared?.recoverableArtifacts, hasLength(1));
      expect(prepared?.recoverableArtifacts.single.sha256, custom.sha256);
      expect(
        await File(
          p.join(sourceDirectory.path, capable.fileName),
        ).readAsBytes(),
        bytes,
      );
    },
  );
}
