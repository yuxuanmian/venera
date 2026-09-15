import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/utils/translations.dart';

/// The App-side half of the feature 008 release gate.
///
/// The gate has two halves:
///
/// 1. **This file** — the Host must reject a candidate whose `minAppVersion`
///    is newer than the running App, and must keep the previously installed
///    source usable. This is what lets an older App stay on Pica `1.0.8`
///    instead of receiving a config that requires the new `tagSearch` action.
/// 2. The Catalog publish/last-known-good half, which must additionally prove
///    that a rejected candidate leaves the previously published assembly in
///    place. **That half is not implemented here** — see the note at the
///    bottom of this file. Task T058 therefore stays open, and the Pica
///    `version` / `minAppVersion` / `index.json` fields must not be raised
///    until it is proven.
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

  // NOTE (T058, not implemented): the second half of the release gate is the
  // Catalog *publish* proof — an older Host with installed `1.0.8` must keep
  // publishing last-known-good `1.0.8` when it sees the incompatible `1.0.9`
  // candidate, and an older Host with no LKG must fail safely without erasing
  // other installed sources. Proving that requires driving
  // `CatalogController`'s attempt/publish/LKG path with prepared fake
  // artifacts. It is intentionally not faked here: a green test that does not
  // exercise the real publish path would be worse than an open task. Per
  // tasks.md T058/T060, Pica's `version`, `minAppVersion` and `index.json`
  // entry stay unchanged until that proof exists.
}
