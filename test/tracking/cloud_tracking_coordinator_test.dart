import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/tracking/apply_service.dart';
import 'package:venera/foundation/tracking/cloud_tracking_client.dart';
import 'package:venera/foundation/tracking/cloud_tracking_coordinator.dart';
import 'package:venera/foundation/tracking/observation.dart';
import 'package:venera/foundation/tracking/runtime_generation.dart';
import 'package:venera/foundation/tracking/source_revision_manager.dart';
import 'package:venera/foundation/tracking/source_revision_store.dart';
import 'package:venera/foundation/tracking/source_runtime_policy.dart';
import 'package:venera/foundation/tracking/trusted_catalog.dart';

const _revision = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _revisionB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _hash =
    '0000000000000000000000000000000000000000000000000000000000000000';

const _manwa = TrustedArtifact(sourceKey: 'manwa', fileName: 'manwa.js');
const _localOnly = TrustedArtifact(
  sourceKey: 'copy_manga',
  fileName: 'copy_manga.js',
);

ActiveArtifact _active(
  TrustedArtifact artifact, {
  required bool cloudCapable,
}) => ActiveArtifact(
  sourceKey: artifact.sourceKey,
  fileName: artifact.fileName,
  revision: _revision,
  relativePath: '.managed/$_revision/${artifact.fileName}',
  origin: ArtifactOrigin.managedCatalog,
  sha256: _hash,
  cloudCapable: cloudCapable,
);

Map<String, dynamic> _authority({required List<TrustedArtifact> artifacts}) =>
    _authorityAt(_revision, artifacts);

Map<String, dynamic> _authorityAt(
  String revision,
  List<TrustedArtifact> artifacts,
) => TrustedAuthority(
  catalogId: TrustedCatalog.maintainedCatalogId,
  activeRevision: revision,
  artifacts: artifacts,
).toJson();

Map<String, dynamic> _snapshot({
  required String revision,
  required List<TrustedArtifact> artifacts,
  required List<Map<String, dynamic>> observations,
}) => {
  'authority': _authorityAt(revision, artifacts),
  'generatedAt': '2026-09-05T00:00:00.000Z',
  'observations': observations,
};

List<int> _fullIndex() => utf8.encode(
  jsonEncode([
    {
      'key': _manwa.sourceKey,
      'fileName': _manwa.fileName,
      'cloudTracking': {'scanner': 'scanner.js'},
    },
    {'key': _localOnly.sourceKey, 'fileName': _localOnly.fileName},
  ]),
);

Map<String, dynamic> _observation(
  TrustedArtifact artifact,
  String revision,
  String comicId,
) => {
  'revision': revision,
  'artifact': artifact.toJson(),
  'comicId': comicId,
  'observedAt': '2026-09-05T00:00:00.000Z',
  'validUntil': '2099-09-05T00:00:00.000Z',
  'favoriteUpdate': {'sourceUnread': true},
};

TrackingHttpResponse _jsonResponse(Object data) => TrackingHttpResponse(
  statusCode: 200,
  headers: const {},
  body: jsonEncode({'data': data}),
);

class _QueueTransport implements TrackingHttpTransport {
  _QueueTransport(this.responses);

  final List<TrackingHttpResponse> responses;
  final requests = <String>[];
  final requestBodies = <String?>[];

  @override
  Future<TrackingHttpResponse> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    requests.add('$method $path');
    requestBodies.add(body);
    if (responses.isEmpty) throw StateError('unexpected tracking request');
    return responses.removeAt(0);
  }
}

class _FailingTransport implements TrackingHttpTransport {
  @override
  Future<TrackingHttpResponse> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    throw StateError('tracking server unavailable');
  }
}

class _BlockingAuthorityTransport implements TrackingHttpTransport {
  final authorityResponse = Completer<TrackingHttpResponse>();
  final authorityStarted = Completer<void>();
  final requests = <String>[];
  final requestBodies = <String?>[];
  final List<TrackingHttpResponse> responses = [];
  bool _blocked = false;

  @override
  Future<TrackingHttpResponse> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    requests.add('$method $path');
    requestBodies.add(body);
    if (method == 'GET' && path == '/api/tracking/authority' && !_blocked) {
      _blocked = true;
      authorityStarted.complete();
      return authorityResponse.future;
    }
    if (responses.isEmpty) throw StateError('unexpected tracking request');
    return responses.removeAt(0);
  }
}

class _BlockingClientStateTransport implements TrackingHttpTransport {
  final clientStateResponse = Completer<TrackingHttpResponse>();
  final clientStateStarted = Completer<void>();
  final requests = <String>[];
  final requestBodies = <String?>[];
  final List<TrackingHttpResponse> responses = [];
  bool _blocked = false;

  @override
  Future<TrackingHttpResponse> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    requests.add('$method $path');
    requestBodies.add(body);
    if (method == 'PUT' && path == '/api/tracking/client-state' && !_blocked) {
      _blocked = true;
      clientStateStarted.complete();
      return clientStateResponse.future;
    }
    if (responses.isEmpty) throw StateError('unexpected tracking request');
    return responses.removeAt(0);
  }
}

class _InvalidatingApplyStore implements TrackingApplyStore {
  _InvalidatingApplyStore(this.generations, this.artifact);

  final RuntimeGenerationController generations;
  final TrustedArtifact artifact;
  final committedSources = <String>[];
  var rollbackCount = 0;
  var invalidated = false;

  @override
  TrackingApplyTransaction beginTrackingTransaction() =>
      _InvalidatingApplyTransaction(this);
}

class _InvalidatingApplyTransaction implements TrackingApplyTransaction {
  _InvalidatingApplyTransaction(this.owner);

  final _InvalidatingApplyStore owner;
  final pendingSources = <String>[];
  bool closed = false;

  @override
  TrackingBaseline? readBaseline(String sourceKey, String comicId) => null;

  @override
  void writeBaseline(
    String sourceKey,
    String comicId,
    TrackingBaseline baseline,
  ) {
    if (!owner.invalidated) {
      owner.invalidated = true;
      owner.generations.invalidate(owner.artifact);
    }
    pendingSources.add(sourceKey);
  }

  @override
  void commit() {
    if (closed) throw StateError('transaction already closed');
    owner.committedSources.addAll(pendingSources);
    closed = true;
  }

  @override
  void rollback() {
    closed = true;
    pendingSources.clear();
    owner.rollbackCount++;
  }
}

class _SelectiveApplyStore implements TrackingApplyStore {
  _SelectiveApplyStore(this.failSourceKey);

  final String? failSourceKey;
  final committedSources = <String>[];

  @override
  TrackingApplyTransaction beginTrackingTransaction() =>
      _SelectiveApplyTransaction(this);
}

class _SelectiveApplyTransaction implements TrackingApplyTransaction {
  _SelectiveApplyTransaction(this.owner);

  final _SelectiveApplyStore owner;
  final pendingSources = <String>[];
  bool closed = false;

  @override
  TrackingBaseline? readBaseline(String sourceKey, String comicId) {
    if (sourceKey == owner.failSourceKey) {
      throw StateError('injected apply failure');
    }
    return null;
  }

  @override
  void writeBaseline(
    String sourceKey,
    String comicId,
    TrackingBaseline baseline,
  ) {
    pendingSources.add(sourceKey);
  }

  @override
  void commit() {
    if (closed) throw StateError('transaction already closed');
    owner.committedSources.addAll(pendingSources);
    closed = true;
  }

  @override
  void rollback() {
    closed = true;
    pendingSources.clear();
  }
}

void main() {
  late Directory tempDir;
  late NetworkFavoriteCacheManager favorites;
  late SourceRevisionManager revisions;
  late Map<String, dynamic> previousSettings;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'venera-cloud-coordinator-',
    );
    favorites = NetworkFavoriteCacheManager.forTesting();
    await favorites.init(
      databasePath: '${tempDir.path}${Platform.pathSeparator}favorites.db',
      migrateLegacy: false,
    );
    final sourceDirectory = Directory(
      '${tempDir.path}${Platform.pathSeparator}comic_source',
    );
    final store = SourceRevisionStore(sourceDirectory);
    await store.save(
      ActiveArtifactRegistry(
        artifacts: [
          _active(_manwa, cloudCapable: true),
          _active(_localOnly, cloudCapable: false),
        ],
      ),
    );
    revisions = SourceRevisionManager(store: store);

    previousSettings = {
      'followUpdatesEnabled': appdata.settings['followUpdatesEnabled'],
      'cloudTrackingEnabled': appdata.settings['cloudTrackingEnabled'],
      'cloudTrackingServerUrl': appdata.settings['cloudTrackingServerUrl'],
      'cloudTrackingAccessToken': appdata.settings['cloudTrackingAccessToken'],
    };
    appdata.settings['followUpdatesEnabled'] = true;
    appdata.settings['cloudTrackingEnabled'] = true;
    appdata.settings['cloudTrackingServerUrl'] = 'https://tracking.invalid';
    appdata.settings['cloudTrackingAccessToken'] = '';
  });

  tearDown(() {
    for (final entry in previousSettings.entries) {
      appdata.settings[entry.key] = entry.value;
    }
    favorites.close();
    tempDir.deleteSync(recursive: true);
  });

  test(
    'composes authority into aligned Cloud and Local-only statuses',
    () async {
      final authority = _authority(artifacts: const [_manwa]);
      final transport = _QueueTransport([
        _jsonResponse(authority),
        _jsonResponse({
          'cloudEnabled': true,
          'interests': const [],
          'stateRevision': 1,
          'updatedAt': '2026-09-03T00:00:00.000Z',
        }),
        _jsonResponse({
          'authority': authority,
          'generatedAt': '2026-09-03T00:00:00.000Z',
          'observations': const [],
        }),
      ]);
      final client = CloudTrackingClient(
        server: Uri.parse('https://tracking.invalid'),
        transport: transport,
      );
      final coordinator = CloudTrackingCoordinator(
        favorites: favorites,
        sourceDirectory: Directory(
          '${tempDir.path}${Platform.pathSeparator}comic_source',
        ),
        revisions: revisions,
        clientFactory: (_, _) => client,
        artifactFetcher: (uri) async => uri.path.endsWith('/index.json')
            ? _fullIndex()
            : utf8.encode('candidate'),
        runtimeReloader: (_) async {},
        pollInterval: const Duration(hours: 1),
      );
      addTearDown(coordinator.dispose);

      await coordinator.start();
      final statuses = await coordinator.statuses();

      final manwaStatus = statuses.singleWhere(
        (item) => item.artifact == _manwa,
      );
      final localStatus = statuses.singleWhere(
        (item) => item.artifact == _localOnly,
      );
      expect(manwaStatus.strategy, TrackingStrategy.cloud);
      expect(manwaStatus.reason, 'Cloud artifact is aligned.');
      expect(localStatus.strategy, TrackingStrategy.local);
      expect(localStatus.reason, contains('pinned'));
      expect(transport.requests, [
        'GET /api/tracking/authority',
        'PUT /api/tracking/client-state',
        'GET /api/tracking/observations',
      ]);

      transport.responses.addAll([
        _jsonResponse(authority),
        _jsonResponse({
          'cloudEnabled': false,
          'interests': const [],
          'stateRevision': 2,
          'updatedAt': '2026-09-03T00:01:00.000Z',
        }),
      ]);
      appdata.settings['cloudTrackingEnabled'] = false;
      await coordinator.onSettingsChanged();
      expect(transport.requests, [
        'GET /api/tracking/authority',
        'PUT /api/tracking/client-state',
        'GET /api/tracking/observations',
        'GET /api/tracking/authority',
        'PUT /api/tracking/client-state',
      ]);
      final disabledState = jsonDecode(transport.requestBodies.last!);
      expect(disabledState['cloudEnabled'], isFalse);
      final statusesAfterDisable = await coordinator.statuses();
      expect(
        statusesAfterDisable
            .singleWhere((item) => item.artifact == _manwa)
            .strategy,
        TrackingStrategy.local,
      );
    },
  );

  test(
    'pauses a capable artifact on authority failure without Local fallback',
    () async {
      final client = CloudTrackingClient(
        server: Uri.parse('https://tracking.invalid'),
        transport: _FailingTransport(),
      );
      final coordinator = CloudTrackingCoordinator(
        favorites: favorites,
        sourceDirectory: Directory(
          '${tempDir.path}${Platform.pathSeparator}comic_source',
        ),
        revisions: revisions,
        clientFactory: (_, _) => client,
        pollInterval: const Duration(hours: 1),
      );
      addTearDown(coordinator.dispose);

      await coordinator.start();
      final statuses = await coordinator.statuses();
      final manwaStatus = statuses.singleWhere(
        (item) => item.artifact == _manwa,
      );
      final localStatus = statuses.singleWhere(
        (item) => item.artifact == _localOnly,
      );

      expect(manwaStatus.strategy, TrackingStrategy.pausedCloud);
      expect(
        manwaStatus.reason,
        'Cloud tracking is paused: Server authority is unavailable.',
      );
      expect(localStatus.strategy, TrackingStrategy.pausedCloud);
      expect(localStatus.reason, contains('Server authority'));
    },
  );

  test(
    'pauses an installed artifact missing from the trusted catalog',
    () async {
      final sourceDirectory = Directory(
        '${tempDir.path}${Platform.pathSeparator}missing-catalog',
      );
      final store = SourceRevisionStore(sourceDirectory);
      await store.save(
        ActiveArtifactRegistry(
          artifacts: [
            _active(_manwa, cloudCapable: true),
            _active(_localOnly, cloudCapable: false),
          ],
        ),
      );
      final authority = _authorityAt(_revisionB, const [_manwa]);
      final index = utf8.encode(
        jsonEncode([
          {
            'key': 'manwa',
            'fileName': 'manwa.js',
            'cloudTracking': {'scanner': 'scanner.js'},
          },
        ]),
      );
      final reloads = <ActiveArtifact>[];
      final coordinator = CloudTrackingCoordinator(
        favorites: favorites,
        sourceDirectory: sourceDirectory,
        revisions: SourceRevisionManager(store: store),
        clientFactory: (_, _) => CloudTrackingClient(
          server: Uri.parse('https://tracking.invalid'),
          transport: _QueueTransport([
            _jsonResponse(authority),
            _jsonResponse({
              'cloudEnabled': true,
              'interests': const [],
              'stateRevision': 1,
              'updatedAt': '2026-09-05T00:00:00.000Z',
            }),
            _jsonResponse({
              'authority': authority,
              'generatedAt': '2026-09-05T00:00:00.000Z',
              'observations': const [],
            }),
          ]),
        ),
        artifactFetcher: (uri) async => uri.path.endsWith('/index.json')
            ? index
            : utf8.encode('candidate-r2'),
        sourceKeyResolver: (_, path) async =>
            path.contains('copy_manga') ? 'copy_manga' : 'manwa',
        runtimeReloader: (artifact) async => reloads.add(artifact),
        pollInterval: const Duration(hours: 1),
      );
      addTearDown(coordinator.dispose);

      await coordinator.start();

      final missing = (await coordinator.statuses()).singleWhere(
        (item) => item.artifact == _localOnly,
      );
      expect(missing.strategy, TrackingStrategy.pausedCloud);
      expect(missing.reason, 'Artifact is missing from the trusted catalog.');
      expect(missing.activationBlocked, isTrue);
      expect(reloads.where((item) => item.identity == _localOnly), isEmpty);
    },
  );

  test('coalesces Cloud-off behind an in-flight authority response', () async {
    final authority = _authority(artifacts: const [_manwa]);
    final transport = _BlockingAuthorityTransport();
    final client = CloudTrackingClient(
      server: Uri.parse('https://tracking.invalid'),
      transport: transport,
    );
    final coordinator = CloudTrackingCoordinator(
      favorites: favorites,
      sourceDirectory: Directory(
        '${tempDir.path}${Platform.pathSeparator}comic_source',
      ),
      revisions: revisions,
      clientFactory: (_, _) => client,
      pollInterval: const Duration(hours: 1),
    );
    addTearDown(coordinator.dispose);

    final starting = coordinator.start();
    await transport.authorityStarted.future;
    appdata.settings['cloudTrackingEnabled'] = false;
    transport.responses.addAll([
      _jsonResponse(authority),
      _jsonResponse({
        'cloudEnabled': false,
        'interests': const [],
        'stateRevision': 2,
        'updatedAt': '2026-09-05T00:01:00.000Z',
      }),
    ]);
    final changed = coordinator.onSettingsChanged();
    transport.authorityResponse.complete(_jsonResponse(authority));
    await Future.wait([starting, changed]);

    expect(transport.requests, [
      'GET /api/tracking/authority',
      'GET /api/tracking/authority',
      'PUT /api/tracking/client-state',
    ]);
    expect(
      transport.requestBodies.where(
        (body) => body != null && body.contains('"cloudEnabled":true'),
      ),
      isEmpty,
    );
    expect(coordinator.modes.cloudEnabled, isFalse);
    // This transport fixture has registry pointers but no verified source
    // bytes. Cloud-off must not turn those pointers into executable runtimes.
    expect(coordinator.modes.strategyFor(_manwa), TrackingStrategy.pausedCloud);
  });

  test('does not restore Cloud after a late client-state response', () async {
    final authority = _authority(artifacts: const [_manwa]);
    final transport = _BlockingClientStateTransport();
    transport.responses.add(_jsonResponse(authority));
    final client = CloudTrackingClient(
      server: Uri.parse('https://tracking.invalid'),
      transport: transport,
    );
    final coordinator = CloudTrackingCoordinator(
      favorites: favorites,
      sourceDirectory: Directory(
        '${tempDir.path}${Platform.pathSeparator}comic_source',
      ),
      revisions: revisions,
      clientFactory: (_, _) => client,
      artifactFetcher: (uri) async => uri.path.endsWith('/index.json')
          ? _fullIndex()
          : utf8.encode('candidate'),
      runtimeReloader: (_) async {},
      pollInterval: const Duration(hours: 1),
    );
    addTearDown(coordinator.dispose);

    final starting = coordinator.start();
    await transport.clientStateStarted.future;
    appdata.settings['cloudTrackingEnabled'] = false;
    transport.responses.addAll([
      _jsonResponse(authority),
      _jsonResponse({
        'cloudEnabled': false,
        'interests': const [],
        'stateRevision': 2,
        'updatedAt': '2026-09-05T00:02:00.000Z',
      }),
    ]);
    final changed = coordinator.onSettingsChanged();
    transport.clientStateResponse.complete(
      _jsonResponse({
        'cloudEnabled': true,
        'interests': const [],
        'stateRevision': 1,
        'updatedAt': '2026-09-05T00:01:00.000Z',
      }),
    );
    await Future.wait([starting, changed]);

    expect(
      transport.requestBodies.where(
        (body) => body != null && body.contains('"cloudEnabled":true'),
      ),
      hasLength(1),
    );
    expect(jsonDecode(transport.requestBodies.last!)['cloudEnabled'], isFalse);
    expect(coordinator.modes.strategyFor(_manwa), TrackingStrategy.local);
  });

  test(
    'reloads the exact pinned R2 artifact before activating its generation',
    () async {
      final authority = _authorityAt(_revisionB, const [_manwa]);
      final bytes = utf8.encode('candidate-r2');
      final reloads = <ActiveArtifact>[];
      final index = utf8.encode(
        jsonEncode([
          {
            'key': 'manwa',
            'fileName': 'manwa.js',
            'cloudTracking': {'scanner': 'scanner.js'},
          },
        ]),
      );
      final coordinator = CloudTrackingCoordinator(
        favorites: favorites,
        sourceDirectory: Directory(
          '${tempDir.path}${Platform.pathSeparator}comic_source',
        ),
        revisions: revisions,
        clientFactory: (_, _) => CloudTrackingClient(
          server: Uri.parse('https://tracking.invalid'),
          transport: _QueueTransport([
            _jsonResponse(authority),
            _jsonResponse({
              'cloudEnabled': true,
              'interests': const [],
              'stateRevision': 1,
              'updatedAt': '2026-09-05T00:00:00.000Z',
            }),
            _jsonResponse({
              'authority': authority,
              'generatedAt': '2026-09-05T00:00:00.000Z',
              'observations': const [],
            }),
          ]),
        ),
        artifactFetcher: (uri) async =>
            uri.path.endsWith('/index.json') ? index : bytes,
        sourceKeyResolver: (_, _) async => 'manwa',
        runtimeReloader: (artifact) async => reloads.add(artifact),
        pollInterval: const Duration(hours: 1),
      );
      addTearDown(coordinator.dispose);

      await coordinator.start();

      expect(reloads.map((item) => item.revision), [_revisionB]);
      expect(
        (await revisions.current()).find('manwa', 'manwa.js')?.revision,
        _revisionB,
      );
      expect(
        (await coordinator.statuses())
            .singleWhere((item) => item.artifact == _manwa)
            .strategy,
        TrackingStrategy.cloud,
      );
    },
  );

  test(
    'restores R1 when Cloud turns off during catalog fetch after activation',
    () async {
      final authority = _authorityAt(_revisionB, const [_manwa]);
      final index = utf8.encode(
        jsonEncode([
          {
            'key': 'manwa',
            'fileName': 'manwa.js',
            'cloudTracking': {'scanner': 'scanner.js'},
          },
        ]),
      );
      var changed = false;
      late CloudTrackingCoordinator coordinator;
      final reloads = <ActiveArtifact>[];
      coordinator = CloudTrackingCoordinator(
        favorites: favorites,
        sourceDirectory: Directory(
          '${tempDir.path}${Platform.pathSeparator}comic_source',
        ),
        revisions: revisions,
        clientFactory: (_, _) => CloudTrackingClient(
          server: Uri.parse('https://tracking.invalid'),
          transport: _QueueTransport([_jsonResponse(authority)]),
        ),
        artifactFetcher: (uri) async {
          if (uri.path.endsWith('/index.json') && !changed) {
            changed = true;
            appdata.settings['cloudTrackingEnabled'] = false;
            appdata.settings['cloudTrackingServerUrl'] = '';
            coordinator.beforeArtifactsChange();
          }
          return uri.path.endsWith('/index.json')
              ? index
              : utf8.encode('candidate-r2');
        },
        sourceKeyResolver: (_, _) async => 'manwa',
        runtimeReloader: (artifact) async => reloads.add(artifact),
        pollInterval: const Duration(hours: 1),
      );
      addTearDown(coordinator.dispose);

      await coordinator.start();

      expect(
        (await revisions.current()).find('manwa', 'manwa.js')?.revision,
        _revision,
      );
      expect(reloads, isEmpty);
      expect(coordinator.modes.strategyFor(_manwa), TrackingStrategy.local);
    },
  );

  test(
    'restores R1 when the operation epoch changes at pointer commit',
    () async {
      final authority = _authorityAt(_revisionB, const [_manwa]);
      final index = utf8.encode(
        jsonEncode([
          {
            'key': 'manwa',
            'fileName': 'manwa.js',
            'cloudTracking': {'scanner': 'scanner.js'},
          },
        ]),
      );
      var changed = false;
      late CloudTrackingCoordinator coordinator;
      final sourceDirectory = Directory(
        '${tempDir.path}${Platform.pathSeparator}comic_source',
      );
      final store = SourceRevisionStore(
        sourceDirectory,
        atomicReplace: (source, target) async {
          if (target.path.endsWith('active-artifacts.json') && !changed) {
            changed = true;
            appdata.settings['cloudTrackingEnabled'] = false;
            appdata.settings['cloudTrackingServerUrl'] = '';
            coordinator.beforeArtifactsChange();
          }
          await source.rename(target.path);
        },
      );
      final localRevisions = SourceRevisionManager(store: store);
      final reloads = <ActiveArtifact>[];
      coordinator = CloudTrackingCoordinator(
        favorites: favorites,
        sourceDirectory: sourceDirectory,
        revisions: localRevisions,
        clientFactory: (_, _) => CloudTrackingClient(
          server: Uri.parse('https://tracking.invalid'),
          transport: _QueueTransport([_jsonResponse(authority)]),
        ),
        artifactFetcher: (uri) async => uri.path.endsWith('/index.json')
            ? index
            : utf8.encode('candidate-r2'),
        sourceKeyResolver: (_, _) async => 'manwa',
        runtimeReloader: (artifact) async => reloads.add(artifact),
        pollInterval: const Duration(hours: 1),
      );
      addTearDown(coordinator.dispose);

      await coordinator.start();

      expect(
        (await localRevisions.current()).find('manwa', 'manwa.js')?.revision,
        _revision,
      );
      expect(
        (await store.loadLastKnownGood())?.find('manwa', 'manwa.js')?.revision,
        _revision,
      );
      expect(reloads.map((item) => item.revision), [_revision]);
      expect(coordinator.modes.strategyFor(_manwa), TrackingStrategy.local);
    },
  );

  test('restores R1 when Cloud changes after catalog validation', () async {
    final authority = _authorityAt(_revisionB, const [_manwa]);
    final sourceDirectory = Directory(
      '${tempDir.path}${Platform.pathSeparator}validated',
    );
    final store = SourceRevisionStore(sourceDirectory);
    await store.save(
      ActiveArtifactRegistry(artifacts: [_active(_manwa, cloudCapable: true)]),
    );
    sourceRuntimePolicy.prepare(
      cloudEnabled: true,
      registry: (await store.load())!,
      sourceDirectoryPath: sourceDirectory.path,
    );
    final index = utf8.encode(
      jsonEncode([
        {
          'key': 'manwa',
          'fileName': 'manwa.js',
          'cloudTracking': {'scanner': 'scanner.js'},
        },
      ]),
    );
    var validated = false;
    late CloudTrackingCoordinator coordinator;
    final reloads = <ActiveArtifact>[];
    coordinator = CloudTrackingCoordinator(
      favorites: favorites,
      sourceDirectory: sourceDirectory,
      revisions: SourceRevisionManager(store: store),
      clientFactory: (_, _) => CloudTrackingClient(
        server: Uri.parse('https://tracking.invalid'),
        transport: _QueueTransport([_jsonResponse(authority)]),
      ),
      artifactFetcher: (uri) async => uri.path.endsWith('/index.json')
          ? index
          : utf8.encode('candidate-r2'),
      sourceKeyResolver: (_, _) async {
        if (!validated) {
          validated = true;
          appdata.settings['cloudTrackingEnabled'] = false;
          appdata.settings['cloudTrackingServerUrl'] = '';
          coordinator.beforeArtifactsChange();
        }
        return 'manwa';
      },
      runtimeReloader: (artifact) async => reloads.add(artifact),
      pollInterval: const Duration(hours: 1),
    );
    addTearDown(coordinator.dispose);

    await coordinator.start();

    expect(validated, isTrue);
    expect(
      (await coordinator.revisions.current())
          .find('manwa', 'manwa.js')
          ?.revision,
      _revision,
    );
    expect(reloads.map((item) => item.revision), [_revision]);
    expect(coordinator.modes.strategyFor(_manwa), TrackingStrategy.local);
  });

  test(
    'restores R1 when the epoch changes after pointer replacement or block clear',
    () async {
      final authority = _authorityAt(_revisionB, const [_manwa]);
      final index = utf8.encode(
        jsonEncode([
          {
            'key': 'manwa',
            'fileName': 'manwa.js',
            'cloudTracking': {'scanner': 'scanner.js'},
          },
        ]),
      );

      for (final stage in const [
        'pointerReplaced',
        'activationBlockedCleared',
      ]) {
        appdata.settings['cloudTrackingEnabled'] = true;
        appdata.settings['cloudTrackingServerUrl'] = 'https://tracking.invalid';
        final sourceDirectory = Directory(
          '${tempDir.path}${Platform.pathSeparator}$stage',
        );
        var changed = false;
        var coordinatorReady = false;
        late CloudTrackingCoordinator coordinator;
        final reloads = <ActiveArtifact>[];
        final store = SourceRevisionStore(
          sourceDirectory,
          atomicReplace: (source, target) async {
            final replacement = await source.readAsString();
            await source.rename(target.path);
            if (coordinatorReady &&
                target.path.endsWith('active-artifacts.json') &&
                !changed) {
              final isPointerReplacement = stage == 'pointerReplaced';
              final isBlockClear =
                  stage == 'activationBlockedCleared' &&
                  replacement.contains('"revision":"$_revisionB"') &&
                  !replacement.contains('"activationBlocked":true');
              if (isPointerReplacement || isBlockClear) {
                changed = true;
                appdata.settings['cloudTrackingEnabled'] = false;
                appdata.settings['cloudTrackingServerUrl'] = '';
                coordinator.beforeArtifactsChange();
              }
            }
          },
        );
        await store.save(
          ActiveArtifactRegistry(
            artifacts: [_active(_manwa, cloudCapable: true)],
          ),
        );
        sourceRuntimePolicy.prepare(
          cloudEnabled: true,
          registry: (await store.load())!,
          sourceDirectoryPath: sourceDirectory.path,
        );
        final localRevisions = SourceRevisionManager(store: store);
        coordinator = CloudTrackingCoordinator(
          favorites: favorites,
          sourceDirectory: sourceDirectory,
          revisions: localRevisions,
          clientFactory: (_, _) => CloudTrackingClient(
            server: Uri.parse('https://tracking.invalid'),
            transport: _QueueTransport([_jsonResponse(authority)]),
          ),
          artifactFetcher: (uri) async => uri.path.endsWith('/index.json')
              ? index
              : utf8.encode('candidate-r2'),
          sourceKeyResolver: (_, _) async => 'manwa',
          runtimeReloader: (artifact) async => reloads.add(artifact),
          pollInterval: const Duration(hours: 1),
        );
        coordinatorReady = true;
        addTearDown(coordinator.dispose);

        try {
          await coordinator.start();

          expect(
            (await localRevisions.current())
                .find('manwa', 'manwa.js')
                ?.revision,
            _revision,
          );
          expect(
            (await store.loadLastKnownGood())
                ?.find('manwa', 'manwa.js')
                ?.revision,
            _revision,
          );
          expect(
            reloads.map((item) => item.revision),
            stage == 'pointerReplaced' ? [_revision] : [_revisionB, _revision],
          );
          expect(coordinator.modes.strategyFor(_manwa), TrackingStrategy.local);
        } finally {
          coordinator.dispose();
        }
      }
    },
  );

  test('restores R1 when Cloud turns off during R2 runtime reload', () async {
    final authority = _authorityAt(_revisionB, const [_manwa]);
    final index = utf8.encode(
      jsonEncode([
        {
          'key': 'manwa',
          'fileName': 'manwa.js',
          'cloudTracking': {'scanner': 'scanner.js'},
        },
      ]),
    );
    var changed = false;
    late CloudTrackingCoordinator coordinator;
    final reloads = <ActiveArtifact>[];
    coordinator = CloudTrackingCoordinator(
      favorites: favorites,
      sourceDirectory: Directory(
        '${tempDir.path}${Platform.pathSeparator}comic_source',
      ),
      revisions: revisions,
      clientFactory: (_, _) => CloudTrackingClient(
        server: Uri.parse('https://tracking.invalid'),
        transport: _QueueTransport([_jsonResponse(authority)]),
      ),
      artifactFetcher: (uri) async => uri.path.endsWith('/index.json')
          ? index
          : utf8.encode('candidate-r2'),
      sourceKeyResolver: (_, _) async => 'manwa',
      runtimeReloader: (artifact) async {
        reloads.add(artifact);
        if (artifact.revision == _revisionB && !changed) {
          changed = true;
          appdata.settings['cloudTrackingEnabled'] = false;
          appdata.settings['cloudTrackingServerUrl'] = '';
          coordinator.beforeArtifactsChange();
        }
      },
      pollInterval: const Duration(hours: 1),
    );
    addTearDown(coordinator.dispose);

    await coordinator.start();

    expect(
      (await revisions.current()).find('manwa', 'manwa.js')?.revision,
      _revision,
    );
    expect(reloads.map((item) => item.revision), [_revisionB, _revision]);
    expect(coordinator.modes.strategyFor(_manwa), TrackingStrategy.local);
  });

  test('pauses only the artifact whose R2 runtime activation fails', () async {
    final sourceDirectory = Directory(
      '${tempDir.path}${Platform.pathSeparator}comic_source',
    );
    final store = SourceRevisionStore(sourceDirectory);
    await store.save(
      ActiveArtifactRegistry(
        artifacts: [
          _active(_manwa, cloudCapable: true),
          _active(_localOnly, cloudCapable: true),
        ],
      ),
    );
    final localRevisions = SourceRevisionManager(store: store);
    final authority = _authorityAt(_revisionB, const [_manwa, _localOnly]);
    final index = utf8.encode(
      jsonEncode([
        {
          'key': 'manwa',
          'fileName': 'manwa.js',
          'cloudTracking': {'scanner': 'scanner.js'},
        },
        {
          'key': 'copy_manga',
          'fileName': 'copy_manga.js',
          'cloudTracking': {'scanner': 'scanner.js'},
        },
      ]),
    );
    final reloads = <ActiveArtifact>[];
    final coordinator = CloudTrackingCoordinator(
      favorites: favorites,
      sourceDirectory: sourceDirectory,
      revisions: localRevisions,
      clientFactory: (_, _) => CloudTrackingClient(
        server: Uri.parse('https://tracking.invalid'),
        transport: _QueueTransport([
          _jsonResponse(authority),
          _jsonResponse({
            'cloudEnabled': true,
            'interests': const [],
            'stateRevision': 1,
            'updatedAt': '2026-09-05T00:00:00.000Z',
          }),
          _jsonResponse({
            'authority': authority,
            'generatedAt': '2026-09-05T00:00:00.000Z',
            'observations': const [],
          }),
        ]),
      ),
      artifactFetcher: (uri) async => uri.path.endsWith('/index.json')
          ? index
          : utf8.encode('candidate-${uri.pathSegments.last}'),
      sourceKeyResolver: (source, path) async =>
          path.contains('copy_manga') ? 'copy_manga' : 'manwa',
      runtimeReloader: (artifact) async {
        reloads.add(artifact);
        if (artifact.identity == _localOnly &&
            artifact.revision == _revisionB) {
          throw StateError('injected copy_manga reload failure');
        }
      },
      pollInterval: const Duration(hours: 1),
    );
    addTearDown(coordinator.dispose);

    await coordinator.start();
    final statuses = await coordinator.statuses();

    expect(
      statuses.singleWhere((item) => item.artifact == _manwa).strategy,
      TrackingStrategy.cloud,
    );
    final localStatus = statuses.singleWhere(
      (item) => item.artifact == _localOnly,
    );
    expect(localStatus.strategy, TrackingStrategy.pausedCloud);
    expect(localStatus.reason, contains('activation failed'));
    expect(
      reloads.where(
        (artifact) =>
            artifact.identity == _manwa && artifact.revision == _revisionB,
      ),
      hasLength(1),
    );
    expect(
      reloads.where(
        (artifact) =>
            artifact.identity == _localOnly && artifact.revision == _revision,
      ),
      hasLength(0),
    );
    final failedSelection = (await coordinator.revisions.current()).find(
      _localOnly.sourceKey,
      _localOnly.fileName,
    );
    expect(failedSelection?.revision, _revision);
    expect(failedSelection?.activationBlocked, isTrue);
  });

  test(
    'notifies the cache once per committed Cloud artifact snapshot',
    () async {
      final sourceDirectory = Directory(
        '${tempDir.path}${Platform.pathSeparator}comic_source',
      );
      final store = SourceRevisionStore(sourceDirectory);
      await store.save(
        ActiveArtifactRegistry(
          artifacts: [
            _active(_manwa, cloudCapable: true),
            _active(_localOnly, cloudCapable: true),
          ],
        ),
      );
      final localRevisions = SourceRevisionManager(store: store);
      favorites.replaceComicMembership('manwa', '42', const ['folder']);
      favorites.replaceComicMembership('copy_manga', '84', const ['folder']);
      var notifications = 0;
      favorites.addListener(() => notifications++);
      final applyStore = _SelectiveApplyStore('copy_manga');
      final authority = _authority(artifacts: const [_manwa, _localOnly]);
      final transport = _QueueTransport([
        _jsonResponse(authority),
        _jsonResponse({
          'cloudEnabled': true,
          'interests': const [],
          'stateRevision': 1,
          'updatedAt': '2026-09-05T00:00:00.000Z',
        }),
        _jsonResponse(
          _snapshot(
            revision: _revision,
            artifacts: const [_manwa, _localOnly],
            observations: [
              _observation(_manwa, _revision, '42'),
              _observation(_localOnly, _revision, '84'),
            ],
          ),
        ),
      ]);
      final coordinator = CloudTrackingCoordinator(
        favorites: favorites,
        sourceDirectory: sourceDirectory,
        revisions: localRevisions,
        applyStore: applyStore,
        clientFactory: (_, _) => CloudTrackingClient(
          server: Uri.parse('https://tracking.invalid'),
          transport: transport,
        ),
        artifactFetcher: (uri) async => uri.path.endsWith('/index.json')
            ? _fullIndex()
            : utf8.encode('candidate'),
        runtimeReloader: (_) async {},
        pollInterval: const Duration(hours: 1),
      );
      addTearDown(coordinator.dispose);

      await coordinator.start();

      expect(applyStore.committedSources, ['manwa']);
      expect(notifications, 1);
      expect(
        (await coordinator.statuses())
            .singleWhere((item) => item.artifact == _manwa)
            .strategy,
        TrackingStrategy.cloud,
      );
      expect(
        (await coordinator.statuses())
            .singleWhere((item) => item.artifact == _localOnly)
            .strategy,
        TrackingStrategy.local,
      );
    },
  );

  test(
    'rejects a generation invalidated immediately before apply commit',
    () async {
      final sourceDirectory = Directory(
        '${tempDir.path}${Platform.pathSeparator}apply-fence',
      );
      final store = SourceRevisionStore(sourceDirectory);
      await store.save(
        ActiveArtifactRegistry(
          artifacts: [_active(_manwa, cloudCapable: true)],
        ),
      );
      favorites.replaceComicMembership('manwa', '42', const ['folder']);
      final generations = RuntimeGenerationController();
      final applyStore = _InvalidatingApplyStore(generations, _manwa);
      final authority = _authority(artifacts: const [_manwa]);
      final transport = _QueueTransport([
        _jsonResponse(authority),
        _jsonResponse({
          'cloudEnabled': true,
          'interests': const [],
          'stateRevision': 1,
          'updatedAt': '2026-09-05T00:05:00.000Z',
        }),
        _jsonResponse(
          _snapshot(
            revision: _revision,
            artifacts: const [_manwa],
            observations: [_observation(_manwa, _revision, '42')],
          ),
        ),
      ]);
      final coordinator = CloudTrackingCoordinator(
        favorites: favorites,
        sourceDirectory: sourceDirectory,
        revisions: SourceRevisionManager(store: store),
        generations: generations,
        applyStore: applyStore,
        clientFactory: (_, _) => CloudTrackingClient(
          server: Uri.parse('https://tracking.invalid'),
          transport: transport,
        ),
        artifactFetcher: (uri) async => uri.path.endsWith('/index.json')
            ? _fullIndex()
            : utf8.encode('candidate'),
        runtimeReloader: (_) async {},
        pollInterval: const Duration(hours: 1),
      );
      addTearDown(coordinator.dispose);

      await coordinator.start();

      expect(applyStore.invalidated, isTrue);
      expect(applyStore.committedSources, isEmpty);
      expect(applyStore.rollbackCount, 1);
      final status = (await coordinator.statuses()).singleWhere(
        (item) => item.artifact == _manwa,
      );
      expect(status.strategy, TrackingStrategy.pausedCloud);
      expect(status.reason, contains('apply failed'));
    },
  );
}
