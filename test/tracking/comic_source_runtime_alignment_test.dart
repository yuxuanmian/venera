import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/tracking/cloud_tracking_client.dart';
import 'package:venera/foundation/tracking/cloud_tracking_coordinator.dart';
import 'package:venera/foundation/tracking/legacy_source_identity.dart';
import 'package:venera/foundation/tracking/source_revision_store.dart';
import 'package:venera/foundation/tracking/source_runtime_policy.dart';
import 'package:venera/foundation/tracking/trusted_catalog.dart';
import 'package:venera/foundation/tracking/runtime_generation.dart';

const _revisionR1 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _revisionR2 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _sourceKey = 'tracking_runtime_alignment_source';

List<int> _source(String name) => utf8.encode('''
class TrackingRuntimeAlignmentSource extends ComicSource {
  name = "$name";
  key = "$_sourceKey";
  version = "1.0.0";
  minAppVersion = "1.0.0";
}
''');

List<int> _compositionSource(TrustedArtifact artifact, String name) {
  final counter = artifact.sourceKey == 'composition_missing'
      ? '''globalThis.__ownershipMissingExecutions =
    (globalThis.__ownershipMissingExecutions || 0) + 1;'''
      : '';
  return utf8.encode('''
$counter
class TrackingOwnershipSource extends ComicSource {
  name = "$name";
  key = "${artifact.sourceKey}";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  ready = false;
  init() { this.ready = true; }
  ping() { return this.name + ":" + this.ready; }
}
''');
}

class _CompositionTransport implements TrackingHttpTransport {
  _CompositionTransport(this.responses);

  final List<TrackingHttpResponse> responses;
  final requestBodies = <String?>[];

  @override
  Future<TrackingHttpResponse> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    requestBodies.add(body);
    if (responses.isEmpty) throw StateError('unexpected tracking request');
    return responses.removeAt(0);
  }
}

TrackingHttpResponse _compositionResponse(Object data) => TrackingHttpResponse(
  statusCode: 200,
  headers: const {},
  body: jsonEncode({'data': data}),
);

Map<String, dynamic> _compositionAuthority(
  String revision,
  List<TrustedArtifact> artifacts,
) => TrustedAuthority(
  catalogId: TrustedCatalog.maintainedCatalogId,
  activeRevision: revision,
  artifacts: artifacts,
).toJson();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory sourceDirectory;

  setUpAll(() async {
    sourceDirectory = await Directory.systemTemp.createTemp(
      'venera-runtime-alignment-',
    );
    App.dataPath = sourceDirectory.path;
    await JsEngine().init();
  });

  tearDownAll(() async {
    ComicSourceManager().remove(_sourceKey);
    if (await sourceDirectory.exists()) {
      await sourceDirectory.delete(recursive: true);
    }
  });

  test(
    'loads the exact staged R2 JavaScript after R1 runtime activation',
    () async {
      final store = SourceRevisionStore(
        Directory(
          '${sourceDirectory.path}${Platform.pathSeparator}comic_source',
        ),
      );
      final r1 = await store.writeManagedArtifact(
        _revisionR1,
        'alignment.js',
        _source('R1'),
        sourceKey: _sourceKey,
      );
      final activeR1 = r1.copyWith(cloudCapable: true);
      await store.save(ActiveArtifactRegistry(artifacts: [activeR1]));

      await ComicSourceManager().reload(requiredArtifact: activeR1);
      expect(ComicSource.find(_sourceKey)?.name, 'R1');

      final r2Bytes = _source('R2');
      final r2Text = utf8.decode(r2Bytes);
      final candidatePath = store.fileForRelativePath(
        '.managed/$_revisionR2/alignment.js',
      );
      final candidate = await ComicSourceParser().parse(
        r2Text,
        candidatePath.path,
        register: false,
        allowExistingKey: true,
        loadData: false,
        scheduleInit: false,
      );
      expect(candidate.key, _sourceKey);
      expect(ComicSource.find(_sourceKey)?.name, 'R1');

      final r2 = await store.writeManagedArtifact(
        _revisionR2,
        'alignment.js',
        r2Bytes,
        sourceKey: _sourceKey,
      );
      final activeR2 = r2.copyWith(cloudCapable: true);
      await store.save(ActiveArtifactRegistry(artifacts: [activeR2]));

      await ComicSourceManager().reload(requiredArtifact: activeR2);
      final loaded = ComicSource.find(_sourceKey);
      expect(loaded?.name, 'R2');
      expect(
        p.canonicalize(loaded!.filePath),
        p.canonicalize(store.fileForRelativePath(activeR2.relativePath).path),
      );
    },
  );

  test(
    'aligns installed mixed-capability artifacts through the real source manager',
    () async {
      const capable = TrustedArtifact(
        sourceKey: 'composition_capable',
        fileName: 'composition_capable.js',
      );
      const localOnly = TrustedArtifact(
        sourceKey: 'composition_local_only',
        fileName: 'composition_local_only.js',
      );
      const variantA = TrustedArtifact(
        sourceKey: 'composition_variant',
        fileName: 'composition_variant_a.js',
      );
      const variantB = TrustedArtifact(
        sourceKey: 'composition_variant',
        fileName: 'composition_variant_b.js',
      );
      const missing = TrustedArtifact(
        sourceKey: 'composition_missing',
        fileName: 'composition_missing.js',
      );
      const uninstalled = TrustedArtifact(
        sourceKey: 'composition_uninstalled',
        fileName: 'composition_uninstalled.js',
      );
      final previousDataPath = App.dataPath;
      final previousSettings = {
        'followUpdatesEnabled': appdata.settings['followUpdatesEnabled'],
        'cloudTrackingEnabled': appdata.settings['cloudTrackingEnabled'],
        'cloudTrackingServerUrl': appdata.settings['cloudTrackingServerUrl'],
        'cloudTrackingAccessToken':
            appdata.settings['cloudTrackingAccessToken'],
      };
      final root = await Directory.systemTemp.createTemp(
        'venera-runtime-ownership-composition-',
      );
      final sourceRoot = Directory(p.join(root.path, 'comic_source'));
      final favorites = NetworkFavoriteCacheManager.forTesting();
      var favoritesInitialized = false;
      CloudTrackingCoordinator? coordinator;
      final customBytes = _compositionSource(missing, 'custom');
      final indexArtifacts = [
        capable,
        localOnly,
        variantA,
        variantB,
        uninstalled,
      ];
      try {
        App.dataPath = root.path;
        appdata.settings['followUpdatesEnabled'] = true;
        appdata.settings['cloudTrackingEnabled'] = true;
        appdata.settings['cloudTrackingServerUrl'] = 'https://tracking.invalid';
        appdata.settings['cloudTrackingAccessToken'] = '';
        await favorites.init(
          databasePath: p.join(root.path, 'favorites.db'),
          migrateLegacy: false,
        );
        favoritesInitialized = true;

        final store = SourceRevisionStore(sourceRoot);
        await sourceRoot.create(recursive: true);
        final managed = <ActiveArtifact>[];
        for (final artifact in [capable, localOnly, variantA]) {
          final written = await store.writeManagedArtifact(
            _revisionR1,
            artifact.fileName,
            _compositionSource(artifact, 'R1'),
            sourceKey: artifact.sourceKey,
          );
          managed.add(
            written.copyWith(
              cloudCapable: artifact == capable || artifact == variantA,
            ),
          );
        }
        final customPath = p.join(sourceRoot.path, missing.fileName);
        await File(customPath).writeAsBytes(customBytes, flush: true);
        final custom = ActiveArtifact(
          sourceKey: missing.sourceKey,
          fileName: missing.fileName,
          revision: null,
          relativePath: missing.fileName,
          origin: ArtifactOrigin.custom,
          sha256: sha256.convert(customBytes).toString(),
        );
        final initial = ActiveArtifactRegistry(artifacts: [...managed, custom]);
        await store.save(initial);
        sourceRuntimePolicy.prepare(
          cloudEnabled: false,
          registry: initial,
          sourceDirectoryPath: sourceRoot.path,
        );
        await ComicSourceManager().reload();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final executionsBeforeCloud = JsEngine().runCode(
          'globalThis.__ownershipMissingExecutions || 0',
        );

        favorites.replaceComicMembership(
          capable.sourceKey,
          'comic-capable',
          const ['folder'],
        );
        favorites.replaceComicMembership(
          localOnly.sourceKey,
          'comic-local',
          const ['folder'],
        );
        favorites.replaceComicMembership(
          variantA.sourceKey,
          'comic-variant',
          const ['folder'],
        );

        final authority = _compositionAuthority(_revisionR2, [
          capable,
          variantA,
        ]);
        final transport = _CompositionTransport([
          _compositionResponse(authority),
          _compositionResponse({
            'cloudEnabled': true,
            'interests': const [],
            'stateRevision': 1,
            'updatedAt': '2026-09-05T00:00:00.000Z',
          }),
          _compositionResponse({
            'authority': authority,
            'generatedAt': '2026-09-05T00:00:00.000Z',
            'observations': const [],
          }),
        ]);
        final indexBytes = utf8.encode(
          jsonEncode([
            for (final artifact in indexArtifacts)
              {
                'key': artifact.sourceKey,
                'fileName': artifact.fileName,
                if (artifact == capable || artifact == variantA)
                  'cloudTracking': {'scanner': 'scanner.js'},
              },
          ]),
        );
        coordinator = CloudTrackingCoordinator(
          favorites: favorites,
          sourceDirectory: sourceRoot,
          clientFactory: (_, _) => CloudTrackingClient(
            server: Uri.parse('https://tracking.invalid'),
            transport: transport,
          ),
          artifactFetcher: (uri) async => uri.path.endsWith('/index.json')
              ? indexBytes
              : _compositionSource(
                  indexArtifacts.firstWhere(
                    (artifact) => artifact.fileName == uri.pathSegments.last,
                  ),
                  'R2',
                ),
          sourceKeyResolver: (source, _) async =>
              LegacySourceIdentity.fromBytes(utf8.encode(source)).sourceKey,
          pollInterval: const Duration(hours: 1),
        );

        // The initial Local load used an explicit registry admission.  Clear
        // that startup snapshot so the coordinator performs its real
        // Cloud-on admission/takeover phase before alignment.
        sourceRuntimePolicy.registry = null;
        await coordinator.start();
        await Future<void>.delayed(const Duration(milliseconds: 100));

        final registry = await store.load();
        if (registry == null) {
          fail('aligned registry was not persisted');
        }
        for (final artifact in [capable, localOnly, variantA]) {
          final active = registry.find(artifact.sourceKey, artifact.fileName);
          expect(active?.revision, _revisionR2);
          expect(active?.activationBlocked, isFalse);
          expect(
            active?.sha256,
            sha256.convert(_compositionSource(artifact, 'R2')).toString(),
          );
          expect(
            p.canonicalize(
              store.fileForRelativePath(active!.relativePath).path,
            ),
            p.canonicalize(
              store
                  .fileForRelativePath(
                    '.managed/$_revisionR2/${artifact.fileName}',
                  )
                  .path,
            ),
          );
        }
        final missingActive = registry.find(
          missing.sourceKey,
          missing.fileName,
        );
        expect(missingActive?.revision, isNull);
        expect(missingActive?.activationBlocked, isTrue);
        expect(await File(customPath).readAsBytes(), customBytes);
        expect(
          JsEngine().runCode('globalThis.__ownershipMissingExecutions || 0'),
          executionsBeforeCloud,
        );
        expect(
          registry.find(uninstalled.sourceKey, uninstalled.fileName),
          isNull,
        );
        expect(ComicSource.find(capable.sourceKey)?.name, 'R2');
        expect(ComicSource.find(localOnly.sourceKey)?.name, 'R2');
        expect(coordinator.modes.strategyFor(capable), TrackingStrategy.cloud);
        expect(
          coordinator.modes.strategyFor(localOnly),
          TrackingStrategy.local,
        );
        expect(coordinator.modes.strategyFor(variantA), TrackingStrategy.cloud);

        final state = jsonDecode(transport.requestBodies[1]!);
        final interestArtifacts = [
          for (final interest in state['interests'] as List)
            '${interest['artifact']['sourceKey']}\u0000${interest['artifact']['fileName']}',
        ];
        expect(
          interestArtifacts,
          contains('${capable.sourceKey}\u0000${capable.fileName}'),
        );
        expect(
          interestArtifacts,
          isNot(contains('${localOnly.sourceKey}\u0000${localOnly.fileName}')),
        );
        expect(
          interestArtifacts,
          isNot(contains('${variantA.sourceKey}\u0000${variantB.fileName}')),
        );
      } finally {
        coordinator?.dispose();
        if (favoritesInitialized) favorites.close();
        sourceRuntimePolicy
          ..revokeAll()
          ..cloudEnabled = false
          ..pendingCloudEnable = false
          ..admissionReady = true
          ..operationEpoch = 0
          ..registry = null
          ..sourceDirectoryPath = null
          ..authorityRevision = null;
        for (final key in [
          'composition_capable',
          'composition_local_only',
          'composition_variant',
          'composition_missing',
        ]) {
          ComicSourceManager().remove(key);
        }
        App.dataPath = previousDataPath;
        for (final entry in previousSettings.entries) {
          appdata.settings[entry.key] = entry.value;
        }
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
  );

  test(
    'migrates a root custom source without a registry before Cloud takeover',
    () async {
      const artifact = TrustedArtifact(
        sourceKey: 'composition_no_registry',
        fileName: 'composition_no_registry.js',
      );
      final previousDataPath = App.dataPath;
      final previousSettings = {
        'followUpdatesEnabled': appdata.settings['followUpdatesEnabled'],
        'cloudTrackingEnabled': appdata.settings['cloudTrackingEnabled'],
        'cloudTrackingServerUrl': appdata.settings['cloudTrackingServerUrl'],
        'cloudTrackingAccessToken':
            appdata.settings['cloudTrackingAccessToken'],
      };
      final root = await Directory.systemTemp.createTemp(
        'venera-runtime-no-registry-',
      );
      final sourceRoot = Directory(p.join(root.path, 'comic_source'));
      final favorites = NetworkFavoriteCacheManager.forTesting();
      var favoritesInitialized = false;
      CloudTrackingCoordinator? coordinator;
      final customBytes = _compositionSource(artifact, 'custom');
      try {
        App.dataPath = root.path;
        appdata.settings['followUpdatesEnabled'] = true;
        appdata.settings['cloudTrackingEnabled'] = true;
        appdata.settings['cloudTrackingServerUrl'] = 'https://tracking.invalid';
        appdata.settings['cloudTrackingAccessToken'] = '';
        await favorites.init(
          databasePath: p.join(root.path, 'favorites.db'),
          migrateLegacy: false,
        );
        favoritesInitialized = true;
        await sourceRoot.create(recursive: true);
        final rootFile = File(p.join(sourceRoot.path, artifact.fileName));
        await rootFile.writeAsBytes(customBytes, flush: true);
        sourceRuntimePolicy
          ..revokeAll()
          ..registry = null
          ..cloudEnabled = false
          ..pendingCloudEnable = false
          ..admissionReady = true
          ..operationEpoch = 0
          ..sourceDirectoryPath = null
          ..authorityRevision = null;

        final authority = _compositionAuthority(_revisionR2, [artifact]);
        final transport = _CompositionTransport([
          _compositionResponse(authority),
          _compositionResponse({
            'cloudEnabled': true,
            'interests': const [],
            'stateRevision': 1,
            'updatedAt': '2026-09-05T00:00:00.000Z',
          }),
          _compositionResponse({
            'authority': authority,
            'generatedAt': '2026-09-05T00:00:00.000Z',
            'observations': const [],
          }),
        ]);
        coordinator = CloudTrackingCoordinator(
          favorites: favorites,
          sourceDirectory: sourceRoot,
          clientFactory: (_, _) => CloudTrackingClient(
            server: Uri.parse('https://tracking.invalid'),
            transport: transport,
          ),
          artifactFetcher: (uri) async => uri.path.endsWith('/index.json')
              ? utf8.encode(
                  jsonEncode([
                    {
                      'key': artifact.sourceKey,
                      'fileName': artifact.fileName,
                      'cloudTracking': {'scanner': 'scanner.js'},
                    },
                  ]),
                )
              : _compositionSource(artifact, 'R2'),
          sourceKeyResolver: (source, _) async =>
              LegacySourceIdentity.fromBytes(utf8.encode(source)).sourceKey,
          pollInterval: const Duration(hours: 1),
        );

        expect(await rootFile.readAsBytes(), customBytes);
        expect(await SourceRevisionStore(sourceRoot).load(), isNull);
        await coordinator.start();
        await Future<void>.delayed(const Duration(milliseconds: 100));

        final registry = await SourceRevisionStore(sourceRoot).load();
        final active = registry?.find(artifact.sourceKey, artifact.fileName);
        expect(active?.revision, _revisionR2);
        expect(active?.activationBlocked, isFalse);
        expect(ComicSource.find(artifact.sourceKey)?.name, 'R2');
        expect(
          JsEngine().runCode(
            'ComicSource.sources.${artifact.sourceKey}.ping()',
          ),
          'R2:true',
        );
        expect(
          sourceRuntimePolicy.permitForPath(
            SourceRevisionStore(
              sourceRoot,
            ).fileForRelativePath(active!.relativePath).path,
          ),
          isNull,
        );
        expect(await rootFile.readAsBytes(), customBytes);
        expect(
          registry?.recoverableArtifacts.any(
            (item) =>
                item.identity == artifact &&
                item.relativePath == artifact.fileName &&
                item.sha256 == sha256.convert(customBytes).toString(),
          ),
          isTrue,
        );
      } finally {
        coordinator?.dispose();
        if (favoritesInitialized) favorites.close();
        sourceRuntimePolicy
          ..revokeAll()
          ..cloudEnabled = false
          ..pendingCloudEnable = false
          ..admissionReady = true
          ..operationEpoch = 0
          ..registry = null
          ..sourceDirectoryPath = null
          ..authorityRevision = null;
        ComicSourceManager().remove(artifact.sourceKey);
        App.dataPath = previousDataPath;
        for (final entry in previousSettings.entries) {
          appdata.settings[entry.key] = entry.value;
        }
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
  );
}
