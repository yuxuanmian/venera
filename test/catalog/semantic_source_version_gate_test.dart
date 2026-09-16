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
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/utils/translations.dart';

/// The release gate for feature 008, in its two halves.
///
/// 1. **App-side parser gate** (the first four tests) — the Host must reject a
///    candidate whose `minAppVersion` is newer than the running App, and must
///    keep the previously installed source usable. This is what lets an older
///    App stay on Pica `1.0.8` instead of receiving a config that requires the
///    new `tagSearch` action.
/// 2. **Catalog publish / last-known-good gate** (the last four tests) — the
///    same rejection must hold on the real `CatalogController`
///    attempt/publish/last-known-good path: an older Host that already has
///    `1.0.8` installed (as `active`, or as the only healthy `lkg`) keeps
///    publishing `1.0.8` and never receives the incompatible `1.0.9`
///    assembly, and an older Host with no local assembly at all fails a new
///    install safely without erasing other installed sources.
///
/// The publish half prepares fake artifacts and drives the real production
/// objects: a real [CatalogStore] on a temp directory, the real
/// [CatalogRuntimeLoader.forComicSources] factory (so the `minAppVersion` gate
/// is the one [ComicSourceParser] enforces), and the real
/// `CatalogController` flow. Only the network transport and the prepared
/// snapshots are fake.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dataDirectory;

  setUpAll(() async {
    await AppTranslation.init();
    dataDirectory = await Directory.systemTemp.createTemp(
      'venera-semantic-version-gate-',
    );
    App.dataPath = dataDirectory.path;
    await JsEngine().init();
  });

  tearDownAll(() async {
    if (await dataDirectory.exists()) {
      await dataDirectory.delete(recursive: true);
    }
  });

  String sourceScript({
    required String key,
    required String version,
    required String minAppVersion,
  }) =>
      '''
class SemanticGateSource extends ComicSource {
  name = "Semantic gate";
  key = "$key";
  version = "$version";
  minAppVersion = "$minAppVersion";
  search = {
    load: async (keyword, options, page) => ({comics: [], maxPage: 1}),
  };
  comic = {
    loadInfo: async (id) => ({}),
    loadEp: async (comicId, epId) => ({images: []}),
  };
}
''';

  test('the installed 1.0.8 source stays usable', () async {
    const key = 'semantic_gate_installed';
    final source = await ComicSourceParser().parse(
      sourceScript(key: key, version: '1.0.8', minAppVersion: '1.0.0'),
      '$key.js',
    );
    expect(source.version, '1.0.8');
    expect(source.searchPageData, isNotNull);
    final page = await source.searchPageData!.loadPage!(
      'anything',
      1,
      const [],
    );
    expect(page.error, isFalse);
  });

  test('an incompatible 1.0.9 candidate is rejected', () async {
    const key = 'semantic_gate_candidate';
    await expectLater(
      ComicSourceParser().parse(
        sourceScript(key: key, version: '1.0.9', minAppVersion: '99.0.0'),
        '$key.js',
      ),
      throwsA(isA<ComicSourceParseException>()),
    );
  });

  test('the current development App satisfies the intended 2.0.0 gate', () {
    // `compareSemVer(required, running)` is true when the source requires a
    // newer App; the parser lower-cases the App version by stripping the
    // prerelease suffix, so `2.0.0-beta.3` satisfies a `2.0.0` gate.
    final running = App.version.split('-').first;
    expect(compareSemVer('99.0.0', running), isTrue);
    expect(compareSemVer('2.0.0', running), isFalse);
    expect(compareSemVer('1.0.0', running), isFalse);
  });

  test('a rejected candidate does not replace the installed source', () async {
    const key = 'semantic_gate_keeps_installed';
    final installed = await ComicSourceParser().parse(
      sourceScript(key: key, version: '1.0.8', minAppVersion: '1.0.0'),
      '$key.js',
    );
    ComicSourceManager().add(installed);
    addTearDown(() => ComicSourceManager().remove(key));

    await expectLater(
      ComicSourceParser().parse(
        sourceScript(key: key, version: '1.0.9', minAppVersion: '99.0.0'),
        '$key.js',
      ),
      throwsA(isA<ComicSourceParseException>()),
    );

    expect(ComicSource.find(key), isNotNull);
    expect(ComicSource.find(key)!.version, '1.0.8');
    final page = await ComicSource.find(key)!.searchPageData!.loadPage!(
      'anything',
      1,
      const [],
    );
    expect(page.error, isFalse);
  });

  // ---------------------------------------------------------------------
  // Catalog publish / last-known-good half (T058 proof, driven by T072)
  // ---------------------------------------------------------------------

  test(
    'publishing keeps the installed 1.0.8 assembly when the candidate is incompatible',
    () async {
      final fixture = await _createPublishFixture(enabled: const [_picacgKey]);
      final installed = _pointer('a' * 40);
      final fallback = _pointer('b' * 40);
      final candidate = _pointer('c' * 40);
      final installedScript = _sourceScript(
        key: _picacgKey,
        version: _installedVersion,
        minAppVersion: '1.0.0',
      );
      final fallbackScript = _sourceScript(
        key: _picacgKey,
        version: '1.0.7',
        minAppVersion: '1.0.0',
      );
      final candidateScript = _sourceScript(
        key: _picacgKey,
        version: _candidateVersion,
        minAppVersion: _incompatibleGate,
        tagSearch: true,
      );

      await _writeLocalSnapshot(
        fixture.store,
        installed,
        'installed',
        key: _picacgKey,
        version: _installedVersion,
        source: installedScript,
      );
      await _writeLocalSnapshot(
        fixture.store,
        fallback,
        'fallback',
        key: _picacgKey,
        version: '1.0.7',
        source: fallbackScript,
      );
      fixture.appdata.catalogRuntime = AppCatalogState(
        active: installed,
        lkg: fallback,
      ).toJson();
      fixture.appdata.settings['serverUrl'] = _hostServerUrl;
      fixture.appdata.settings['enabledSources'] = <String>[_picacgKey];
      final appdataFile = File(p.join(fixture.root.path, 'appdata.json'));
      await appdataFile.writeAsString(
        jsonEncode(fixture.appdata.toJson()),
        flush: true,
      );
      final appdataBytesBefore = await appdataFile.readAsBytes();

      _authority(fixture.responses, candidate);
      _availableRevision(
        fixture.responses,
        candidate,
        candidateScript,
        key: _picacgKey,
        version: _candidateVersion,
      );

      final controller = fixture.controller();
      final result = await controller.boot();

      expect(result, isA<CatalogReady>());
      final ready = result as CatalogReady;
      expect(ready.usedLocalFallback, isTrue);
      expect(ready.snapshot.manifest.pointer.identity, installed.identity);
      expect(controller.sessionState?.active?.identity, installed.identity);
      // The older local assembly stays the backup; only the active pointer was
      // re-published from disk.
      expect(controller.sessionState?.lkg?.identity, fallback.identity);

      // The incompatible candidate never became a local snapshot and was never
      // handed to the App.
      expect(await fixture.store.readSnapshot(candidate), isNull);
      final published = ComicSource.find(_picacgKey);
      expect(published, isNotNull);
      expect(published!.version, _installedVersion);
      expect(
        published.semanticSearchData,
        isNull,
        reason: 'the 1.0.9 tagSearch action must not reach the App',
      );
      final page = await published.searchPageData!.loadPage!(
        'anything',
        1,
        const [],
      );
      expect(page.error, isFalse);

      // A rejected candidate performs no Catalog commit at all.
      expect(
        fixture.appdata.readCatalogState()!.active!.identity,
        installed.identity,
      );
      expect(
        fixture.appdata.readCatalogState()!.lkg!.identity,
        fallback.identity,
      );
      expect(fixture.appdata.settings['enabledSources'], <String>[_picacgKey]);
      expect(fixture.preferences.enabledSources, <String>[_picacgKey]);
      expect(await appdataFile.readAsBytes(), appdataBytesBefore);
    },
  );

  test(
    'publishing falls back to the last-known-good 1.0.8 when the active snapshot is gone',
    () async {
      final target = _RepairObservingAppdata();
      final fixture = await _createPublishFixture(
        enabled: const [_picacgKey],
        appdata: target,
      );
      final broken = _pointer('a' * 40);
      final lkg = _pointer('b' * 40);
      final candidate = _pointer('c' * 40);
      final lkgScript = _sourceScript(
        key: _picacgKey,
        version: _installedVersion,
        minAppVersion: '1.0.0',
      );
      final candidateScript = _sourceScript(
        key: _picacgKey,
        version: _candidateVersion,
        minAppVersion: _incompatibleGate,
        tagSearch: true,
      );

      // `broken` is deliberately never written: the installed active pointer
      // has no readable cached snapshot left, so only the persisted
      // last-known-good can serve the App.
      await _writeLocalSnapshot(
        fixture.store,
        lkg,
        'lkg',
        key: _picacgKey,
        version: _installedVersion,
        source: lkgScript,
      );
      fixture.appdata.catalogRuntime = AppCatalogState(
        active: broken,
        lkg: lkg,
      ).toJson();
      fixture.appdata.settings['serverUrl'] = _hostServerUrl;
      fixture.appdata.settings['enabledSources'] = <String>[_picacgKey];

      _authority(fixture.responses, candidate);
      _availableRevision(
        fixture.responses,
        candidate,
        candidateScript,
        key: _picacgKey,
        version: _candidateVersion,
      );

      final controller = fixture.controller();
      final result = await controller.boot();

      expect(result, isA<CatalogReady>());
      final ready = result as CatalogReady;
      expect(ready.usedLocalFallback, isTrue);
      expect(ready.snapshot.manifest.pointer.identity, lkg.identity);
      expect(controller.sessionState?.active?.identity, lkg.identity);
      expect(controller.sessionState?.lkg, isNull);
      expect(await fixture.store.readSnapshot(candidate), isNull);
      final published = ComicSource.find(_picacgKey);
      expect(published, isNotNull);
      expect(published!.version, _installedVersion);
      expect(published.semanticSearchData, isNull);

      // The local fallback schedules a device-pointer repair. Wait for it on
      // the appdata write lock instead of sleeping, so the test never races the
      // asynchronous write or leaves it pointing at the next fixture.
      await target.pointerRepairPrepared.future.timeout(
        const Duration(seconds: 5),
      );
      final barrier = await fixture.appdata.prepareUserDataCommit(const {});
      await barrier.discard();
      expect(
        fixture.appdata.readCatalogState()!.active!.identity,
        lkg.identity,
      );
    },
  );

  test(
    'a new install of the incompatible candidate fails safely without erasing other sources',
    () async {
      final fixture = await _createPublishFixture(enabled: const [_picacgKey]);
      final candidate = _pointer('c' * 40);
      final candidateScript = _sourceScript(
        key: _picacgKey,
        version: _candidateVersion,
        minAppVersion: _incompatibleGate,
        tagSearch: true,
      );

      // A source that is already installed outside the Catalog. It is a real
      // parsed source and its legacy executable is discovered by
      // `LegacyMigration`, so a failed install must leave both untouched.
      final otherScript = _sourceScript(
        key: _otherKey,
        version: '1.0.0',
        minAppVersion: '1.0.0',
      );
      final legacyRoot = Directory(p.join(fixture.root.path, 'comic_source'));
      await legacyRoot.create(recursive: true);
      final legacyFile = File(p.join(legacyRoot.path, '$_otherKey.js'));
      await legacyFile.writeAsString(otherScript, flush: true);
      ComicSourceManager().add(
        await ComicSourceParser().parse(otherScript, '$_otherKey.js'),
      );

      _authority(fixture.responses, candidate);
      _availableRevision(
        fixture.responses,
        candidate,
        candidateScript,
        key: _picacgKey,
        version: _candidateVersion,
      );

      final controller = fixture.controller();
      final result = await controller.initialize(_hostServerUrl);

      // A brand-new installation has no active and no LKG, so the incompatible
      // candidate cannot be answered from anywhere: the install is refused.
      expect(fixture.appdata.readCatalogState(), isNull);
      expect(result, isA<CatalogNeedsInitialization>());
      final needsInit = result as CatalogNeedsInitialization;
      expect(needsInit.serverDraft, _hostServerUrl);
      expect(needsInit.failure, isNotNull);
      expect(
        needsInit.failure!.kind,
        CatalogSetupFailureKind.contentPreparationFailed,
      );
      expect(
        needsInit.failure!.diagnostic,
        startsWith('runtime:'),
        reason: 'the rejection must happen while preparing the candidate',
      );

      // Nothing was published, and every other installed source survived.
      expect(controller.sessionState, isNull);
      expect(fixture.appdata.sessionCatalogState, isNull);
      expect(ComicSource.find(_picacgKey), isNull);
      final other = ComicSource.find(_otherKey);
      expect(other, isNotNull);
      expect(other!.version, '1.0.0');
      expect(await legacyFile.exists(), isTrue);
      expect(await fixture.store.readSnapshot(candidate), isNull);
      expect(fixture.preferences.enabledSources, <String>[
        _picacgKey,
      ], reason: 'a refused install must not rewrite the selection');
    },
  );

  test(
    'the 1.0.9 candidate is published when the Host satisfies its gate',
    () async {
      final fixture = await _createPublishFixture(enabled: const [_picacgKey]);
      final installed = _pointer('a' * 40);
      final candidate = _pointer('c' * 40);
      final installedScript = _sourceScript(
        key: _picacgKey,
        version: _installedVersion,
        minAppVersion: '1.0.0',
      );
      // The intended production pair: `1.0.9` gated at `2.0.0`. The
      // development Host is `2.0.0-beta.3`, i.e. exactly the App-first ("new
      // Host") side of the rollout, so this direction must publish.
      final candidateScript = _sourceScript(
        key: _picacgKey,
        version: _candidateVersion,
        minAppVersion: _intendedGate,
        tagSearch: true,
      );
      expect(
        compareSemVer(_intendedGate, App.version.split('-').first),
        isFalse,
        reason: 'the development Host satisfies the intended 2.0.0 gate',
      );

      await _writeLocalSnapshot(
        fixture.store,
        installed,
        'installed',
        key: _picacgKey,
        version: _installedVersion,
        source: installedScript,
      );
      fixture.appdata.catalogRuntime = AppCatalogState(
        active: installed,
      ).toJson();
      fixture.appdata.settings['serverUrl'] = _hostServerUrl;
      fixture.appdata.settings['enabledSources'] = <String>[_picacgKey];

      _authority(fixture.responses, candidate);
      _availableRevision(
        fixture.responses,
        candidate,
        candidateScript,
        key: _picacgKey,
        version: _candidateVersion,
      );

      final controller = fixture.controller();
      final result = await controller.boot();

      expect(result, isA<CatalogReady>());
      final ready = result as CatalogReady;
      expect(ready.usedLocalFallback, isFalse);
      expect(ready.snapshot.manifest.pointer.identity, candidate.identity);
      expect(controller.sessionState?.active?.identity, candidate.identity);
      expect(controller.sessionState?.lkg?.identity, installed.identity);
      expect(
        fixture.appdata.readCatalogState()!.active!.identity,
        candidate.identity,
      );
      expect(await fixture.store.readSnapshot(candidate), isNotNull);
      final published = ComicSource.find(_picacgKey);
      expect(published, isNotNull);
      expect(published!.version, _candidateVersion);
      expect(
        published.semanticSearchData,
        isNotNull,
        reason: 'a satisfying Host does receive the tagSearch capability',
      );
    },
  );

  test('the 1.0.9 fixture really carries the tagSearch action', () async {
    // Control for the pair above: the only difference between the accepted and
    // the rejected candidate is its `minAppVersion` gate, not a malformed
    // script. This keeps the rejection attributable to the version gate.
    final accepted = await ComicSourceParser().parse(
      _sourceScript(
        key: 'semantic_gate_fixture_ok',
        version: _candidateVersion,
        minAppVersion: '1.0.0',
        tagSearch: true,
      ),
      'semantic_gate_fixture_ok.js',
    );
    expect(accepted.version, _candidateVersion);
    expect(accepted.semanticSearchData, isNotNull);

    await expectLater(
      ComicSourceParser().parse(
        _sourceScript(
          key: 'semantic_gate_fixture_gated',
          version: _candidateVersion,
          minAppVersion: _incompatibleGate,
          tagSearch: true,
        ),
        'semantic_gate_fixture_gated.js',
      ),
      throwsA(isA<ComicSourceParseException>()),
    );
  });
}

// ---------------------------------------------------------------------------
// Catalog publish/LKG fixture
// ---------------------------------------------------------------------------

const _hostServerUrl = 'https://server.example';
const _authorityUrl = 'https://server.example/api/catalog/authority';
const _picacgKey = 'picacg';
const _otherKey = 'other';
const _installedVersion = '1.0.8';
const _candidateVersion = '1.0.9';

/// The gate the intended Pica `1.0.9` config declares.
const _intendedGate = '2.0.0';

/// The gate used to *simulate an older Host*.
///
/// This development Host is `2.0.0-beta.3`, which satisfies the intended
/// `2.0.0` gate — it is the App-first side of the rollout, not the older App.
/// `App.version` is a `final` field, so a test cannot lower it. Raising the
/// candidate's gate above any version this build can claim drives the very
/// same `compareSemVer(minAppVersion, App.version)` branch in
/// [ComicSourceParser] that the older App would take for `2.0.0`.
const _incompatibleGate = '99.0.0';

class _Transport implements CatalogTransport {
  _Transport(this.responses);

  final Map<String, CatalogBytesResponse> responses;

  @override
  Future<CatalogBytesResponse> getBytes(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    CatalogCancellationToken? cancellation,
  }) async {
    final response = responses[uri.toString()];
    if (response == null) throw StateError('missing response for $uri');
    return response;
  }
}

/// Signals that the local-fallback pointer repair entered the appdata write
/// lock, so a test can await it deterministically instead of sleeping.
class _RepairObservingAppdata extends Appdata {
  _RepairObservingAppdata()
    : super.createForTesting(() async => Directory.systemTemp);

  final pointerRepairPrepared = Completer<void>();

  @override
  Future<PreparedAppDataCommit> prepareCatalogPointerRepair(
    CatalogPointer pointer,
  ) {
    if (!pointerRepairPrepared.isCompleted) pointerRepairPrepared.complete();
    return super.prepareCatalogPointerRepair(pointer);
  }
}

class _PublishFixture {
  _PublishFixture._({
    required this.root,
    required this.appdata,
    required this.store,
    required this.preferences,
    required this.responses,
  });

  final Directory root;
  final Appdata appdata;
  final CatalogStore store;
  final SourcePreferences preferences;
  final Map<String, CatalogBytesResponse> responses;

  CatalogController controller({Duration budget = catalogNormalPrepareBudget}) {
    return CatalogController(
      store: store,
      httpClient: CatalogHttpClient(transport: _Transport(responses)),
      runtimeLoader: CatalogRuntimeLoader.forComicSources(),
      preferences: preferences,
      appdata: appdata,
      legacyRoot: Directory(p.join(root.path, 'comic_source')),
      normalPrepareBudget: budget,
    );
  }
}

Future<_PublishFixture> _createPublishFixture({
  required List<String> enabled,
  Appdata? appdata,
}) async {
  final root = await Directory.systemTemp.createTemp('catalog-publish-gate-');
  final previousDataPath = App.dataPath;
  final manager = ComicSourceManager();
  final installedBefore = List<ComicSource>.from(manager.all());
  App.dataPath = root.path;
  final fixture = _PublishFixture._(
    root: root,
    appdata:
        appdata ?? Appdata.createForTesting(() async => Directory.systemTemp),
    store: CatalogStore(Directory(p.join(root.path, 'catalog'))),
    preferences: SourcePreferences(initial: List<String>.from(enabled)),
    responses: <String, CatalogBytesResponse>{},
  );
  addTearDown(() async {
    manager.installPreparedSources(installedBefore);
    fixture.preferences.dispose();
    App.dataPath = previousDataPath;
    await _removeEventually(root);
  });
  return fixture;
}

CatalogPointer _pointer(String revision) => CatalogPointer(
  catalogId: 'owner/repo',
  revision: revision,
  indexUrl: 'https://raw.githubusercontent.com/owner/repo/$revision/index.json',
);

Map<String, dynamic> _indexEntry(String key, String version) => {
  'name': key,
  'key': key,
  'fileName': '$key.js',
  'version': version,
};

/// A parsed comic source. `tagSearch` stands in for the action an older App
/// cannot interpret; the candidate that carries it is gated by
/// `minAppVersion`.
String _sourceScript({
  required String key,
  required String version,
  required String minAppVersion,
  bool tagSearch = false,
}) {
  final tagSearchDeclaration = tagSearch
      ? '''
    tagSearch: {
      load: async (value, options, page) => ({comics: [], maxPage: 1}),
    },
'''
      : '';
  return '''
class SemanticGateSource extends ComicSource {
  name = "Semantic gate";
  key = "$key";
  version = "$version";
  minAppVersion = "$minAppVersion";
  search = {
    load: async (keyword, options, page) => ({comics: [], maxPage: 1}),
$tagSearchDeclaration  };
  comic = {
    loadInfo: async (id) => ({}),
    loadEp: async (comicId, epId) => ({images: []}),
  };
}
''';
}

void _authority(
  Map<String, CatalogBytesResponse> responses,
  CatalogPointer pointer,
) {
  responses[_authorityUrl] = CatalogBytesResponse(
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

/// Serves one revision exactly like the pinned raw GitHub layout: an index plus
/// one source file per entry.
void _availableRevision(
  Map<String, CatalogBytesResponse> responses,
  CatalogPointer pointer,
  String source, {
  required String key,
  required String version,
}) {
  responses[pointer.indexUrl] = CatalogBytesResponse(
    200,
    utf8.encode(jsonEncode([_indexEntry(key, version)])),
  );
  responses['https://raw.githubusercontent.com/owner/repo/${pointer.revision}/$key.js'] =
      CatalogBytesResponse(200, utf8.encode(source));
}

/// Writes a complete, verified snapshot into the local Catalog store, i.e. the
/// already-installed assembly an older Host would boot from.
Future<void> _writeLocalSnapshot(
  CatalogStore store,
  CatalogPointer pointer,
  String attemptId, {
  required String key,
  required String version,
  required String source,
}) async {
  final entry = _indexEntry(key, version);
  final candidate = await store.createCandidate(
    pointer: pointer,
    indexBytes: utf8.encode(jsonEncode([entry])),
    index: CatalogIndex.fromJson([entry]),
    attemptId: attemptId,
  );
  await store.writeCandidateSource(
    candidate,
    CatalogSourceEntry.fromJson(entry),
    utf8.encode(source),
  );
  await store.promoteCandidate(await store.finalizeCandidate(candidate));
}

/// Windows can briefly hold a handle on a file a test just wrote; retry rather
/// than leaking a temp directory.
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
