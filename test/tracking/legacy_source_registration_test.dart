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

const _sourceKey = 'legacy_dynamic';
const _fileName = 'legacy_dynamic.js';
const _revision = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

List<int> _legacySource({String name = 'Local'}) => utf8.encode('''
class LegacyDynamic extends ComicSource {
  name = "$name";
  key = "legacy_" + "dynamic";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  comic = {
    loadInfo(id) {
      return {title: "$name", cover: "https://example.test/$name.jpg", description: "", tags: {}};
    },
  };
  ping() { return this.name; }
}
''');

List<int> _managedCloudSource() => utf8.encode('''
class LegacyDynamic extends ComicSource {
  name = "Cloud R2";
  key = "$_sourceKey";
  version = "2.0.0";
  minAppVersion = "1.0.0";
  comic = {
    loadInfo(id) {
      return {title: "Cloud R2", cover: "https://example.test/r2.jpg", description: "", tags: {}};
    },
  };
  ping() { return this.name; }
}
''');

class _Transport implements TrackingHttpTransport {
  _Transport(this.responses);

  final List<TrackingHttpResponse> responses;
  final requests = <String>[];

  @override
  Future<TrackingHttpResponse> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    requests.add('$method $path');
    if (responses.isEmpty) throw StateError('unexpected tracking request');
    return responses.removeAt(0);
  }
}

TrackingHttpResponse _response(Object value) => TrackingHttpResponse(
  statusCode: 200,
  headers: const {},
  body: jsonEncode({'data': value}),
);

Map<String, dynamic> _authority() => TrustedAuthority(
  catalogId: TrustedCatalog.maintainedCatalogId,
  activeRevision: _revision,
  artifacts: const [
    TrustedArtifact(sourceKey: _sourceKey, fileName: _fileName),
  ],
).toJson();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, dynamic> previousSettings;
  late Directory root;
  late Directory sourceRoot;

  setUpAll(() async {
    previousSettings = {
      'cloudTrackingEnabled': appdata.settings['cloudTrackingEnabled'],
      'cloudTrackingServerUrl': appdata.settings['cloudTrackingServerUrl'],
      'cloudTrackingAccessToken': appdata.settings['cloudTrackingAccessToken'],
    };
    await JsEngine().init();
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-legacy-registration-');
    sourceRoot = Directory(p.join(root.path, 'comic_source'))
      ..createSync(recursive: true);
    App.dataPath = root.path;
    App.disposeTracking();
    appdata.settings['cloudTrackingEnabled'] = false;
    appdata.settings['cloudTrackingServerUrl'] = '';
    appdata.settings['cloudTrackingAccessToken'] = '';
    sourceRuntimePolicy
      ..revokeAll()
      ..registry = null
      ..sourceDirectoryPath = null
      ..authorityRevision = null
      ..pendingCloudEnable = false
      ..admissionReady = true
      ..admissionSuspended = false
      ..operationEpoch = 0
      ..cloudEnabled = false;
  });

  tearDown(() async {
    sourceRuntimePolicy.revokeAll();
    App.disposeTracking();
    ComicSourceManager().remove(_sourceKey);
    for (final entry in previousSettings.entries) {
      appdata.settings[entry.key] = entry.value;
    }
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('rejects the dynamic key lexically before Local fallback', () {
    expect(
      () => LegacySourceIdentity.fromBytes(_legacySource()),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'Local dynamic legacy source is registered before runtime publication and survives restart',
    () async {
      const identity = TrustedArtifact(
        sourceKey: _sourceKey,
        fileName: _fileName,
      );
      final rawBytes = _legacySource();
      final rootFile = File(p.join(sourceRoot.path, _fileName))
        ..writeAsBytesSync(rawBytes, flush: true);

      // This follows init.dart: admission discovery is data-only, then the
      // source manager performs the Local fallback under the commit lock.
      await App.cloudTracking.prepareRuntimeAdmission();
      final discovered = await SourceRevisionStore(sourceRoot).load();
      expect(discovered, isNotNull);
      expect(discovered!.artifacts, isEmpty);
      expect(
        discovered.migrationDiagnostics[_fileName],
        'Source identity is not a unique static literal.',
      );

      await ComicSourceManager().reload();
      final store = SourceRevisionStore(sourceRoot);
      final registered = await store.load();
      final active = registered?.find(_sourceKey, _fileName);
      expect(active, isNotNull);
      expect(active!.origin, ArtifactOrigin.custom);
      expect(active.relativePath, _fileName);
      expect(active.sha256, sha256.convert(rawBytes).toString());
      expect(active.activationBlocked, isFalse);
      expect(registered!.migrationDiagnostics.containsKey(_fileName), isFalse);
      expect(
        registered.recoverableArtifacts
            .where((item) => item.identity == identity)
            .length,
        1,
      );
      expect(await rootFile.readAsBytes(), rawBytes);
      expect(ComicSource.find(_sourceKey)?.name, 'Local');
      final details = (await ComicSource.find(_sourceKey)!.loadComicInfo!(
        'comic-1',
      )).data;
      expect(details.title, 'Local');

      // Simulate a process restart: a known exact selection loads directly and
      // is not discovered as a second root source.
      App.disposeTracking();
      sourceRuntimePolicy.revokeAll();
      sourceRuntimePolicy.prepare(
        cloudEnabled: false,
        registry: (await store.load())!,
        sourceDirectoryPath: sourceRoot.path,
      );
      await ComicSourceManager().reload();
      expect(
        ComicSource.all().where((source) => source.key == _sourceKey),
        hasLength(1),
      );
      expect(
        (await store.load())!.recoverableArtifacts
            .where((item) => item.identity == identity)
            .length,
        1,
      );
      expect(ComicSource.find(_sourceKey)?.name, 'Local');
    },
  );

  test(
    'Cloud-on startup preserves the dynamic root without executing it',
    () async {
      final rawBytes = utf8.encode('''
globalThis.__legacyDynamicConstructors =
    (globalThis.__legacyDynamicConstructors || 0) + 1;
${utf8.decode(_legacySource())}
''');
      final rootFile = File(p.join(sourceRoot.path, _fileName))
        ..writeAsBytesSync(rawBytes, flush: true);
      appdata.settings['cloudTrackingEnabled'] = true;

      final favorites = NetworkFavoriteCacheManager.forTesting();
      await favorites.init(
        databasePath: p.join(root.path, 'favorites.db'),
        migrateLegacy: false,
      );
      addTearDown(favorites.close);

      final coordinator = CloudTrackingCoordinator(
        favorites: favorites,
        sourceDirectory: sourceRoot,
        clientFactory: (_, _) => CloudTrackingClient(
          server: Uri.parse('https://tracking.invalid'),
          transport: _Transport([
            _response(_authority()),
            _response({
              'cloudEnabled': true,
              'interests': const [],
              'stateRevision': 1,
              'updatedAt': '2026-09-05T00:00:00.000Z',
            }),
            _response({
              'authority': _authority(),
              'generatedAt': '2026-09-05T00:00:00.000Z',
              'observations': const [],
            }),
          ]),
        ),
        artifactFetcher: (uri) async => uri.path.endsWith('/index.json')
            ? utf8.encode(
                jsonEncode([
                  {
                    'key': _sourceKey,
                    'fileName': _fileName,
                    'cloudTracking': {'scanner': 'scanner.js'},
                  },
                ]),
              )
            : _managedCloudSource(),
        pollInterval: const Duration(hours: 1),
      );
      addTearDown(coordinator.dispose);

      await coordinator.prepareRuntimeAdmission();
      expect(await SourceRevisionStore(sourceRoot).load(), isNotNull);
      expect(
        (await SourceRevisionStore(sourceRoot).load())!.artifacts,
        isEmpty,
      );
      await ComicSourceManager().reload();

      expect(ComicSource.find(_sourceKey), isNull);
      expect(await rootFile.readAsBytes(), rawBytes);
      expect(
        (await SourceRevisionStore(
          sourceRoot,
        ).load())!.migrationDiagnostics[_fileName],
        'Source identity is not a unique static literal.',
      );
      expect(
        JsEngine().runCode('globalThis.__legacyDynamicConstructors || 0'),
        0,
      );
    },
  );

  test(
    'a verified Local dynamic source is taken over by the exact Cloud artifact',
    () async {
      const identity = TrustedArtifact(
        sourceKey: _sourceKey,
        fileName: _fileName,
      );
      final localBytes = _legacySource();
      final rootFile = File(p.join(sourceRoot.path, _fileName))
        ..writeAsBytesSync(localBytes, flush: true);
      await App.cloudTracking.prepareRuntimeAdmission();
      await ComicSourceManager().reload();
      expect(ComicSource.find(_sourceKey)?.name, 'Local');

      final transport = _Transport([
        _response(_authority()),
        _response({
          'cloudEnabled': true,
          'interests': const [],
          'stateRevision': 1,
          'updatedAt': '2026-09-05T00:00:00.000Z',
        }),
        _response({
          'authority': _authority(),
          'generatedAt': '2026-09-05T00:00:00.000Z',
          'observations': const [],
        }),
      ]);
      final cloudBytes = _managedCloudSource();
      final favorites = NetworkFavoriteCacheManager.forTesting();
      await favorites.init(
        databasePath: p.join(root.path, 'favorites.db'),
        migrateLegacy: false,
      );
      addTearDown(favorites.close);
      final coordinator = CloudTrackingCoordinator(
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
                    'key': _sourceKey,
                    'fileName': _fileName,
                    'cloudTracking': {'scanner': 'scanner.js'},
                  },
                ]),
              )
            : cloudBytes,
        pollInterval: const Duration(hours: 1),
      );
      addTearDown(coordinator.dispose);

      appdata.settings['cloudTrackingEnabled'] = true;
      appdata.settings['cloudTrackingServerUrl'] = 'https://tracking.invalid';
      await coordinator.prepareRuntimeAdmission();
      await coordinator.start();

      final store = SourceRevisionStore(sourceRoot);
      final registry = await store.load();
      final active = registry!.find(identity.sourceKey, identity.fileName)!;
      expect(active.revision, _revision);
      expect(active.origin, ArtifactOrigin.managedCatalog);
      expect(active.activationBlocked, isFalse);
      expect(active.sha256, sha256.convert(cloudBytes).toString());
      expect(await rootFile.readAsBytes(), localBytes);
      expect(ComicSource.find(_sourceKey)?.name, 'Cloud R2');
      expect(
        registry.recoverableArtifacts.where(
          (item) => item.identity == identity,
        ),
        hasLength(1),
      );
      expect(registry.recoverableArtifacts.single.relativePath, _fileName);
      expect(sourceRuntimePolicy.hasActiveRuntime(active), isTrue);
      expect(
        (await ComicSource.find(_sourceKey)!.loadComicInfo!(
          'comic-1',
        )).data.title,
        'Cloud R2',
      );
    },
  );
}
