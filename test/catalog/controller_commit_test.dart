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
import 'package:venera/foundation/catalog/runtime_context.dart';
import 'package:venera/foundation/catalog/runtime_loader.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';
import 'package:venera/foundation/catalog/store.dart';

class _Transport implements CatalogTransport {
  _Transport(this.pointer);

  final CatalogPointer pointer;

  @override
  Future<CatalogBytesResponse> getBytes(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    CatalogCancellationToken? cancellation,
  }) async {
    if (uri.toString() == 'https://server.example/api/catalog/authority') {
      return CatalogBytesResponse(
        200,
        utf8.encode(
          jsonEncode({
            'catalogId': pointer.catalogId,
            'activeRevision': pointer.revision,
            'indexUrl': pointer.indexUrl,
          }),
        ),
      );
    }
    throw StateError('unexpected request $uri');
  }
}

class _ThrowingAppdata extends Appdata {
  _ThrowingAppdata(this.failure)
    : super.createForTesting(() async => Directory.systemTemp);

  final Object failure;

  @override
  Future<PreparedAppDataCommit> prepareCatalogCommit({
    required AppCatalogState nextState,
    required List<String>? nextEnabled,
    String? nextServerUrl,
    CatalogAttempt? attempt,
    void Function(Map<String, dynamic> settings)? migrateSourcePages,
  }) async {
    throw failure;
  }
}

class _ObservingAppdata extends Appdata {
  _ObservingAppdata()
    : super.createForTesting(() async => Directory.systemTemp);

  final commitEntered = Completer<void>();

  @override
  Future<PreparedAppDataCommit> prepareCatalogCommit({
    required AppCatalogState nextState,
    required List<String>? nextEnabled,
    String? nextServerUrl,
    CatalogAttempt? attempt,
    void Function(Map<String, dynamic> settings)? migrateSourcePages,
  }) {
    if (!commitEntered.isCompleted) commitEntered.complete();
    return super.prepareCatalogCommit(
      nextState: nextState,
      nextEnabled: nextEnabled,
      nextServerUrl: nextServerUrl,
      attempt: attempt,
      migrateSourcePages: migrateSourcePages,
    );
  }
}

CatalogPointer _pointer(String revision) => CatalogPointer(
  catalogId: 'owner/repo',
  revision: revision,
  indexUrl: 'https://raw.githubusercontent.com/owner/repo/$revision/index.json',
);

Future<void> _writeSnapshot(
  CatalogStore store,
  CatalogPointer pointer,
  String attemptId, {
  List<String> keys = const ['demo'],
}) async {
  final index = [
    for (final key in keys)
      {'name': key, 'key': key, 'fileName': '$key.js', 'version': '1'},
  ];
  final indexBytes = utf8.encode(jsonEncode(index));
  final candidate = await store.createCandidate(
    pointer: pointer,
    indexBytes: indexBytes,
    index: CatalogIndex.fromJson(index),
    attemptId: attemptId,
  );
  for (final item in index) {
    await store.writeCandidateSource(
      candidate,
      CatalogSourceEntry.fromJson(item),
      utf8.encode('source'),
    );
  }
  final complete = await store.finalizeCandidate(candidate);
  await store.promoteCandidate(complete);
}

Future<({Directory root, CatalogPointer active, CatalogPointer lkg})>
_prepareFixture(
  Appdata target, {
  List<String> activeKeys = const ['demo'],
}) async {
  final root = await Directory.systemTemp.createTemp('catalog-lkg-commit-');
  App.dataPath = root.path;
  final active = _pointer('a' * 40);
  final lkg = _pointer('b' * 40);
  final store = CatalogStore(Directory(p.join(root.path, 'catalog')));
  await _writeSnapshot(store, active, 'active', keys: activeKeys);
  await _writeSnapshot(store, lkg, 'lkg');
  target.catalogRuntime = AppCatalogState(active: active, lkg: lkg).toJson();
  target.settings['serverUrl'] = 'https://server.example';
  target.settings['enabledSources'] = <String>['demo'];
  await File(
    p.join(root.path, 'appdata.json'),
  ).writeAsString(jsonEncode(target.toJson()), flush: true);
  return (root: root, active: active, lkg: lkg);
}

Future<void> _removeEventually(Directory root) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    if (!await root.exists()) return;
    try {
      await root.delete(recursive: true);
      return;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

void main() {
  for (final selection in <List<String>?>[
    [],
    ['demo', 'new_source'],
    ['demo', 'remote_only'],
    null,
  ]) {
    test('pointer repair preserves concurrent selection $selection', () async {
      final oldPath = App.isInitialized ? App.dataPath : null;
      final target = _ObservingAppdata();
      final fixture = await _prepareFixture(target);
      final releaseSave = Completer<void>();
      final saveEntered = Completer<void>();
      final repairReplaced = Completer<void>();
      final contexts = <ManagedSourceContext>[];
      Map<String, dynamic>? savedUserDocument;
      var writes = 0;
      target.atomicReplace = (source, destination) async {
        final write = ++writes;
        if (write == 1) {
          saveEntered.complete();
          await releaseSave.future;
        }
        final hook = target.atomicReplace;
        target.atomicReplace = null;
        try {
          await target.replaceFileAtomically(source, destination);
        } finally {
          target.atomicReplace = hook;
        }
        if (write == 1) {
          savedUserDocument = Map<String, dynamic>.from(
            jsonDecode(await destination.readAsString()) as Map,
          )..remove('catalogRuntime');
        }
        if (write == 2) repairReplaced.complete();
      };
      final preferences = SourcePreferences(initial: ['demo']);
      final controller = CatalogController(
        store: CatalogStore(Directory(p.join(fixture.root.path, 'catalog'))),
        httpClient: CatalogHttpClient(transport: _Transport(fixture.lkg)),
        runtimeLoader: CatalogRuntimeLoader(
          factory: (entry, source, context) {
            contexts.add(context);
            return Object();
          },
        ),
        preferences: preferences,
        appdata: target,
        legacyRoot: Directory(p.join(fixture.root.path, 'comic_source')),
      );
      final save = target.persistEnabledSources(selection);
      try {
        await saveEntered.future.timeout(const Duration(seconds: 3));
        final boot = controller.boot();
        await target.commitEntered.future.timeout(const Duration(seconds: 3));
        controller.useLocalVersion();
        final result = await boot.timeout(const Duration(seconds: 3));
        expect(result, isA<CatalogReady>());
        expect(releaseSave.isCompleted, isFalse);
        releaseSave.complete();
        await save;
        await repairReplaced.future.timeout(const Duration(seconds: 3));
        // Acquiring the shared lock proves repair installed memory and released.
        final barrier = await target.prepareUserDataCommit({});
        await barrier.discard();
        expect(target.settings['enabledSources'], selection);
        final repairedUserDocument = Map<String, dynamic>.from(
          jsonDecode(
                await File(
                  p.join(fixture.root.path, 'appdata.json'),
                ).readAsString(),
              )
              as Map,
        )..remove('catalogRuntime');
        expect(repairedUserDocument, savedUserDocument);
        expect(
          target.readCatalogState()!.active!.identity,
          fixture.lkg.identity,
        );
        expect(target.readCatalogState()!.lkg, isNull);
        expect(contexts, hasLength(1));
        expect(contexts.single.phase, ManagedSourcePhase.published);
        await target.saveData(false);
        final document = jsonDecode(
          await File(p.join(fixture.root.path, 'appdata.json')).readAsString(),
        );
        expect(document['settings']['enabledSources'], selection);
      } finally {
        if (!releaseSave.isCompleted) releaseSave.complete();
        await save;
        target.atomicReplace = null;
        preferences.dispose();
        await _removeEventually(fixture.root);
        if (oldPath != null) App.dataPath = oldPath;
      }
    });
  }

  test('authority commit still prunes only observed removed keys', () async {
    final target = Appdata.createForTesting(() async => Directory.systemTemp);
    final fixture = await _prepareFixture(
      target,
      activeKeys: ['demo', 'removed'],
    );
    addTearDown(() => _removeEventually(fixture.root));
    target.settings['enabledSources'] = ['demo', 'removed', 'remote_only'];
    final preferences = SourcePreferences(
      initial: ['demo', 'removed', 'remote_only'],
    );
    addTearDown(preferences.dispose);
    final controller = CatalogController(
      store: CatalogStore(Directory(p.join(fixture.root.path, 'catalog'))),
      httpClient: CatalogHttpClient(transport: _Transport(fixture.lkg)),
      runtimeLoader: CatalogRuntimeLoader(factory: (_, _, _) => Object()),
      preferences: preferences,
      appdata: target,
      legacyRoot: Directory(p.join(fixture.root.path, 'comic_source')),
    );
    final result = await controller.boot();
    expect(result, isA<CatalogReady>());
    expect((result as CatalogReady).usedLocalFallback, isFalse);
    expect(target.settings['enabledSources'], ['demo', 'remote_only']);
    expect(preferences.enabledSources, ['demo', 'remote_only']);
    expect(target.readCatalogState()!.lkg!.identity, fixture.active.identity);
  });

  test('commit cancellation wins before the committing phase', () {
    final attempt = CatalogAttempt(
      id: 'commit',
      deadline: DateTime.now().add(const Duration(minutes: 1)),
    );
    attempt.close();
    expect(attempt.beginCommit(), isFalse);
    expect(attempt.phase, CatalogAttemptPhase.closed);
  });

  test(
    'prepared LKG survives an appdata replace failure without reparsing',
    () async {
      final target = Appdata.createForTesting(() async => Directory.systemTemp);
      final fixture = await _prepareFixture(target);
      addTearDown(() => _removeEventually(fixture.root));
      var factoryCalls = 0;
      final loader = CatalogRuntimeLoader(
        factory: (entry, source, context) {
          factoryCalls++;
          return source;
        },
      );
      target.atomicReplace = (source, destination) async {
        if (p.basename(destination.path) == 'appdata.json') {
          throw const FileSystemException('injected replace failure');
        }
        await source.rename(destination.path);
      };
      addTearDown(() => target.atomicReplace = null);

      final controller = CatalogController(
        store: CatalogStore(Directory(p.join(fixture.root.path, 'catalog'))),
        httpClient: CatalogHttpClient(transport: _Transport(fixture.lkg)),
        runtimeLoader: loader,
        preferences: SourcePreferences(initial: ['demo']),
        appdata: target,
        legacyRoot: Directory(p.join(fixture.root.path, 'comic_source')),
      );
      addTearDown(controller.preferences.dispose);
      final appdataBytes = await File(
        p.join(fixture.root.path, 'appdata.json'),
      ).readAsBytes();
      final result = await controller.boot();

      expect(result, isA<CatalogReady>());
      expect((result as CatalogReady).usedLocalFallback, isTrue);
      expect(controller.sessionState?.active?.identity, fixture.lkg.identity);
      expect(controller.sessionState?.lkg, isNull);
      expect(factoryCalls, 1);
      expect(
        await File(p.join(fixture.root.path, 'appdata.json')).readAsBytes(),
        appdataBytes,
      );
      expect(target.settings['enabledSources'], ['demo']);
    },
  );

  test('prepared LKG survives prepareCatalogCommit failure', () async {
    final target = _ThrowingAppdata(
      const FileSystemException('prepare failed'),
    );
    final fixture = await _prepareFixture(target);
    addTearDown(() => _removeEventually(fixture.root));
    var factoryCalls = 0;
    final loader = CatalogRuntimeLoader(
      factory: (entry, source, context) {
        factoryCalls++;
        return source;
      },
    );
    final controller = CatalogController(
      store: CatalogStore(Directory(p.join(fixture.root.path, 'catalog'))),
      httpClient: CatalogHttpClient(transport: _Transport(fixture.lkg)),
      runtimeLoader: loader,
      preferences: SourcePreferences(initial: ['demo']),
      appdata: target,
      legacyRoot: Directory(p.join(fixture.root.path, 'comic_source')),
    );
    addTearDown(controller.preferences.dispose);

    final result = await controller.boot();
    expect(result, isA<CatalogReady>());
    expect((result as CatalogReady).usedLocalFallback, isTrue);
    expect(controller.sessionState?.active?.identity, fixture.lkg.identity);
    expect(factoryCalls, 1);
  });

  test(
    'cancelling while commit preparation waits publishes the same LKG and discards late handle',
    () async {
      final target = _ObservingAppdata();
      final fixture = await _prepareFixture(target);
      addTearDown(() => _removeEventually(fixture.root));
      final blocker = await target.prepareUserDataCommit({});
      final loader = CatalogRuntimeLoader(
        factory: (entry, source, context) {
          return source;
        },
      );
      final controller = CatalogController(
        store: CatalogStore(Directory(p.join(fixture.root.path, 'catalog'))),
        httpClient: CatalogHttpClient(transport: _Transport(fixture.lkg)),
        runtimeLoader: loader,
        preferences: SourcePreferences(initial: ['demo']),
        appdata: target,
        legacyRoot: Directory(p.join(fixture.root.path, 'comic_source')),
      );
      addTearDown(controller.preferences.dispose);

      final boot = controller.boot();
      await target.commitEntered.future;
      expect(controller.canUseLocalVersion, isTrue);
      controller.useLocalVersion();
      final result = await boot;
      expect(result, isA<CatalogReady>());
      expect((result as CatalogReady).usedLocalFallback, isTrue);
      expect(controller.sessionState?.active?.identity, fixture.lkg.identity);
      await blocker.discard();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        (await Directory(fixture.root.path).list().toList())
            .whereType<File>()
            .where((file) => file.path.contains('.tmp')),
        isEmpty,
      );
    },
  );

  test('commit preparation timeout reuses the already prepared LKG', () async {
    final target = _ObservingAppdata();
    final fixture = await _prepareFixture(target);
    addTearDown(() => _removeEventually(fixture.root));
    final blocker = await target.prepareUserDataCommit({});
    final controller = CatalogController(
      store: CatalogStore(Directory(p.join(fixture.root.path, 'catalog'))),
      httpClient: CatalogHttpClient(transport: _Transport(fixture.lkg)),
      runtimeLoader: CatalogRuntimeLoader(
        factory: (entry, source, context) => source,
      ),
      preferences: SourcePreferences(initial: ['demo']),
      appdata: target,
      legacyRoot: Directory(p.join(fixture.root.path, 'comic_source')),
      normalPrepareBudget: const Duration(milliseconds: 100),
    );
    addTearDown(controller.preferences.dispose);

    final boot = controller.boot();
    await target.commitEntered.future;
    final result = await boot;
    expect(result, isA<CatalogReady>());
    expect((result as CatalogReady).usedLocalFallback, isTrue);
    expect(controller.sessionState?.active?.identity, fixture.lkg.identity);
    await blocker.discard();
  });
}
