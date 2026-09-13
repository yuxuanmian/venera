import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/res.dart';

import 'scan_retirement/fixtures.dart';

const _sourceKey = 'network-cache-test';

FavoriteItem _comic(String id, {String? favoriteId}) => FavoriteItem(
  id: id,
  name: 'Comic $id',
  coverPath: 'https://example.invalid/$id.jpg',
  author: 'Author',
  sourceKeyValue: _sourceKey,
  tags: const ['tag'],
  remoteFavoriteId: favoriteId,
);

FavoriteData _numberedData(
  Future<Res<List<Comic>>> Function(int page, [String? folder]) loader,
) => FavoriteData(
  key: _sourceKey,
  title: 'Network cache test',
  multiFolder: true,
  loadComic: loader,
  loadNext: null,
  loadFolders: ([_]) async => const Res({'remote': 'Remote'}),
);

void main() {
  late Directory directory;
  late NetworkFavoriteCacheManager cache;
  const folder = NetworkFavoriteFolderRef(
    sourceKey: _sourceKey,
    folderId: 'remote',
    title: 'Remote',
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('venera-network-cache-');
    cache = NetworkFavoriteCacheManager.forTesting();
    await cache.init(
      databasePath: '${directory.path}${Platform.pathSeparator}cache.db',
      migrateLegacy: false,
    );
  });

  tearDown(() async {
    cache.close();
    await directory.delete(recursive: true);
  });

  test(
    'numbered pages persist, replace, deduplicate, and survive failure',
    () async {
      final first = _numberedData(
        (page, [_]) async => Res([_comic('one'), _comic('one')], subData: 1),
      );
      await cache.refreshFolders(first);
      expect((await cache.refreshPage(first, folder, 1)).success, isTrue);
      expect(cache.getCachedPage(folder, 1)!.comics.single.id, 'one');
      expect(cache.isFavoriteKnown(_sourceKey, 'one'), isTrue);

      final replacement = _numberedData(
        (page, [_]) async => Res([_comic('two')], subData: 1),
      );
      await cache.refreshPage(replacement, folder, 1);
      expect(cache.getCachedPage(folder, 1)!.comics.single.id, 'two');
      expect(cache.isFavoriteKnown(_sourceKey, 'one'), isFalse);
      expect(cache.isFavoriteKnown(_sourceKey, 'two'), isTrue);

      final failed = _numberedData(
        (page, [_]) async => const Res.error('offline'),
      );
      expect((await cache.refreshPage(failed, folder, 1)).error, isTrue);
      expect(cache.getCachedPage(folder, 1)!.comics.single.id, 'two');
    },
  );

  test('ordinary full cache keeps its completed pages and status', () async {
    final data = _numberedData(
      (page, [_]) async => page == 1
          ? Res([_comic('one')], subData: 2)
          : Res([_comic('two')], subData: 2),
    );
    final frames = await cache
        .cacheAllPages(data, folder, isCanceled: () => false)
        .toList();

    expect(frames.last.isComplete, isTrue);
    expect(cache.countCachedComics(folder), 2);
    expect(cache.getFullCacheStatus(folder).isComplete, isTrue);
  });

  test(
    'mark-read stays scoped and never wakes the retired hot window (007 FR-011)',
    () async {
      final data = _numberedData(
        (page, [_]) async => Res([_comic('one')], subData: 1),
      );
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);

      final before = cache.getComicsWithUpdatesInfo(folder).single;
      // No entry can have set these, because the only writer is gone (`toggle
      // ManualHotWindow` was deleted).  The columns still exist and still read
      // back — they are kept, not deleted (FR-031) — but always at "off".
      expect(before.manualHotEnabled, isFalse);
      expect(before.manualHotUntil, isNull);

      cache.markReadInAllFolders(_sourceKey, 'one');
      final read = cache.getComicsWithUpdatesInfo(folder).single;
      expect(read.hasNewUpdate, isFalse);
      expect(
        read.manualHotEnabled,
        isFalse,
        reason: 'marking read must not enable a hot window',
      );
      expect(read.manualHotUntil, isNull);
      expect(read.lastCheckTime, before.lastCheckTime);
      expect(read.nextCheckAt, before.nextCheckAt);
      expect(read.updateMarker, before.updateMarker);
    },
  );

  test('the manual hot-window write entry no longer exists anywhere', () {
    // `toggleManualHotWindow` was the last production writer of the legacy
    // marker store's manual hot-window columns.  It cannot be referenced from
    // Dart any more (the analyzer would reject it), so the remaining guard is
    // structural: no source file may define or call it.
    const paths = <String>[
      'lib/foundation/favorites.dart',
      'lib/pages/comic_details_page/comic_page.dart',
      'lib/pages/comic_details_page/favorite.dart',
      'lib/pages/follow_updates_page.dart',
      'lib/pages/settings/settings_page.dart',
    ];
    for (final path in paths) {
      final source = File(path)
          .readAsStringSync()
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      expect(
        source,
        isNot(contains('toggleManualHotWindow')),
        reason: '$path must not carry a manual hot-window write path',
      );
    }
  });

  test(
    'initialized historical scan rows remain readable without execution',
    () async {
      final fixture = await createRetirementFixture();
      addTearDown(fixture.dispose);

      final folder = const NetworkFavoriteFolderRef(
        sourceKey: retirementSourceA,
        folderId: retirementFolderTwo,
      );
      final scan = fixture.cache.getFavoriteUpdateScanState(folder);
      expect(scan, isNotNull);
      expect(scan!.lastPageCount, 3);
      expect(scan.lastComicCount, 6);

      final history = fixture.cache.getComicsWithUpdatesInfo(
        const NetworkFavoriteFolderRef(
          sourceKey: retirementSourceA,
          folderId: retirementFolderOne,
        ),
      );
      expect(history.map((item) => item.id), contains('retire-a'));
      final item = history.firstWhere((item) => item.id == 'retire-a');
      expect(item.updateMarker, 'legacy-test|chapter-10');
      expect(item.updateState?.latestChapterId, 'chapter-10');
      expect(item.sourceUpdateMetadata?['source'], 'retirement-fixture');
    },
  );

  test(
    'clearAllCache clears ordinary cache and advances its generation',
    () async {
      final data = _numberedData(
        (page, [_]) async => Res([_comic('one')], subData: 1),
      );
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);
      final generation = cache.cacheGeneration;

      cache.clearAllCache();

      expect(cache.cacheGeneration, generation + 1);
      expect(cache.countCachedComics(folder), 0);
      expect(cache.getCachedPage(folder, 1), isNull);
    },
  );
}
