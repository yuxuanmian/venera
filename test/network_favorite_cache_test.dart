import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/res.dart';

FavoriteItem _comic(
  String id, {
  String name = 'Comic',
  String author = 'Author',
  String? coverPath,
}) => FavoriteItem(
  id: id,
  name: name,
  coverPath: coverPath ?? 'https://example.invalid/$id.jpg',
  author: author,
  sourceKeyValue: 'test-source',
  tags: const ['tag'],
);

FavoriteData _numericData(
  Future<Res<List<Comic>>> Function(int page, [String? folder]) loader,
) => FavoriteData(
  key: 'test-source',
  title: 'Test source',
  multiFolder: true,
  loadComic: loader,
  loadNext: null,
  loadFolders: ([String? _]) async =>
      const Res(<String, String>{'remote': 'Remote'}),
);

ComicSource _detailSource(
  Future<Res<ComicDetails>> Function(String id) loader,
) {
  return ComicSource(
    'Test source',
    'test-source',
    null,
    null,
    null,
    null,
    const [],
    null,
    null,
    loader,
    null,
    null,
    null,
    null,
    '',
    '',
    '1.0.0',
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
}

void main() {
  late Directory tempDir;
  late NetworkFavoriteCacheManager cache;
  const folder = NetworkFavoriteFolderRef(
    sourceKey: 'test-source',
    folderId: 'remote',
    title: 'Remote',
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('venera-favorite-cache-');
    cache = NetworkFavoriteCacheManager.forTesting();
    await cache.init(
      databasePath: '${tempDir.path}${Platform.pathSeparator}cache.db',
      migrateLegacy: false,
    );
  });

  tearDown(() async {
    cache.close();
    await tempDir.delete(recursive: true);
  });

  test(
    'numeric pages persist, overwrite on success, and survive failure',
    () async {
      final initial = _numericData(
        (page, [folder]) async => Res(<Comic>[_comic('one')], subData: 2),
      );
      await cache.refreshFolders(initial);
      final first = await cache.refreshPage(initial, folder, 1);
      expect(first.success, isTrue);
      expect(cache.getCachedPage(folder, 1)!.comics.single.id, 'one');

      final replacement = _numericData(
        (page, [folder]) async => Res(<Comic>[_comic('two')], subData: 2),
      );
      await cache.refreshPage(replacement, folder, 1);
      expect(cache.getCachedPage(folder, 1)!.comics.single.id, 'two');

      final failed = _numericData(
        (page, [folder]) async => const Res.error('offline'),
      );
      final result = await cache.refreshPage(failed, folder, 1);
      expect(result.error, isTrue);
      expect(cache.getCachedPage(folder, 1)!.comics.single.id, 'two');
    },
  );

  test('duplicate comics on the same page are deduplicated', () async {
    final data = _numericData(
      (page, [folder]) async =>
          Res(<Comic>[_comic('dup'), _comic('dup')], subData: 1),
    );
    await cache.refreshFolders(data);

    final result = await cache.refreshPage(data, folder, 1);

    expect(result.success, isTrue);
    expect(cache.getCachedPage(folder, 1)!.comics.length, 1);
    expect(cache.getCachedPage(folder, 1)!.comics.single.id, 'dup');
  });

  test('tryFromJson tolerates malformed persisted folder data', () {
    expect(
      NetworkFavoriteFolderRef.tryFromJson({
        'sourceKey': 'test-source',
        'folderId': 'remote',
        'title': 123,
      }),
      isNull,
    );
  });

  test('clearAllCache removes folders, pages, items and memberships', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[_comic('one')], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);
    expect(cache.getCachedPage(folder, 1), isNotNull);

    cache.clearAllCache();

    expect(cache.getCachedFolders('test-source'), isEmpty);
    expect(cache.getCachedPage(folder, 1), isNull);
    expect(cache.countCachedComics(folder), 0);
    expect(cache.isFavoriteKnown('test-source', 'one'), isFalse);
    expect(cache.getFullCacheStatus(folder).isComplete, isFalse);
  });

  test('removing a favorite falls back to the cached favorite id', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[
        FavoriteItem(
          id: 'one',
          name: 'One',
          coverPath: 'https://example.invalid/one.jpg',
          author: 'Author',
          sourceKeyValue: 'test-source',
          tags: const ['tag'],
          remoteFavoriteId: 'fav-1',
        ),
      ], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);

    String? receivedFavoriteId;
    final mutationData = FavoriteData(
      key: 'test-source',
      title: 'Test source',
      multiFolder: true,
      loadComic: data.loadComic,
      loadNext: null,
      loadFolders: data.loadFolders,
      addOrDelFavorite: (comicId, folderId, isAdding, favoriteId) async {
        receivedFavoriteId = favoriteId;
        return const Res(true);
      },
    );
    final source = ComicSource(
      'Test source',
      'test-source',
      null,
      null,
      null,
      mutationData,
      const [],
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      '',
      '',
      '1.0.0',
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
    source.data['account'] = ['user'];
    ComicSourceManager().add(source);
    addTearDown(() => ComicSourceManager().remove('test-source'));

    final result = await cache.changeFavorite(
      data: mutationData,
      folder: folder,
      comicId: 'one',
      isAdding: false,
    );

    expect(result.success, isTrue);
    expect(receivedFavoriteId, 'fav-1');
    expect(cache.getCachedPage(folder, 1)!.updatedAt.millisecondsSinceEpoch, 0);
  });

  test('cursor changes invalidate later cached pages', () async {
    var firstNext = 'next-a';
    final cursorData = FavoriteData(
      key: 'test-source',
      title: 'Test source',
      multiFolder: true,
      loadComic: null,
      loadNext: (token, [folder]) async {
        if (token == null) {
          return Res(<Comic>[_comic('first')], subData: firstNext);
        }
        return Res(<Comic>[_comic('second')], subData: null);
      },
      loadFolders: ([String? _]) async =>
          const Res(<String, String>{'remote': 'Remote'}),
    );

    await cache.refreshNextPage(cursorData, folder, null);
    await cache.refreshNextPage(cursorData, folder, 'next-a');
    expect(cache.getCachedNextPage(folder, 'next-a'), isNotNull);

    firstNext = 'next-b';
    await cache.refreshNextPage(cursorData, folder, null);
    expect(cache.getCachedNextPage(folder, 'next-a'), isNull);
    expect(cache.getCachedNextPage(folder, null)!.nextToken, 'next-b');
  });

  test(
    'remote folder removal clears its cache and offline mutation is inert',
    () async {
      final data = _numericData(
        (page, [folder]) async => Res(<Comic>[_comic('one')], subData: 1),
      );
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);
      expect(cache.getCachedPage(folder, 1), isNotNull);

      final noFolders = FavoriteData(
        key: 'test-source',
        title: 'Test source',
        multiFolder: true,
        loadComic: data.loadComic,
        loadNext: null,
        loadFolders: ([String? _]) async => const Res(<String, String>{}),
      );
      await cache.refreshFolders(noFolders);
      expect(cache.getCachedPage(folder, 1), isNull);

      final offline = await cache.changeFavorite(
        data: data,
        folder: folder,
        comicId: 'one',
        isAdding: true,
      );
      expect(offline.error, isTrue);
      expect(cache.isFavoriteKnown('test-source', 'one'), isFalse);
    },
  );

  test(
    'background summary refresh keeps covers while replacing list metadata',
    () async {
      var remoteComic = _comic(
        'one',
        name: 'Old name',
        author: 'Old author',
        coverPath: 'https://example.invalid/old.jpg',
      );
      final data = _numericData(
        (page, [folder]) async => Res(<Comic>[remoteComic], subData: 1),
      );
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);

      remoteComic = _comic(
        'one',
        name: 'New name',
        author: 'New author',
        coverPath: 'https://example.invalid/new.jpg',
      );
      await cache.refreshCachedSummaries(data, minimumAge: Duration.zero);

      final cached = cache.getCachedPage(folder, 1)!.comics.single;
      expect(cached.name, 'New name');
      expect(cached.author, 'New author');
      expect(cached.coverPath, 'https://example.invalid/old.jpg');
    },
  );

  test(
    'manual numeric full cache stores every page and preserves covers',
    () async {
      var useNewCover = false;
      final data = _numericData((page, [folder]) async {
        final cover = useNewCover
            ? 'https://example.invalid/new-$page.jpg'
            : 'https://example.invalid/old-$page.jpg';
        return Res(<Comic>[
          _comic('comic-$page', name: 'Comic $page', coverPath: cover),
        ], subData: 3);
      });
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);
      useNewCover = true;

      final progress = await cache
          .cacheAllPages(data, folder, isCanceled: () => false)
          .toList();

      expect(progress.last.isComplete, isTrue);
      expect(progress.last.totalPages, 3);
      expect(progress.last.comicsCached, 3);
      expect(cache.getCachedPage(folder, 3)!.comics.single.id, 'comic-3');
      expect(
        cache.getCachedPage(folder, 1)!.comics.single.coverPath,
        'https://example.invalid/old-1.jpg',
      );
      final status = cache.getFullCacheStatus(folder);
      expect(status.isComplete, isTrue);
      expect(status.pageCount, 3);
      expect(status.comicCount, 3);
    },
  );

  test(
    'manual cursor full cache follows cursors and reports indeterminate',
    () async {
      final data = FavoriteData(
        key: 'test-source',
        title: 'Test source',
        multiFolder: true,
        loadComic: null,
        loadNext: (token, [folder]) async {
          if (token == null) {
            return Res(<Comic>[_comic('first')], subData: 'cursor-1');
          }
          return Res(<Comic>[_comic('second')], subData: null);
        },
        loadFolders: ([String? _]) async =>
            const Res(<String, String>{'remote': 'Remote'}),
      );

      final progress = await cache
          .cacheAllPages(data, folder, isCanceled: () => false)
          .toList();

      expect(progress.last.isComplete, isTrue);
      expect(progress.where((item) => item.totalPages != null), isEmpty);
      expect(cache.getCachedNextPage(folder, 'cursor-1'), isNotNull);
      final status = cache.getFullCacheStatus(folder);
      expect(status.pageCount, 2);
      expect(status.comicCount, 2);
    },
  );

  test(
    'full cache cancellation and failure keep committed pages incomplete',
    () async {
      var calls = 0;
      final data = _numericData((page, [folder]) async {
        calls++;
        if (page == 2) return const Res.error('offline');
        return Res(<Comic>[_comic('comic-$page')], subData: 3);
      });
      await cache.refreshFolders(data);
      final failed = await cache
          .cacheAllPages(data, folder, isCanceled: () => false)
          .toList();
      expect(failed.last.errorMessage, 'offline');
      expect(cache.getCachedPage(folder, 1), isNotNull);
      expect(cache.getFullCacheStatus(folder).isComplete, isFalse);

      calls = 0;
      final canceled = await cache
          .cacheAllPages(data, folder, isCanceled: () => calls >= 1)
          .toList();
      expect(canceled.last.isCanceled, isTrue);
      expect(cache.getCachedPage(folder, 1), isNotNull);
      expect(cache.getFullCacheStatus(folder).isComplete, isFalse);
    },
  );

  test('cached search covers all pages and all summary fields', () async {
    final data = _numericData((page, [folder]) async {
      if (page == 1) {
        return Res(<Comic>[
          FavoriteItem(
            id: 'first-id',
            name: 'Alpha Hero',
            coverPath: 'https://example.invalid/first.jpg',
            author: 'Jane Writer',
            sourceKeyValue: 'test-source',
            tags: const ['Action', 'Space'],
          ),
        ], subData: 2);
      }
      return Res(<Comic>[
        FavoriteItem(
          id: 'second-id',
          name: 'Beta Story',
          coverPath: 'https://example.invalid/second.jpg',
          author: 'Alice Artist',
          sourceKeyValue: 'test-source',
          tags: const ['Mystery', 'School'],
        ),
        FavoriteItem(
          id: 'first-id',
          name: 'Alpha Hero',
          coverPath: 'https://example.invalid/duplicate.jpg',
          author: 'Jane Writer',
          sourceKeyValue: 'test-source',
          tags: const ['Action'],
        ),
      ], subData: 2);
    });
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);
    await cache.refreshPage(data, folder, 2);
    const otherFolder = NetworkFavoriteFolderRef(
      sourceKey: 'test-source',
      folderId: 'other',
      title: 'Other',
    );
    await cache.refreshPage(data, otherFolder, 1);

    expect(cache.searchCachedComics(folder, 'alpha').single.id, 'first-id');
    expect(cache.searchCachedComics(folder, 'writer').single.id, 'first-id');
    expect(cache.searchCachedComics(folder, 'mystery').single.id, 'second-id');
    expect(
      cache.searchCachedComics(folder, 'second-id').single.id,
      'second-id',
    );
    expect(
      cache.searchCachedComics(folder, 'beta artist').single.id,
      'second-id',
    );
    expect(cache.searchCachedComics(folder, 'hero').length, 1);
    expect(cache.searchCachedComics(folder, 'alpha').length, 1);
    expect(cache.searchCachedComics(otherFolder, 'beta'), isEmpty);
  });

  test('initialization backfills old cached search text', () async {
    cache.close();
    final databasePath = '${tempDir.path}${Platform.pathSeparator}cache.db';
    File(databasePath).deleteSync();
    final database = sqlite3.open(databasePath);
    database.execute('''
      CREATE TABLE favorite_items (
        source_key TEXT NOT NULL,
        folder_id TEXT NOT NULL,
        page_index INTEGER NOT NULL,
        comic_id TEXT NOT NULL,
        display_order INTEGER NOT NULL,
        comic_json TEXT NOT NULL,
        favorite_id TEXT,
        favorite_time TEXT NOT NULL,
        last_update_time TEXT,
        last_check_time INTEGER,
        has_new_update INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (source_key, folder_id, page_index, comic_id)
      );
    ''');
    database.execute(
      'INSERT INTO favorite_items VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        'test-source',
        'remote',
        1,
        'old-id',
        0,
        '{"title":"Old cached title","subTitle":"Old author","tags":["OldTag"]}',
        null,
        '2026-08-04 00:00:00',
        null,
        null,
        0,
      ],
    );
    database.dispose();

    cache = NetworkFavoriteCacheManager.forTesting();
    await cache.init(databasePath: databasePath, migrateLegacy: false);

    expect(cache.searchCachedComics(folder, 'oldtag').single.id, 'old-id');
    expect(cache.searchCachedComics(folder, 'old author').single.id, 'old-id');

    cache.markComicRetryLater(folder, 'old-id');
    expect(cache.getComicsWithUpdatesInfo(folder).single.retryAfter, isNotNull);
  });

  test('detail checks establish a baseline and store basic metadata', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[_comic('one')], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);

    cache.updateBasicInfo(
      folder,
      'one',
      title: 'Renamed',
      author: 'Updated author',
      chapterCount: 12,
    );
    expect(
      cache.recordComicCheck(
        folder,
        'one',
        updateTime: '2026-8-3',
        updateMarker: 'time:2026-8-3|chapters:12',
      ),
      isFalse,
    );
    var checked = cache.getComicsWithUpdatesInfo(folder).single;
    expect(checked.name, 'Renamed');
    expect(checked.author, 'Updated author');
    expect(checked.chapterCount, 12);
    expect(checked.coverPath, 'https://example.invalid/one.jpg');
    expect(checked.hasNewUpdate, isFalse);

    expect(
      cache.recordComicCheck(
        folder,
        'one',
        updateTime: '2026-8-3',
        updateMarker: 'time:2026-8-3|chapters:13',
      ),
      isTrue,
    );
    checked = cache.getComicsWithUpdatesInfo(folder).single;
    expect(checked.hasNewUpdate, isTrue);
    expect(checked.updateMarker, 'time:2026-8-3|chapters:13');
  });

  test(
    'unchecked comics track baseline completion and clearAllBaselines',
    () async {
      final data = _numericData(
        (page, [folder]) async => Res(<Comic>[
          _comic('one'),
          _comic('two'),
          _comic('three'),
        ], subData: 1),
      );
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);

      expect(cache.countUncheckedComics(folder), 3);
      expect(cache.hasUncheckedComics(folder), isTrue);

      cache.recordComicCheck(
        folder,
        'one',
        updateTime: '2026-8-3',
        updateMarker: 'time:2026-8-3|chapters:5',
      );
      expect(cache.countUncheckedComics(folder), 2);
      cache.recordComicCheck(
        folder,
        'two',
        updateTime: '2026-8-3',
        updateMarker: 'time:2026-8-3|chapters:6',
      );
      cache.recordComicCheck(
        folder,
        'three',
        updateTime: '2026-8-3',
        updateMarker: 'time:2026-8-3|chapters:7',
      );
      expect(cache.countUncheckedComics(folder), 0);
      expect(cache.hasUncheckedComics(folder), isFalse);

      cache.clearAllBaselines();
      expect(cache.countUncheckedComics(folder), 3);
      expect(cache.hasUncheckedComics(folder), isTrue);
      final reset = cache.getComicsWithUpdatesInfo(folder);
      expect(reset, hasLength(3));
      expect(
        reset.every(
          (comic) =>
              comic.updateMarker == null &&
              comic.updateTime == null &&
              !comic.hasNewUpdate,
        ),
        isTrue,
      );
    },
  );

  test('missing updateFolder only checks unchecked comics', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[
        _comic('one'),
        _comic('two'),
        _comic('three'),
      ], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);
    cache.recordComicCheck(
      folder,
      'one',
      updateTime: '2026-8-3',
      updateMarker: 'time:2026-8-3|chapters:5',
    );

    var detailCalls = 0;
    final source = _detailSource((id) async {
      detailCalls++;
      return Res(
        ComicDetails.fromJson({
          'title': 'Comic',
          'subtitle': 'Author',
          'cover': '',
          'tags': <String, List<String>>{},
          'chapters': <String, String>{'1': 'Chapter 1'},
          'sourceKey': 'test-source',
          'comicId': id,
        }),
      );
    });
    ComicSourceManager().add(source);
    addTearDown(() => ComicSourceManager().remove('test-source'));

    await updateFolder(folder, FollowUpdateMode.missing, cache: cache).toList();
    expect(detailCalls, 2);
    expect(cache.countUncheckedComics(folder), 0);

    await updateFolder(folder, FollowUpdateMode.missing, cache: cache).toList();
    expect(detailCalls, 2);
  });

  test('regular updateFolder skips recent checks and fills gaps', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[
        _comic('one'),
        _comic('two'),
        _comic('three'),
      ], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);
    cache.recordComicCheck(
      folder,
      'one',
      updateTime: '2026-8-3',
      updateMarker: 'time:2026-8-3|chapters:5',
    );

    var detailCalls = 0;
    final source = _detailSource((id) async {
      detailCalls++;
      return Res(
        ComicDetails.fromJson({
          'title': 'Comic',
          'subtitle': 'Author',
          'cover': '',
          'tags': <String, List<String>>{},
          'chapters': <String, String>{'1': 'Chapter 1'},
          'sourceKey': 'test-source',
          'comicId': id,
        }),
      );
    });
    ComicSourceManager().add(source);
    addTearDown(() => ComicSourceManager().remove('test-source'));

    await updateFolder(folder, FollowUpdateMode.regular, cache: cache).toList();
    expect(detailCalls, 2);
    expect(cache.countUncheckedComics(folder), 0);
  });

  test('force updateFolder rechecks every comic', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[
        _comic('one'),
        _comic('two'),
        _comic('three'),
      ], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);
    for (final id in ['one', 'two', 'three']) {
      cache.recordComicCheck(
        folder,
        id,
        updateTime: '2026-8-3',
        updateMarker: 'time:2026-8-3|chapters:5',
      );
    }

    var detailCalls = 0;
    final source = _detailSource((id) async {
      detailCalls++;
      return Res(
        ComicDetails.fromJson({
          'title': 'Comic',
          'subtitle': 'Author',
          'cover': '',
          'tags': <String, List<String>>{},
          'chapters': <String, String>{'1': 'Chapter 1'},
          'sourceKey': 'test-source',
          'comicId': id,
        }),
      );
    });
    ComicSourceManager().add(source);
    addTearDown(() => ComicSourceManager().remove('test-source'));

    await updateFolder(folder, FollowUpdateMode.force, cache: cache).toList();
    expect(detailCalls, 3);
  });

  test('canceled updateFolder does not process comics', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[
        _comic('one'),
        _comic('two'),
        _comic('three'),
      ], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);

    var detailCalls = 0;
    final source = _detailSource((id) async {
      detailCalls++;
      return Res(
        ComicDetails.fromJson({
          'title': 'Comic',
          'subtitle': 'Author',
          'cover': '',
          'tags': <String, List<String>>{},
          'chapters': <String, String>{'1': 'Chapter 1'},
          'sourceKey': 'test-source',
          'comicId': id,
        }),
      );
    });
    ComicSourceManager().add(source);
    addTearDown(() => ComicSourceManager().remove('test-source'));

    await updateFolder(
      folder,
      FollowUpdateMode.missing,
      isCanceled: () => true,
      cache: cache,
    ).toList();
    expect(detailCalls, 0);
    expect(cache.countUncheckedComics(folder), 3);
  });

  test('comics with updates info paginates in chunks of 50', () async {
    final data = _numericData(
      (page, [folder]) async => Res(
        List<Comic>.generate(120, (index) => _comic('comic-$index')),
        subData: 1,
      ),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);

    expect(cache.countComicsWithUpdatesInfo(folder), 120);
    expect(
      cache.getComicsWithUpdatesInfoPage(folder, limit: 50, offset: 0).length,
      50,
    );
    expect(
      cache.getComicsWithUpdatesInfoPage(folder, limit: 50, offset: 50).length,
      50,
    );
    final lastPage = cache.getComicsWithUpdatesInfoPage(
      folder,
      limit: 50,
      offset: 100,
    );
    expect(lastPage.length, 20);
    expect(lastPage.first.id, 'comic-100');
  });

  test('retry_after skips cooled comics unless ignored', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[
        _comic('one'),
        _comic('two'),
        _comic('three'),
      ], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);
    cache.markComicRetryLater(folder, 'two');

    var detailCalls = 0;
    final source = _detailSource((id) async {
      detailCalls++;
      return Res(
        ComicDetails.fromJson({
          'title': 'Comic',
          'subtitle': 'Author',
          'cover': '',
          'tags': <String, List<String>>{},
          'chapters': <String, String>{'1': 'Chapter 1'},
          'sourceKey': 'test-source',
          'comicId': id,
        }),
      );
    });
    ComicSourceManager().add(source);
    addTearDown(() => ComicSourceManager().remove('test-source'));

    await updateFolder(folder, FollowUpdateMode.missing, cache: cache).toList();
    expect(detailCalls, 2);

    await updateFolder(
      folder,
      FollowUpdateMode.missing,
      ignoreRetryAfter: true,
      cache: cache,
    ).toList();
    expect(detailCalls, 3);
  });

  test('cooldown-only missing run keeps real baseline counts', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[
        _comic('one'),
        _comic('two'),
        _comic('three'),
      ], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);
    cache.recordComicCheck(
      folder,
      'one',
      updateTime: '2026-8-3',
      updateMarker: 'time:2026-8-3|chapters:5',
    );
    cache.markComicRetryLater(folder, 'two');
    cache.markComicRetryLater(folder, 'three');

    final progress = await updateFolder(
      folder,
      FollowUpdateMode.missing,
      cache: cache,
    ).toList();

    expect(progress.last.total, 0);
    expect(progress.last.current, 0);
    expect(cache.countCachedComics(folder), 3);
    expect(cache.countUncheckedComics(folder), 2);
    expect(
      cache.countCachedComics(folder) - cache.countUncheckedComics(folder),
      1,
    );
  });

  test(
    'countPendingUncheckedComicsInFolders respects checks and cooldowns',
    () async {
      final data = _numericData(
        (page, [folder]) async => Res(<Comic>[
          _comic('one'),
          _comic('two'),
          _comic('three'),
        ], subData: 1),
      );
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);
      const otherFolder = NetworkFavoriteFolderRef(
        sourceKey: 'test-source',
        folderId: 'other',
        title: 'Other',
      );
      await cache.refreshPage(data, otherFolder, 1);

      // All three distinct comics are unchecked and not cooled.
      expect(
        cache.countPendingUncheckedComicsInFolders([folder, otherFolder]),
        3,
      );

      // A future cooldown on every row excludes the comic from the
      // pending count; cooling a single row does not while another copy
      // of the comic is still pending.
      cache.markComicRetryLater(folder, 'two');
      expect(
        cache.countPendingUncheckedComicsInFolders([folder, otherFolder]),
        3,
      );
      cache.markComicRetryLater(otherFolder, 'two');
      expect(
        cache.countPendingUncheckedComicsInFolders([folder, otherFolder]),
        2,
      );

      // An expired cooldown counts again.
      cache.markComicRetryLater(
        folder,
        'two',
        delay: const Duration(seconds: -1),
      );
      cache.markComicRetryLater(
        otherFolder,
        'two',
        delay: const Duration(seconds: -1),
      );
      expect(
        cache.countPendingUncheckedComicsInFolders([folder, otherFolder]),
        3,
      );

      // A successful check in every folder no longer counts as pending.
      cache.recordComicCheck(
        folder,
        'one',
        updateTime: '2026-8-3',
        updateMarker: 'time:2026-8-3|chapters:5',
      );
      cache.recordComicCheck(
        otherFolder,
        'one',
        updateTime: '2026-8-3',
        updateMarker: 'time:2026-8-3|chapters:5',
      );
      expect(
        cache.countPendingUncheckedComicsInFolders([folder, otherFolder]),
        2,
      );

      // Rows of the same comic across folders are counted once, so a
      // comic with every row cooled is no longer pending.
      cache.markComicRetryLater(folder, 'two');
      cache.markComicRetryLater(otherFolder, 'two');
      expect(
        cache.countPendingUncheckedComicsInFolders([folder, otherFolder]),
        1,
      );
      expect(cache.countUncheckedComicsInFolders([folder, otherFolder]), 2);
    },
  );

  test('aggregate folder queries dedupe and paginate', () async {
    const folderB = NetworkFavoriteFolderRef(
      sourceKey: 'test-source',
      folderId: 'remote-b',
      title: 'Remote B',
    );
    final dataA = _numericData(
      (page, [folder]) async => Res(<Comic>[
        _comic('one'),
        _comic('two'),
        _comic('three'),
      ], subData: 1),
    );
    final dataB = _numericData(
      (page, [folder]) async => Res(<Comic>[
        _comic('two'),
        _comic('three'),
        _comic('four'),
      ], subData: 1),
    );
    await cache.refreshFolders(dataA);
    await cache.refreshPage(dataA, folder, 1);
    await cache.refreshPage(dataB, folderB, 1);

    expect(cache.countCachedComicsInFolders([folder, folderB]), 4);
    expect(cache.countUncheckedComicsInFolders([folder, folderB]), 4);
    expect(cache.countComicsWithUpdatesInfoInFolders([folder, folderB]), 4);
    expect(
      cache
          .getComicsWithUpdatesInfoPageInFolders(
            [folder, folderB],
            limit: 2,
            offset: 0,
          )
          .length,
      2,
    );
    final page = cache.getComicsWithUpdatesInfoPageInFolders(
      [folder, folderB],
      limit: 2,
      offset: 2,
    );
    expect(page.length, 2);
    expect(page.map((c) => c.id).toSet().length, 2);

    cache.recordComicCheck(
      folder,
      'one',
      updateTime: '2026-8-3',
      updateMarker: 'time:2026-8-3|chapters:5',
    );
    expect(cache.countUncheckedComicsInFolders([folder, folderB]), 3);

    cache.recordComicCheck(
      folder,
      'one',
      updateTime: '2026-8-4',
      updateMarker: 'time:2026-8-4|chapters:6',
    );
    expect(cache.countUpdatesInFolders([folder, folderB]), 1);
    expect(cache.getUpdatedComicsInFolders([folder, folderB]).single.id, 'one');

    expect(cache.countCachedComicsInFolders(const []), 0);
    expect(
      cache.getComicsWithUpdatesInfoPageInFolders(
        const [],
        limit: 50,
        offset: 0,
      ),
      isEmpty,
    );
  });

  test('caching a page registers an unlisted folder for follow-up', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[
        _comic('one'),
        _comic('two'),
        _comic('three'),
      ], subData: 1),
    );
    // Single-folder sources cache pages directly without refreshFolders.
    await cache.refreshPage(data, folder, 1);

    expect(cache.countCachedComics(folder), 3);
    expect(
      cache.getAllCachedFolders().any(
        (f) => f.sourceKey == 'test-source' && f.folderId == 'remote',
      ),
      isTrue,
    );
    expect(
      cache.countPendingUncheckedComicsInFolders(cache.getAllCachedFolders()),
      3,
    );
  });

  test('single scan confirms suspect gone after a 404 retry', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[_comic('one')], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);

    var detailCalls = 0;
    final source = _detailSource((id) async {
      detailCalls++;
      return Res.error('404 Invalid status code: 404');
    });
    ComicSourceManager().add(source);
    addTearDown(() => ComicSourceManager().remove('test-source'));

    await updateFolder(
      folder,
      FollowUpdateMode.force,
      ignoreRetryAfter: true,
      cache: cache,
    ).toList();
    var item = cache.getComicsWithUpdatesInfo(folder).single;
    expect(detailCalls, 2);
    expect(item.isSuspectGone, isTrue);
    expect(item.checkNotFoundCount, 0);
    expect(item.lastCheckTime, isNotNull);

    await updateFolder(
      folder,
      FollowUpdateMode.force,
      ignoreRetryAfter: true,
      cache: cache,
    ).toList();
    item = cache.getComicsWithUpdatesInfo(folder).single;
    expect(detailCalls, 2);
    expect(item.isSuspectGone, isTrue);
  });

  test('in-scan 404 retry recovers and clears pending state', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[_comic('one')], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);

    var detailCalls = 0;
    final source = _detailSource((id) async {
      detailCalls++;
      if (detailCalls == 1) {
        return Res.error('404 Invalid status code: 404');
      }
      return Res(
        ComicDetails.fromJson({
          'title': 'Comic',
          'subtitle': 'Author',
          'cover': '',
          'tags': <String, List<String>>{},
          'chapters': <String, String>{'1': 'Chapter 1'},
          'sourceKey': 'test-source',
          'comicId': id,
        }),
      );
    });
    ComicSourceManager().add(source);
    addTearDown(() => ComicSourceManager().remove('test-source'));

    await updateFolder(
      folder,
      FollowUpdateMode.force,
      ignoreRetryAfter: true,
      cache: cache,
    ).toList();
    final item = cache.getComicsWithUpdatesInfo(folder).single;
    expect(detailCalls, 2);
    expect(item.isSuspectGone, isFalse);
    expect(item.checkNotFoundCount, 0);
    expect(item.checkFailures, 0);
    expect(item.lastCheckTime, isNotNull);
  });

  test('suspect gone comics are skipped by scans', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[_comic('one')], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);

    var detailCalls = 0;
    final source = _detailSource((id) async {
      detailCalls++;
      return Res.error('404 Invalid status code: 404');
    });
    ComicSourceManager().add(source);
    addTearDown(() => ComicSourceManager().remove('test-source'));

    await updateFolder(
      folder,
      FollowUpdateMode.force,
      ignoreRetryAfter: true,
      cache: cache,
    ).toList();
    await updateFolder(
      folder,
      FollowUpdateMode.force,
      ignoreRetryAfter: true,
      cache: cache,
    ).toList();
    expect(cache.getComicsWithUpdatesInfo(folder).single.isSuspectGone, isTrue);

    await updateFolder(
      folder,
      FollowUpdateMode.force,
      ignoreRetryAfter: true,
      cache: cache,
    ).toList();
    expect(detailCalls, 2);
  });

  test('successful check clears suspect state', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[_comic('one')], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);

    final source = _detailSource((id) async {
      return Res.error('404 Invalid status code: 404');
    });
    ComicSourceManager().add(source);
    addTearDown(() => ComicSourceManager().remove('test-source'));

    await updateFolder(
      folder,
      FollowUpdateMode.force,
      ignoreRetryAfter: true,
      cache: cache,
    ).toList();
    await updateFolder(
      folder,
      FollowUpdateMode.force,
      ignoreRetryAfter: true,
      cache: cache,
    ).toList();
    expect(cache.getComicsWithUpdatesInfo(folder).single.isSuspectGone, isTrue);

    cache.recordComicCheck(
      folder,
      'one',
      updateTime: '2026-8-3',
      updateMarker: 'time:2026-8-3|chapters:5',
    );
    final item = cache.getComicsWithUpdatesInfo(folder).single;
    expect(item.isSuspectGone, isFalse);
    expect(item.checkFailures, 0);
    expect(item.checkNotFoundCount, 0);
  });

  test(
    'clearComicSuspectGoneEverywhere clears and suspect query dedupes',
    () async {
      const folderB = NetworkFavoriteFolderRef(
        sourceKey: 'test-source',
        folderId: 'remote-b',
        title: 'Remote B',
      );
      final data = _numericData(
        (page, [folder]) async => Res(<Comic>[_comic('one')], subData: 1),
      );
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);
      await cache.refreshPage(data, folderB, 1);

      cache.markComicSuspectGone(folder, 'one');
      cache.markComicSuspectGone(folderB, 'one');

      expect(cache.isComicSuspectGone('test-source', 'one'), isTrue);
      expect(cache.getSuspectGoneComicsInFolders([folder, folderB]).length, 1);

      cache.clearComicSuspectGoneEverywhere('test-source', 'one');
      expect(cache.isComicSuspectGone('test-source', 'one'), isFalse);
      expect(cache.getSuspectGoneComicsInFolders([folder, folderB]), isEmpty);
    },
  );

  test('non-not-found failures escalate cooldown', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[_comic('one')], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);

    var detailCalls = 0;
    final source = _detailSource((id) async {
      detailCalls++;
      return Res.error('500 Internal Server Error');
    });
    ComicSourceManager().add(source);
    addTearDown(() => ComicSourceManager().remove('test-source'));

    await updateFolder(
      folder,
      FollowUpdateMode.force,
      ignoreRetryAfter: true,
      cache: cache,
    ).toList();
    var item = cache.getComicsWithUpdatesInfo(folder).single;
    expect(detailCalls, 3);
    expect(item.checkFailures, 1);
    expect(item.checkNotFoundCount, 0);
    expect(item.retryAfter, isNotNull);

    await updateFolder(
      folder,
      FollowUpdateMode.force,
      ignoreRetryAfter: true,
      cache: cache,
    ).toList();
    item = cache.getComicsWithUpdatesInfo(folder).single;
    expect(detailCalls, 6);
    expect(item.checkFailures, 2);
  });

  test('recordComicNotFoundEverywhere follows two-hit rule', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[_comic('one')], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);

    cache.recordComicNotFoundEverywhere('test-source', 'one');
    var item = cache.getComicsWithUpdatesInfo(folder).single;
    expect(item.checkNotFoundCount, 1);
    expect(item.isSuspectGone, isFalse);

    cache.recordComicNotFoundEverywhere('test-source', 'one');
    item = cache.getComicsWithUpdatesInfo(folder).single;
    expect(item.isSuspectGone, isTrue);
    expect(item.lastCheckTime, isNotNull);
  });

  test('update marker includes the date and chapter count', () {
    final info = ComicDetails.fromJson({
      'title': 'Comic',
      'subtitle': 'Author',
      'cover': '',
      'tags': <String, List<String>>{},
      'chapters': <String, String>{'1': 'Chapter 1', '2': 'Chapter 2'},
      'sourceKey': 'test-source',
      'comicId': 'one',
      'updateTime': '2026-08-03 10:00:00',
    });
    expect(comicUpdateMarker(info), 'time:2026-8-3|chapters:2');
  });

  test('only a legacy folder_sync relation migrates follow updates', () {
    final database = File('${tempDir.path}${Platform.pathSeparator}legacy.db');
    final db = sqlite3.open(database.path);
    db.execute('''
      CREATE TABLE folder_sync (
        folder_name TEXT PRIMARY KEY,
        source_key TEXT,
        source_folder TEXT
      );
    ''');
    db.execute('INSERT INTO folder_sync VALUES (?, ?, ?)', [
      'old-local-folder',
      'remote-source',
      'remote-folder',
    ]);
    db.dispose();

    expect(
      readLegacyFollowUpdatesFolder(database, 'old-local-folder'),
      const NetworkFavoriteFolderRef(
        sourceKey: 'remote-source',
        folderId: 'remote-folder',
      ),
    );
    expect(readLegacyFollowUpdatesFolder(database, 'unlinked'), isNull);
  });
}
