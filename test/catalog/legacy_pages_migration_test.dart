import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/controller.dart';
import 'package:venera/foundation/catalog/http_client.dart';
import 'package:venera/foundation/catalog/runtime_loader.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';
import 'package:venera/foundation/catalog/store.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

class _Transport implements CatalogTransport {
  String revision = 'a' * 40;

  @override
  Future<CatalogBytesResponse> getBytes(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    CatalogCancellationToken? cancellation,
  }) async {
    final Object body;
    if (uri.path.endsWith('/authority')) {
      body = {
        'catalogId': 'owner/repo',
        'activeRevision': revision,
        'indexUrl':
            'https://raw.githubusercontent.com/owner/repo/$revision/index.json',
      };
    } else if (uri.path.endsWith('/index.json')) {
      body = [
        for (final key in ['manwa', 'demo', 'new_source'])
          {'name': key, 'key': key, 'fileName': '$key.js', 'version': '1'},
      ];
    } else {
      return CatalogBytesResponse(200, utf8.encode('source'));
    }
    return CatalogBytesResponse(200, utf8.encode(jsonEncode(body)));
  }
}

ComicSource _source(String key) => ComicSource(
  key,
  key,
  null,
  key == 'demo'
      ? CategoryData(
          title: key,
          categories: [],
          enableRankingPage: false,
          key: key,
        )
      : null,
  null,
  FavoriteData(
    key: key,
    title: key,
    multiFolder: false,
    loadComic: null,
    loadNext: null,
  ),
  key == 'demo'
      ? [
          ExplorePageData(
            'demo explore',
            ExplorePageType.multiPageComicList,
            null,
            null,
            null,
            null,
          ),
        ]
      : [],
  key == 'demo' ? const SearchPageData(null, null, null) : null,
  null,
  null,
  null,
  null,
  null,
  null,
  '$key.js',
  '',
  '1',
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  false,
  false,
  null,
  null,
);

void main() {
  for (final scenario in [
    'missing',
    'search only',
    'disabled',
    'failed commit',
  ]) {
    test('legacy page migration: $scenario', () async {
      final root = await Directory.systemTemp.createTemp('legacy-pages-');
      final oldPath = App.isInitialized ? App.dataPath : null;
      final oldSources = ComicSource.all().toList();
      App.dataPath = root.path;
      final target = Appdata.createForTesting(() async => root);
      final preferences = SourcePreferences(
        initial: scenario == 'disabled' ? [] : null,
      );
      final transport = _Transport();
      final legacy = Directory('${root.path}/comic_source');
      await legacy.create();
      for (final key in ['manwa', 'demo']) {
        await File(
          '${legacy.path}/$key.js',
        ).writeAsString('class Main extends ComicSource { key = "$key"; }');
      }
      target.settings['favorites'] = <String>['unrelated'];
      target.settings['explore_pages'] = <String>[];
      target.settings['categories'] = <String>[];
      target.settings['searchSources'] = scenario == 'search only'
          ? <String>['demo']
          : <String>[];
      await File(
        '${root.path}/appdata.json',
      ).writeAsString(jsonEncode(target.toJson()));
      final originalBytes = await File(
        '${root.path}/appdata.json',
      ).readAsString();
      if (scenario == 'failed commit') {
        target.atomicReplace = (_, _) async =>
            throw StateError('replace failed');
      }
      final controller = CatalogController(
        store: CatalogStore(Directory('${root.path}/catalog')),
        httpClient: CatalogHttpClient(transport: transport),
        runtimeLoader: CatalogRuntimeLoader(
          factory: (entry, _, _) => _source(entry.key),
        ),
        preferences: preferences,
        appdata: target,
        legacyRoot: legacy,
      );
      addTearDown(() async {
        controller.dispose();
        preferences.dispose();
        ComicSourceManager().installPreparedSources(oldSources);
        if (oldPath != null) App.dataPath = oldPath;
        await root.delete(recursive: true);
      });
      final result = await controller.initialize('https://server.example');
      if (scenario == 'failed commit') {
        expect(result, isA<CatalogNeedsRecovery>());
        expect(target.settings['favorites'], ['unrelated']);
        expect(target.catalogRuntime, isNull);
        expect(
          await File('${root.path}/appdata.json').readAsString(),
          originalBytes,
        );
        expect(await File('${legacy.path}/manwa.js').exists(), isTrue);
        return;
      }
      expect(result, isA<CatalogReady>());
      if (scenario == 'disabled') {
        expect(preferences.enabledSources, isEmpty);
        expect(target.settings['favorites'], ['unrelated']);
        for (final key in ['explore_pages', 'categories', 'searchSources']) {
          expect(target.settings[key], isEmpty);
        }
        return;
      }
      expect(preferences.enabledSources, ['demo', 'manwa']);
      expect(ComicSource.find('manwa'), isNotNull);
      expect(target.settings['favorites'], contains('manwa'));
      expect(target.settings['favorites'], isNot(contains('new_source')));
      expect(target.settings['searchSources'], ['demo']);
      expect(
        target.settings['explore_pages'],
        scenario == 'search only' ? isEmpty : ['demo explore'],
      );
      expect(
        target.settings['categories'],
        scenario == 'search only' ? isEmpty : ['demo'],
      );
      expect(
        target.settings['favorites'],
        scenario == 'search only' ? isNot(contains('demo')) : contains('demo'),
      );
      final persisted =
          jsonDecode(await File('${root.path}/appdata.json').readAsString())
              as Map;
      expect(persisted['settings']['favorites'], target.settings['favorites']);
      expect(persisted['settings']['enabledSources'], ['demo', 'manwa']);

      target.settings['favorites'] = <String>['unrelated'];
      await target.saveData();
      transport.revision = 'b' * 40;
      expect(await controller.boot(), isA<CatalogReady>());
      expect(target.readCatalogState()!.active!.revision, transport.revision);
      expect(preferences.enabledSources, ['demo', 'manwa']);
      expect(target.settings['favorites'], ['unrelated']);
      // Even leftover legacy files must not make recovery repeat migration.
      await File('${legacy.path}/manwa.js').writeAsString('source');
      expect(
        await controller.recover('https://server.example'),
        isA<CatalogReady>(),
      );
      expect(target.settings['favorites'], ['unrelated']);
    });
  }
}
