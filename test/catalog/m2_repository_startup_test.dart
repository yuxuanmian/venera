import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/controller.dart';
import 'package:venera/foundation/catalog/http_client.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/runtime_loader.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';
import 'package:venera/foundation/catalog/store.dart';

class _Environment {
  _Environment._({
    required this.root,
    required this.wasInitialized,
    required this.oldDataPath,
    required this.appdata,
    required this.store,
  });

  final Directory root;
  final bool wasInitialized;
  final String? oldDataPath;
  final Appdata appdata;
  final CatalogStore store;

  static Future<_Environment> create() async {
    final wasInitialized = App.isInitialized;
    final oldDataPath = wasInitialized ? App.dataPath : null;
    final root = await Directory.systemTemp.createTemp('catalog-m2-');
    App.dataPath = root.path;
    final target = Appdata.createForTesting(() async => root);
    return _Environment._(
      root: root,
      wasInitialized: wasInitialized,
      oldDataPath: oldDataPath,
      appdata: target,
      store: CatalogStore(Directory(p.join(root.path, 'catalog'))),
    );
  }

  Future<void> dispose() async {
    if (wasInitialized) {
      App.dataPath = oldDataPath!;
    } else {
      App.isInitialized = false;
    }
    for (var attempt = 0; attempt < 10; attempt++) {
      if (!await root.exists()) return;
      try {
        await root.delete(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  }
}

class _Transport implements CatalogTransport {
  _Transport(this.handler);

  final FutureOr<CatalogBytesResponse> Function(
    Uri uri,
    CatalogCancellationToken? cancellation,
  )
  handler;
  final requests = <Uri>[];

  @override
  Future<CatalogBytesResponse> getBytes(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    CatalogCancellationToken? cancellation,
  }) async {
    requests.add(uri);
    return handler(uri, cancellation);
  }
}

CatalogPointer _pointer(
  String revision, {
  String catalogId = 'yuxuanmian/venera-configs',
}) {
  final parts = catalogId.split('/');
  return CatalogPointer(
    catalogId: catalogId,
    revision: revision,
    indexUrl: Uri(
      scheme: 'https',
      host: 'raw.githubusercontent.com',
      pathSegments: [parts[0], parts[1], revision, 'index.json'],
    ).toString(),
  );
}

Uri _headUri(String branch) => Uri(
  scheme: 'https',
  host: 'api.github.com',
  pathSegments: [
    'repos',
    'yuxuanmian',
    'venera-configs',
    'git',
    'ref',
    'heads',
    ...branch.split('/'),
  ],
);

CatalogBytesResponse _json(Object? value, {int status = 200}) =>
    CatalogBytesResponse(status, utf8.encode(jsonEncode(value)));

CatalogBytesResponse _head(String branch, CatalogPointer pointer) => _json({
  'ref': 'refs/heads/$branch',
  'object': {'type': 'commit', 'sha': pointer.revision},
});

CatalogBytesResponse _index(List<String> keys) => _json([
  for (final key in keys)
    {'name': key, 'key': key, 'fileName': '$key.js', 'version': '1'},
]);

Future<void> _writeSnapshot(
  CatalogStore store,
  CatalogPointer pointer,
  String attemptId,
  Iterable<String> keys,
) async {
  final entries = [
    for (final key in keys)
      {'name': key, 'key': key, 'fileName': '$key.js', 'version': '1'},
  ];
  final index = CatalogIndex.fromJson(entries);
  final candidate = await store.createCandidate(
    pointer: pointer,
    indexBytes: utf8.encode(jsonEncode(entries)),
    index: index,
    attemptId: attemptId,
  );
  for (final entry in index.entries) {
    await store.writeCandidateSource(
      candidate,
      entry,
      utf8.encode('source ${entry.key}'),
    );
  }
  final completed = await store.finalizeCandidate(candidate);
  await store.promoteCandidate(completed);
}

CatalogRuntimeLoader _loader({
  Set<String> failKeys = const {},
  void Function()? onPrepare,
}) => CatalogRuntimeLoader(
  factory: (entry, source, context) {
    onPrepare?.call();
    if (failKeys.contains(entry.key)) {
      throw StateError('source preparation failed');
    }
    return Object();
  },
);

SourcePreferences _preferences(List<String>? initial) =>
    SourcePreferences(initial: initial);

void main() {
  test(
    'fresh startup auto-installs the default repository with empty selection',
    () async {
      final environment = await _Environment.create();
      final preferences = _preferences(null);
      addTearDown(() async {
        preferences.dispose();
        await environment.dispose();
      });
      environment.appdata.catalogRuntime = null;
      environment.appdata.settings['enabledSources'] = null;
      environment.appdata.settings['catalogRepositoryUrl'] = null;
      environment.appdata.settings['catalogRepositoryBranch'] = null;

      final pointer = _pointer('a' * 40);
      final transport = _Transport((uri, _) {
        if (uri == _headUri('yxm')) return _head('yxm', pointer);
        if (uri == Uri.parse(pointer.indexUrl)) {
          return _index(['first', 'second']);
        }
        if (uri.path.endsWith('/first.js')) {
          return CatalogBytesResponse(200, utf8.encode('first'));
        }
        if (uri.path.endsWith('/second.js')) {
          return CatalogBytesResponse(200, utf8.encode('second'));
        }
        throw StateError('unexpected request $uri');
      });
      final progress = <String>[];
      final controller = CatalogController(
        store: environment.store,
        httpClient: CatalogHttpClient(transport: transport),
        runtimeLoader: _loader(),
        preferences: preferences,
        appdata: environment.appdata,
        legacyRoot: Directory(p.join(environment.root.path, 'comic_source')),
        onProgress: (phase, completed, total) {
          progress.add('$phase:$completed/$total');
        },
      );
      addTearDown(controller.dispose);

      final result = await controller.boot();

      expect(result, isA<CatalogReady>());
      final ready = result as CatalogReady;
      expect(ready.needsSourceSelection, isTrue);
      expect(ready.repositorySource, CatalogRepositorySource.defaults);
      expect(ready.snapshot.manifest.pointer, pointer);
      expect(environment.appdata.settings['enabledSources'], isEmpty);
      expect(
        environment.appdata.settings['catalogRepositoryUrl'],
        CatalogRepositorySource.defaultRepositoryUrl,
      );
      expect(
        environment.appdata.settings['catalogRepositoryBranch'],
        CatalogRepositorySource.defaultBranch,
      );
      expect(environment.appdata.readCatalogState()!.lastAuthority, isNull);
      expect(progress, contains('下载漫画源文件:0/2'));
      expect(progress, contains('下载漫画源文件:2/2'));

      final requestCount = transport.requests.length;
      expect(await controller.boot(), same(ready));
      expect(transport.requests, hasLength(requestCount));
    },
  );

  test(
    'offline old snapshots reuse local Runtime without contacting old URLs',
    () async {
      final environment = await _Environment.create();
      final preferences = _preferences(['demo']);
      addTearDown(() async {
        preferences.dispose();
        await environment.dispose();
      });
      final pointer = _pointer('b' * 40);
      await _writeSnapshot(environment.store, pointer, 'offline-active', [
        'demo',
      ]);
      final oldAuthority = CatalogLastAuthority(
        catalog: pointer,
        serverUrl: 'https://old-server.example',
        checkedAt: DateTime.utc(2026, 1, 1),
      );
      environment.appdata.catalogRuntime = AppCatalogState(
        active: pointer,
        lastAuthority: oldAuthority,
      ).toJson();
      environment.appdata.settings['enabledSources'] = ['demo'];
      environment.appdata.settings['serverUrl'] = 'https://old-server.example';
      environment.appdata.settings['cloudTrackingServerUrl'] =
          'https://legacy-cloud.example';
      final transport = _Transport(
        (_, _) => throw const SocketException('offline'),
      );
      final controller = CatalogController(
        store: environment.store,
        httpClient: CatalogHttpClient(transport: transport),
        runtimeLoader: _loader(),
        preferences: preferences,
        appdata: environment.appdata,
        legacyRoot: Directory(p.join(environment.root.path, 'comic_source')),
      );
      addTearDown(controller.dispose);

      final result = await controller.boot();

      expect(result, isA<CatalogReady>());
      final ready = result as CatalogReady;
      expect(ready.usedLocalFallback, isTrue);
      expect(
        ready.localFallbackReason,
        CatalogLocalFallbackReason.repositoryCheckFailed,
      );
      expect(controller.sessionState?.active, pointer);
      expect(
        controller.sessionState?.lastAuthority?.catalog,
        oldAuthority.catalog,
      );
      expect(
        controller.sessionState?.lastAuthority?.serverUrl,
        oldAuthority.serverUrl,
      );
      expect(preferences.enabledSources, ['demo']);
      expect(
        transport.requests.every((uri) => uri.host == 'api.github.com'),
        isTrue,
      );
      expect(
        transport.requests.map((uri) => uri.host),
        isNot(contains('old-server.example')),
      );
    },
  );

  test(
    'invalid stored repository falls back to healthy local without rewriting',
    () async {
      final environment = await _Environment.create();
      final preferences = _preferences(['demo']);
      addTearDown(() async {
        preferences.dispose();
        await environment.dispose();
      });
      final pointer = _pointer('a' * 40);
      await _writeSnapshot(
        environment.store,
        pointer,
        'invalid-source-active',
        ['demo'],
      );
      environment.appdata.catalogRuntime = AppCatalogState(
        active: pointer,
      ).toJson();
      environment.appdata.settings['enabledSources'] = ['demo'];
      const invalidUrl = 'https://github.com:443/owner/repo';
      environment.appdata.settings['catalogRepositoryUrl'] = invalidUrl;
      environment.appdata.settings['catalogRepositoryBranch'] = 'yxm';
      final transport = _Transport(
        (_, _) => throw StateError('network must not be used'),
      );
      final controller = CatalogController(
        store: environment.store,
        httpClient: CatalogHttpClient(transport: transport),
        runtimeLoader: _loader(),
        preferences: preferences,
        appdata: environment.appdata,
        legacyRoot: Directory(p.join(environment.root.path, 'comic_source')),
      );
      addTearDown(controller.dispose);

      final result = await controller.boot();

      expect(result, isA<CatalogReady>());
      final ready = result as CatalogReady;
      expect(ready.usedLocalFallback, isTrue);
      expect(controller.sessionState?.active, pointer);
      expect(environment.appdata.settings['catalogRepositoryUrl'], invalidUrl);
      expect(environment.appdata.settings['catalogRepositoryBranch'], 'yxm');
      expect(
        controller.latestRepositoryCheck?.failure?.kind,
        CatalogSetupFailureKind.invalidRepositorySource,
      );
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'invalid repository without a runnable snapshot requires source repair',
    () async {
      final environment = await _Environment.create();
      final preferences = _preferences(null);
      addTearDown(() async {
        preferences.dispose();
        await environment.dispose();
      });
      environment.appdata.catalogRuntime = null;
      environment.appdata.settings['enabledSources'] = null;
      const invalidUrl = 'https://github.com/owner/a/../repo';
      environment.appdata.settings['catalogRepositoryUrl'] = invalidUrl;
      environment.appdata.settings['catalogRepositoryBranch'] = 'yxm';
      final transport = _Transport(
        (_, _) => throw StateError('network must not be used'),
      );
      final controller = CatalogController(
        store: environment.store,
        httpClient: CatalogHttpClient(transport: transport),
        runtimeLoader: _loader(),
        preferences: preferences,
        appdata: environment.appdata,
        legacyRoot: Directory(p.join(environment.root.path, 'comic_source')),
      );
      addTearDown(controller.dispose);

      final result = await controller.boot();

      expect(result, isA<CatalogNeedsInitialization>());
      expect(
        (result as CatalogNeedsInitialization).failure?.kind,
        CatalogSetupFailureKind.invalidRepositorySource,
      );
      expect(environment.appdata.settings['catalogRepositoryUrl'], invalidUrl);
      expect(environment.appdata.settings['catalogRepositoryBranch'], 'yxm');
      expect(environment.appdata.catalogRuntime, isNull);
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'healthy same-SHA snapshot is reused after store and Runtime checks',
    () async {
      final environment = await _Environment.create();
      final preferences = _preferences(['demo']);
      addTearDown(() async {
        preferences.dispose();
        await environment.dispose();
      });
      final pointer = _pointer('c' * 40);
      await _writeSnapshot(environment.store, pointer, 'same-sha', ['demo']);
      environment.appdata.catalogRuntime = AppCatalogState(
        active: pointer,
      ).toJson();
      environment.appdata.settings['enabledSources'] = ['demo'];
      var runtimePreparations = 0;
      final transport = _Transport((uri, _) {
        if (uri == _headUri('yxm')) return _head('yxm', pointer);
        throw StateError('unexpected request $uri');
      });
      final controller = CatalogController(
        store: environment.store,
        httpClient: CatalogHttpClient(transport: transport),
        runtimeLoader: _loader(onPrepare: () => runtimePreparations++),
        preferences: preferences,
        appdata: environment.appdata,
        legacyRoot: Directory(p.join(environment.root.path, 'comic_source')),
      );
      addTearDown(controller.dispose);

      final result = await controller.boot();

      expect(result, isA<CatalogReady>());
      expect((result as CatalogReady).usedLocalFallback, isFalse);
      expect(controller.sessionState?.active, pointer);
      expect(runtimePreparations, 1);
      expect(transport.requests, [_headUri('yxm')]);
    },
  );

  test('same-SHA storage corruption is rebuilt and revalidated', () async {
    final environment = await _Environment.create();
    final preferences = _preferences([]);
    addTearDown(() async {
      preferences.dispose();
      await environment.dispose();
    });
    final pointer = _pointer('d' * 40);
    final damaged = environment.store.snapshotDirectory(pointer);
    await damaged.create(recursive: true);
    await File(p.join(damaged.path, 'snapshot.json')).writeAsString('{broken');
    environment.appdata.catalogRuntime = AppCatalogState(
      active: pointer,
    ).toJson();
    environment.appdata.settings['enabledSources'] = <String>[];
    final transport = _Transport((uri, _) {
      if (uri == _headUri('yxm')) return _head('yxm', pointer);
      if (uri == Uri.parse(pointer.indexUrl)) return _index(['demo']);
      if (uri.path.endsWith('/demo.js')) {
        return CatalogBytesResponse(200, utf8.encode('demo'));
      }
      throw StateError('unexpected request $uri');
    });
    final controller = CatalogController(
      store: environment.store,
      httpClient: CatalogHttpClient(transport: transport),
      runtimeLoader: _loader(),
      preferences: preferences,
      appdata: environment.appdata,
      legacyRoot: Directory(p.join(environment.root.path, 'comic_source')),
    );
    addTearDown(controller.dispose);

    final result = await controller.boot();

    expect(result, isA<CatalogReady>());
    expect((await environment.store.readSnapshot(pointer))?.index.keys, {
      'demo',
    });
    expect(transport.requests, contains(Uri.parse(pointer.indexUrl)));
  });

  test(
    'a disabled source failure rejects the full update and keeps active',
    () async {
      final environment = await _Environment.create();
      final preferences = _preferences(['active_source']);
      addTearDown(() async {
        preferences.dispose();
        await environment.dispose();
      });
      final active = _pointer('e' * 40);
      final candidatePointer = _pointer('f' * 40);
      await _writeSnapshot(
        environment.store,
        active,
        'disabled-update-active',
        ['active_source'],
      );
      environment.appdata.catalogRuntime = AppCatalogState(
        active: active,
      ).toJson();
      environment.appdata.settings['enabledSources'] = ['active_source'];
      final transport = _Transport((uri, _) {
        if (uri == _headUri('yxm')) {
          return _head('yxm', candidatePointer);
        }
        if (uri == Uri.parse(candidatePointer.indexUrl)) {
          return _index(['enabled_source', 'disabled_source']);
        }
        if (uri.path.endsWith('.js')) {
          return CatalogBytesResponse(200, utf8.encode('source'));
        }
        throw StateError('unexpected request $uri');
      });
      final controller = CatalogController(
        store: environment.store,
        httpClient: CatalogHttpClient(transport: transport),
        runtimeLoader: _loader(failKeys: {'disabled_source'}),
        preferences: preferences,
        appdata: environment.appdata,
        legacyRoot: Directory(p.join(environment.root.path, 'comic_source')),
      );
      addTearDown(controller.dispose);

      final result = await controller.boot();

      expect(result, isA<CatalogReady>());
      expect((result as CatalogReady).usedLocalFallback, isTrue);
      expect(controller.sessionState?.active, active);
      expect(environment.appdata.readCatalogState()!.active, active);
      expect(preferences.enabledSources, ['active_source']);
      expect(
        transport.requests.any(
          (uri) => uri.path.endsWith('/disabled_source.js'),
        ),
        isTrue,
      );
      expect(await environment.store.readSnapshot(candidatePointer), isNull);
    },
  );

  test(
    'failed new HEAD falls back from missing active to healthy LKG',
    () async {
      final environment = await _Environment.create();
      final preferences = _preferences(['demo']);
      addTearDown(() async {
        preferences.dispose();
        await environment.dispose();
      });
      final active = _pointer('1' * 40);
      final lkg = _pointer('2' * 40);
      final latest = _pointer('3' * 40);
      await _writeSnapshot(environment.store, lkg, 'healthy-lkg', ['demo']);
      environment.appdata.catalogRuntime = AppCatalogState(
        active: active,
        lkg: lkg,
      ).toJson();
      environment.appdata.settings['enabledSources'] = ['demo'];
      final transport = _Transport((uri, _) {
        if (uri == _headUri('yxm')) return _head('yxm', latest);
        if (uri == Uri.parse(latest.indexUrl)) {
          return CatalogBytesResponse(500, utf8.encode('private body'));
        }
        throw StateError('unexpected request $uri');
      });
      final controller = CatalogController(
        store: environment.store,
        httpClient: CatalogHttpClient(transport: transport),
        runtimeLoader: _loader(),
        preferences: preferences,
        appdata: environment.appdata,
        legacyRoot: Directory(p.join(environment.root.path, 'comic_source')),
      );
      addTearDown(controller.dispose);

      final result = await controller.boot();

      expect(result, isA<CatalogReady>());
      final ready = result as CatalogReady;
      expect(ready.usedLocalFallback, isTrue);
      expect(
        ready.localFallbackReason,
        CatalogLocalFallbackReason.updatePreparationFailed,
      );
      expect(controller.sessionState?.active, lkg);
    },
  );

  test('failed HEAD equal to LKG tries healthy active before LKG', () async {
    final environment = await _Environment.create();
    final preferences = _preferences(['demo']);
    addTearDown(() async {
      preferences.dispose();
      await environment.dispose();
    });
    final active = _pointer('8' * 40);
    final lkg = _pointer('9' * 40);
    await _writeSnapshot(environment.store, active, 'active-before-lkg', [
      'demo',
    ]);
    await _writeSnapshot(environment.store, lkg, 'head-is-lkg', ['demo']);
    environment.appdata.catalogRuntime = AppCatalogState(
      active: active,
      lkg: lkg,
    ).toJson();
    environment.appdata.settings['enabledSources'] = ['demo'];
    environment.appdata.atomicReplace = (_, _) async {
      throw const FileSystemException('injected replace failure');
    };
    final transport = _Transport((uri, _) {
      if (uri == _headUri('yxm')) return _head('yxm', lkg);
      throw StateError('unexpected request $uri');
    });
    final controller = CatalogController(
      store: environment.store,
      httpClient: CatalogHttpClient(transport: transport),
      runtimeLoader: _loader(),
      preferences: preferences,
      appdata: environment.appdata,
      legacyRoot: Directory(p.join(environment.root.path, 'comic_source')),
    );
    addTearDown(controller.dispose);

    final result = await controller.boot();

    expect(result, isA<CatalogReady>());
    expect((result as CatalogReady).usedLocalFallback, isTrue);
    expect(controller.sessionState?.active, active);
    expect(transport.requests, [_headUri('yxm')]);
  });

  test(
    'cold-start cancellation rejects a late successful HEAD response',
    () async {
      final environment = await _Environment.create();
      final preferences = _preferences(null);
      addTearDown(() async {
        preferences.dispose();
        await environment.dispose();
      });
      environment.appdata.catalogRuntime = null;
      environment.appdata.settings['enabledSources'] = null;
      final started = Completer<void>();
      final pending = Completer<CatalogBytesResponse>();
      final pointer = _pointer('4' * 40);
      final transport = _Transport((uri, _) {
        if (!started.isCompleted) started.complete();
        return pending.future;
      });
      final controller = CatalogController(
        store: environment.store,
        httpClient: CatalogHttpClient(transport: transport),
        runtimeLoader: _loader(),
        preferences: preferences,
        appdata: environment.appdata,
        legacyRoot: Directory(p.join(environment.root.path, 'comic_source')),
      );
      addTearDown(controller.dispose);

      final boot = controller.boot();
      await started.future.timeout(const Duration(seconds: 3));
      controller.cancelCurrentAttempt();
      pending.complete(_head('yxm', pointer));
      final result = await boot.timeout(const Duration(seconds: 3));

      expect(result, isA<CatalogNeedsInitialization>());
      expect((result as CatalogNeedsInitialization).failure, isNull);
      expect(environment.appdata.catalogRuntime, isNull);
      expect(environment.appdata.settings['enabledSources'], isNull);
      expect(transport.requests, hasLength(1));
    },
  );

  test(
    'cancellation before same-SHA publication leaves no Runtime published',
    () async {
      final environment = await _Environment.create();
      final preferences = _preferences(['demo']);
      addTearDown(() async {
        preferences.dispose();
        await environment.dispose();
      });
      final pointer = _pointer('0' * 40);
      await _writeSnapshot(environment.store, pointer, 'cancel-same-sha', [
        'demo',
      ]);
      environment.appdata.catalogRuntime = AppCatalogState(
        active: pointer,
      ).toJson();
      environment.appdata.settings['enabledSources'] = ['demo'];
      final transport = _Transport((uri, _) {
        if (uri == _headUri('yxm')) return _head('yxm', pointer);
        throw StateError('unexpected request $uri');
      });
      late final CatalogController controller;
      controller = CatalogController(
        store: environment.store,
        httpClient: CatalogHttpClient(transport: transport),
        runtimeLoader: CatalogRuntimeLoader(
          factory: (_, _, _) {
            controller.cancelCurrentAttempt();
            return Object();
          },
        ),
        preferences: preferences,
        appdata: environment.appdata,
        legacyRoot: Directory(p.join(environment.root.path, 'comic_source')),
      );
      addTearDown(controller.dispose);

      final result = await controller.boot();

      expect(result, isA<CatalogNeedsRecovery>());
      expect(controller.sessionState, isNull);
      expect(environment.appdata.readCatalogState()!.active, pointer);
    },
  );

  test(
    'successful switch prunes only removed keys from latest preferences',
    () async {
      final environment = await _Environment.create();
      final active = _pointer('5' * 40);
      final latest = _pointer('6' * 40);
      await _writeSnapshot(environment.store, active, 'prune-active', [
        'demo',
        'removed',
      ]);
      environment.appdata.catalogRuntime = AppCatalogState(
        active: active,
      ).toJson();
      environment.appdata.settings['enabledSources'] = [
        'demo',
        'removed',
        'unknown',
      ];
      await File(
        p.join(environment.root.path, 'appdata.json'),
      ).writeAsString(jsonEncode(environment.appdata.toJson()), flush: true);
      final preferences = _preferences(['demo', 'removed']);
      addTearDown(() async {
        preferences.dispose();
        await environment.dispose();
      });
      final transport = _Transport((uri, _) {
        if (uri == _headUri('yxm')) return _head('yxm', latest);
        if (uri == Uri.parse(latest.indexUrl)) {
          return _index(['demo', 'new_source']);
        }
        if (uri.path.endsWith('.js')) {
          return CatalogBytesResponse(200, utf8.encode('source'));
        }
        throw StateError('unexpected request $uri');
      });
      final controller = CatalogController(
        store: environment.store,
        httpClient: CatalogHttpClient(transport: transport),
        runtimeLoader: _loader(),
        preferences: preferences,
        appdata: environment.appdata,
        legacyRoot: Directory(p.join(environment.root.path, 'comic_source')),
      );
      addTearDown(controller.dispose);

      final result = await controller.boot();

      expect(result, isA<CatalogReady>());
      expect(environment.appdata.settings['enabledSources'], [
        'demo',
        'unknown',
      ]);
      expect(preferences.enabledSources, ['demo', 'unknown']);
      expect(environment.appdata.readCatalogState()!.active, latest);
      expect(environment.appdata.readCatalogState()!.lkg, active);
      final persisted =
          jsonDecode(
                await File(
                  p.join(environment.root.path, 'appdata.json'),
                ).readAsString(),
              )
              as Map;
      expect(persisted['settings']['enabledSources'], ['demo', 'unknown']);
    },
  );

  test(
    'HEAD check and source verification never replace the active Runtime',
    () async {
      final environment = await _Environment.create();
      final preferences = _preferences(['demo']);
      addTearDown(() async {
        preferences.dispose();
        await environment.dispose();
      });
      final active = _pointer('7' * 40);
      await _writeSnapshot(environment.store, active, 'verify-active', [
        'demo',
      ]);
      environment.appdata.catalogRuntime = AppCatalogState(
        active: active,
      ).toJson();
      environment.appdata.settings['enabledSources'] = ['demo'];
      final nextSource = CatalogRepositorySource(
        repositoryUrl: CatalogRepositorySource.defaultRepositoryUrl,
        branch: 'next',
      );
      final transport = _Transport((uri, _) {
        if (uri == _headUri('yxm') || uri == _headUri('next')) {
          return _head(uri == _headUri('next') ? 'next' : 'yxm', active);
        }
        if (uri == Uri.parse(active.indexUrl)) return _index(['demo']);
        throw StateError('unexpected request $uri');
      });
      final controller = CatalogController(
        store: environment.store,
        httpClient: CatalogHttpClient(transport: transport),
        runtimeLoader: _loader(),
        preferences: preferences,
        appdata: environment.appdata,
        legacyRoot: Directory(p.join(environment.root.path, 'comic_source')),
      );
      addTearDown(controller.dispose);
      await controller.boot();
      final runtimeBefore = controller.sessionState?.active;
      final requestsBefore = transport.requests.length;

      final check = await controller.checkRepositoryUpdate();
      expect(check.succeeded, isTrue);
      expect(controller.sessionState?.active, runtimeBefore);
      expect(transport.requests, hasLength(requestsBefore + 1));

      final verification = await controller.verifyAndSaveRepositorySource(
        nextSource,
      );
      expect(verification.succeeded, isTrue);
      expect(verification.check.latest, active);
      expect(controller.sessionState?.active, runtimeBefore);
      expect(environment.appdata.readCatalogState()!.active, active);
      expect(environment.appdata.settings['catalogRepositoryBranch'], 'next');
      expect(
        transport.requests.skip(requestsBefore + 1).map((uri) => uri.path),
        contains('/repos/yuxuanmian/venera-configs/git/ref/heads/next'),
      );
      expect(
        transport.requests
            .skip(requestsBefore + 1)
            .every((uri) => !uri.path.endsWith('.js')),
        isTrue,
      );
    },
  );

  test(
    'source verification failure preserves saved source and active Runtime',
    () async {
      final environment = await _Environment.create();
      final preferences = _preferences(['demo']);
      addTearDown(() async {
        preferences.dispose();
        await environment.dispose();
      });
      final active = _pointer('b' * 40);
      await _writeSnapshot(environment.store, active, 'verify-failure-active', [
        'demo',
      ]);
      environment.appdata.catalogRuntime = AppCatalogState(
        active: active,
      ).toJson();
      environment.appdata.settings['enabledSources'] = ['demo'];
      final nextSource = CatalogRepositorySource(branch: 'next');
      final transport = _Transport((uri, _) {
        if (uri == _headUri('yxm')) return _head('yxm', active);
        if (uri == _headUri('next')) return _head('next', active);
        if (uri == Uri.parse(active.indexUrl)) {
          return CatalogBytesResponse(500, utf8.encode('private response'));
        }
        throw StateError('unexpected request $uri');
      });
      final controller = CatalogController(
        store: environment.store,
        httpClient: CatalogHttpClient(transport: transport),
        runtimeLoader: _loader(),
        preferences: preferences,
        appdata: environment.appdata,
        legacyRoot: Directory(p.join(environment.root.path, 'comic_source')),
      );
      addTearDown(controller.dispose);
      await controller.boot();
      final runtimeBefore = controller.sessionState?.active;

      final verification = await controller.verifyAndSaveRepositorySource(
        nextSource,
      );

      expect(verification.succeeded, isFalse);
      expect(
        verification.failure?.kind,
        CatalogSetupFailureKind.contentPreparationFailed,
      );
      expect(controller.sessionState?.active, runtimeBefore);
      expect(environment.appdata.settings['catalogRepositoryBranch'], 'yxm');
      expect(
        verification.failure?.diagnostic,
        isNot(contains('private response')),
      );
      expect(
        transport.requests.any((uri) => uri.path.endsWith('.js')),
        isFalse,
      );
    },
  );
}
