import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/tracking/normalizer.dart';

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
  late String databasePath;
  const folder = NetworkFavoriteFolderRef(
    sourceKey: 'test-source',
    folderId: 'remote',
    title: 'Remote',
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('venera-favorite-cache-');
    cache = NetworkFavoriteCacheManager.forTesting();
    databasePath = '${tempDir.path}${Platform.pathSeparator}cache.db';
    await cache.init(databasePath: databasePath, migrateLegacy: false);
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

    final beforeEpoch = cache.captureFavoriteSessionEpoch('test-source');
    final beforeGeneration = cache.cacheGeneration;
    cache.recordFavoriteUpdateScanAttempt(
      folder,
      attemptedAt: DateTime(2026, 8, 24),
    );
    cache.clearAllCache();

    expect(cache.captureFavoriteSessionEpoch('test-source'), beforeEpoch + 1);
    expect(cache.cacheGeneration, beforeGeneration + 1);
    expect(cache.getCachedFolders('test-source'), isEmpty);
    expect(cache.getCachedPage(folder, 1), isNull);
    expect(cache.countCachedComics(folder), 0);
    expect(cache.isFavoriteKnown('test-source', 'one'), isFalse);
    expect(cache.getFullCacheStatus(folder).isComplete, isFalse);
    expect(cache.getFavoriteUpdateScanState(folder), isNull);
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
    'summary refresh time budget stops the sweep without dropping progress',
    () async {
      final data = _numericData(
        (page, [folder]) async => Res(<Comic>[_comic('p$page')], subData: 3),
      );
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);
      await cache.refreshPage(data, folder, 2);
      await cache.refreshPage(data, folder, 3);

      var listCalls = 0;
      final counting = _numericData((page, [folder]) async {
        listCalls++;
        return Res(<Comic>[_comic('p$page')], subData: 3);
      });

      // An exhausted budget returns before any page request and without
      // error; already-committed pages stay untouched.
      await cache.refreshCachedSummaries(
        counting,
        minimumAge: Duration.zero,
        timeBudget: Duration.zero,
      );
      expect(listCalls, 0);

      // Without a budget the same sweep refreshes every stale page.
      await cache.refreshCachedSummaries(counting, minimumAge: Duration.zero);
      expect(listCalls, 3);
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

  test(
    'numbered full cache fetches the remaining pages concurrently',
    () async {
      final gate = Completer<void>();
      final allInFlight = Completer<void>();
      var calls = <int>[];
      final data = _numericData((page, [folder]) async {
        calls.add(page);
        if (page > 1) {
          if (calls.toSet().containsAll(<int>[2, 3, 4])) {
            allInFlight.complete();
          }
          await gate.future;
        }
        return Res(<Comic>[_comic('comic-$page')], subData: 4);
      });
      await cache.refreshFolders(data);

      final run = cache
          .cacheAllPages(data, folder, isCanceled: () => false)
          .toList();
      // Pages 2..4 must all be in flight before any of them is released;
      // a sequential implementation would deadlock this test.
      await allInFlight.future.timeout(const Duration(seconds: 5));
      gate.complete();
      final progress = await run;

      expect(progress.last.isComplete, isTrue);
      expect(progress.last.totalPages, 4);
      expect(cache.getFullCacheStatus(folder).pageCount, 4);
      expect(cache.getCachedPage(folder, 3)!.comics.single.id, 'comic-3');
    },
  );

  test('full cache without a page count walks to an empty page', () async {
    var calls = <int>[];
    final data = _numericData((page, [folder]) async {
      calls.add(page);
      if (page >= 3) return const Res(<Comic>[]);
      return Res(<Comic>[_comic('comic-$page')]);
    });
    await cache.refreshFolders(data);

    final progress = await cache
        .cacheAllPages(data, folder, isCanceled: () => false)
        .toList();

    expect(progress.last.isComplete, isTrue);
    expect(progress.last.totalPages, isNull);
    expect(cache.getCachedPage(folder, 1), isNotNull);
    expect(cache.getCachedPage(folder, 2), isNotNull);
    // The empty terminal page and anything fetched after it in the same
    // batch are dropped, not kept as a hole.
    expect(cache.getCachedPage(folder, 3), isNull);
    expect(cache.getCachedPage(folder, 4), isNull);
    final status = cache.getFullCacheStatus(folder);
    expect(status.isComplete, isTrue);
    expect(status.pageCount, 2);
    expect(status.comicCount, 2);
    // Pages 3 and 4 (same batch as the terminal page) were fetched too.
    expect(calls.toSet(), {1, 2, 3, 4});
  });

  test('full cache without a page count stops at a repeating tail', () async {
    var calls = <int>[];
    final data = _numericData((page, [folder]) async {
      calls.add(page);
      if (page >= 3) return Res(<Comic>[_comic('comic-2')]);
      return Res(<Comic>[_comic('comic-$page')]);
    });
    await cache.refreshFolders(data);

    final progress = await cache
        .cacheAllPages(data, folder, isCanceled: () => false)
        .toList();

    expect(progress.last.isComplete, isTrue);
    expect(cache.getFullCacheStatus(folder).pageCount, 2);
    // The pages after the clamp were fetched in the same batch; the walk
    // stops without requesting anything beyond it.
    expect(calls.toSet(), {1, 2, 3, 4});
    expect(calls.length, 4);
  });

  test('full cache without a page count fetches pages concurrently', () async {
    final gate = Completer<void>();
    final allInFlight = Completer<void>();
    var calls = <int>[];
    final data = _numericData((page, [folder]) async {
      calls.add(page);
      if (page > 1 && page < 5) {
        if (calls.toSet().containsAll(<int>[2, 3, 4])) {
          allInFlight.complete();
        }
        await gate.future;
      }
      if (page >= 5) return const Res(<Comic>[]);
      return Res(<Comic>[_comic('comic-$page')]);
    });
    await cache.refreshFolders(data);

    final run = cache
        .cacheAllPages(data, folder, isCanceled: () => false)
        .toList();
    // The unknown-total walk must still fetch pages 2..4 concurrently; a
    // sequential walk would deadlock this test.
    await allInFlight.future.timeout(const Duration(seconds: 5));
    gate.complete();
    final progress = await run;

    expect(progress.last.isComplete, isTrue);
    expect(cache.getFullCacheStatus(folder).pageCount, 4);
    expect(cache.getCachedPage(folder, 4)!.comics.single.id, 'comic-4');
    expect(cache.getCachedPage(folder, 5), isNull);
  });

  test('full cache without a page count hits the safety cap', () async {
    NetworkFavoriteCacheManager.fullCacheUnknownTotalCap = 3;
    addTearDown(
      () => NetworkFavoriteCacheManager.fullCacheUnknownTotalCap = 500,
    );
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[_comic('comic-$page')]),
    );
    await cache.refreshFolders(data);

    final progress = await cache
        .cacheAllPages(data, folder, isCanceled: () => false)
        .toList();

    expect(progress.last.errorMessage, contains('page count'));
    expect(cache.getFullCacheStatus(folder).isComplete, isFalse);
    // Pages fetched up to the cap are still committed.
    expect(cache.getCachedPage(folder, 3), isNotNull);
  });

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

    cache.markComicRetryLaterEverywhere('test-source', 'old-id');
    expect(cache.getComicsWithUpdatesInfo(folder).single.retryAfter, isNotNull);
  });

  test('favorite comic index is idempotent and serves point lookups', () async {
    final databasePath = '${tempDir.path}${Platform.pathSeparator}cache.db';

    // Reopen the same existing database to exercise the migration path rather
    // than only checking a fresh CREATE TABLE sequence.
    cache.close();
    cache = NetworkFavoriteCacheManager.forTesting();
    await cache.init(databasePath: databasePath, migrateLegacy: false);

    cache.close();
    cache = NetworkFavoriteCacheManager.forTesting();
    await cache.init(databasePath: databasePath, migrateLegacy: false);

    final database = sqlite3.open(databasePath);
    try {
      final indexNames = database
          .select("PRAGMA index_list('favorite_items')")
          .map((row) => row['name'] as String)
          .toSet();
      expect(indexNames, contains('idx_favorite_items_comic'));

      final plan = database.select(
        '''EXPLAIN QUERY PLAN
           SELECT * FROM favorite_items
           WHERE source_key = ? AND folder_id = ? AND comic_id = ?''',
        ['test-source', 'remote', 'one'],
      );
      expect(
        plan.map((row) => row['detail'].toString()).join('\n'),
        contains('idx_favorite_items_comic'),
      );
    } finally {
      database.dispose();
    }
  });

  test('manual hot window reuses its fixed deadline after closing', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[_comic('one')], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);
    final t0 = DateTime(2026, 8, 1, 12);
    cache.recordComicCheckEverywhere(
      'test-source',
      'one',
      completedAt: t0,
      updateTime: '2026-08-01',
      updateMarker: 'v2|time:2026-08-01|chapters:1',
    );

    var info = cache.toggleManualHotWindow(
      'test-source',
      'one',
      enabled: true,
      now: t0,
    )!;
    final deadline = info.manualHotUntil;
    expect(deadline, t0.add(const Duration(days: 14)));

    info = cache.toggleManualHotWindow(
      'test-source',
      'one',
      enabled: false,
      now: t0.add(const Duration(days: 2)),
    )!;
    expect(info.manualHotEnabled, isFalse);
    expect(info.manualHotUntil, deadline);
    expect(info.isHotActiveAt(t0.add(const Duration(days: 2))), isFalse);

    info = cache.toggleManualHotWindow(
      'test-source',
      'one',
      enabled: true,
      now: t0.add(const Duration(days: 3)),
    )!;
    expect(info.manualHotUntil, deadline);

    info = cache.toggleManualHotWindow(
      'test-source',
      'one',
      enabled: true,
      now: t0.add(const Duration(days: 15)),
    )!;
    expect(info.manualHotUntil, t0.add(const Duration(days: 29)));
  });

  test(
    'current schema baseline does not gain an automatic hot window after restart',
    () async {
      final data = _numericData(
        (page, [folder]) async => Res(<Comic>[_comic('restart')], subData: 1),
      );
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);

      final t0 = DateTime.now();
      final sourceActivityAt = t0.subtract(const Duration(days: 1));
      cache.recordComicCheckEverywhere(
        'test-source',
        'restart',
        completedAt: t0,
        sourceActivityAt: sourceActivityAt,
        updateMarker: 'v1|time:${sourceActivityAt.toIso8601String()}',
      );

      final first = cache.getComicUpdateInfo(
        'test-source',
        'restart',
        'remote',
      )!;
      expect(first.autoHotUntil, isNull);
      expect(first.nextCheckAt, isNotNull);
      final baselineMs = first.baselineAt!.millisecondsSinceEpoch;
      final sourceMs = first.sourceActivityAt!.millisecondsSinceEpoch;
      final nextCheckMs = first.nextCheckAt!.millisecondsSinceEpoch;
      final jitterApplied = first.oldScheduleJitterApplied;
      final manualEnabled = first.manualHotEnabled;

      cache.close();
      final metadataDb = sqlite3.open(databasePath);
      try {
        expect(
          metadataDb.select('SELECT value FROM metadata WHERE key = ?', [
            'follow_schedule_state_backfill_v1',
          ]).single['value'],
          'done',
        );
      } finally {
        metadataDb.dispose();
      }
      cache = NetworkFavoriteCacheManager.forTesting();
      await cache.init(databasePath: databasePath, migrateLegacy: false);
      final second = cache.getComicUpdateInfo(
        'test-source',
        'restart',
        'remote',
      )!;
      expect(second.autoHotUntil, isNull);
      expect(second.baselineAt!.millisecondsSinceEpoch, baselineMs);
      expect(second.sourceActivityAt!.millisecondsSinceEpoch, sourceMs);
      expect(second.nextCheckAt!.millisecondsSinceEpoch, nextCheckMs);
      expect(second.oldScheduleJitterApplied, jitterApplied);
      expect(second.manualHotEnabled, manualEnabled);

      cache.close();
      cache = NetworkFavoriteCacheManager.forTesting();
      await cache.init(databasePath: databasePath, migrateLegacy: false);
      final third = cache.getComicUpdateInfo(
        'test-source',
        'restart',
        'remote',
      )!;
      expect(third.autoHotUntil, isNull);
      expect(third.baselineAt!.millisecondsSinceEpoch, baselineMs);
      expect(third.sourceActivityAt!.millisecondsSinceEpoch, sourceMs);
      expect(third.nextCheckAt!.millisecondsSinceEpoch, nextCheckMs);
      expect(third.oldScheduleJitterApplied, jitterApplied);
      expect(third.manualHotEnabled, manualEnabled);
    },
  );

  test('complete schema without a marker only records done', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[_comic('no-marker')], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);

    final completedAt = DateTime.now();
    final activity = completedAt.subtract(const Duration(days: 2));
    cache.recordComicCheckEverywhere(
      'test-source',
      'no-marker',
      completedAt: completedAt,
      sourceActivityAt: activity,
      updateMarker: 'v1|time:${activity.toIso8601String()}',
    );
    final before = cache.getComicUpdateInfo(
      'test-source',
      'no-marker',
      'remote',
    )!;
    final beforeBaselineMs = before.baselineAt!.millisecondsSinceEpoch;
    final beforeSourceMs = before.sourceActivityAt!.millisecondsSinceEpoch;
    final beforeNextMs = before.nextCheckAt!.millisecondsSinceEpoch;

    cache.close();
    final database = sqlite3.open(databasePath);
    database.execute('DELETE FROM metadata WHERE key = ?', [
      'follow_schedule_state_backfill_v1',
    ]);
    expect(
      database.select('SELECT 1 FROM metadata WHERE key = ?', [
        'follow_schedule_state_backfill_v1',
      ]),
      isEmpty,
    );
    database.dispose();

    cache = NetworkFavoriteCacheManager.forTesting();
    await cache.init(databasePath: databasePath, migrateLegacy: false);
    final after = cache.getComicUpdateInfo(
      'test-source',
      'no-marker',
      'remote',
    )!;
    expect(after.autoHotUntil, isNull);
    expect(after.baselineAt!.millisecondsSinceEpoch, beforeBaselineMs);
    expect(after.sourceActivityAt!.millisecondsSinceEpoch, beforeSourceMs);
    expect(after.nextCheckAt!.millisecondsSinceEpoch, beforeNextMs);
    expect(after.oldScheduleJitterApplied, isFalse);

    cache.close();
    final markerDb = sqlite3.open(databasePath);
    try {
      expect(
        markerDb.select('SELECT value FROM metadata WHERE key = ?', [
          'follow_schedule_state_backfill_v1',
        ]).single['value'],
        'done',
      );
    } finally {
      markerDb.dispose();
    }
    cache = NetworkFavoriteCacheManager.forTesting();
    await cache.init(databasePath: databasePath, migrateLegacy: false);
    final afterSecondInit = cache.getComicUpdateInfo(
      'test-source',
      'no-marker',
      'remote',
    )!;
    expect(afterSecondInit.autoHotUntil, isNull);
    expect(afterSecondInit.nextCheckAt!.millisecondsSinceEpoch, beforeNextMs);
  });

  test(
    'pending schedule backfill resumes and becomes done after completion',
    () async {
      final data = _numericData(
        (page, [folder]) async =>
            Res(<Comic>[_comic('pending-recovery')], subData: 1),
      );
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);

      cache.close();
      final migrationNow = DateTime.now();
      final activity = migrationNow.subtract(const Duration(days: 2));
      final lastCheck = migrationNow.subtract(const Duration(hours: 23));
      final database = sqlite3.open(databasePath);
      database.execute(
        '''INSERT OR REPLACE INTO comic_check_state
           (source_key, comic_id, last_update_time, update_marker,
            last_check_time, has_new_update)
           VALUES (?, ?, ?, ?, ?, 0)''',
        [
          'test-source',
          'pending-recovery',
          activity.toIso8601String(),
          'v1|time:${activity.toIso8601String()}',
          lastCheck.millisecondsSinceEpoch,
        ],
      );
      database.execute(
        '''INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)''',
        ['follow_schedule_state_backfill_v1', 'pending'],
      );
      database.dispose();

      cache = NetworkFavoriteCacheManager.forTesting();
      await cache.init(databasePath: databasePath, migrateLegacy: false);
      final recovered = cache.getComicUpdateInfo(
        'test-source',
        'pending-recovery',
        'remote',
      )!;
      expect(
        recovered.baselineAt!.millisecondsSinceEpoch,
        lastCheck.millisecondsSinceEpoch,
      );
      expect(
        recovered.sourceActivityAt!.millisecondsSinceEpoch,
        activity.millisecondsSinceEpoch,
      );
      expect(
        recovered.nextCheckAt!.millisecondsSinceEpoch,
        lastCheck.add(const Duration(hours: 24)).millisecondsSinceEpoch,
      );
      expect(
        recovered.autoHotUntil!.millisecondsSinceEpoch,
        activity.add(kFollowUpdateHotWindow).millisecondsSinceEpoch,
      );
      expect(recovered.oldScheduleJitterApplied, isFalse);

      final firstValues = (
        baseline: recovered.baselineAt!.millisecondsSinceEpoch,
        source: recovered.sourceActivityAt!.millisecondsSinceEpoch,
        next: recovered.nextCheckAt!.millisecondsSinceEpoch,
        auto: recovered.autoHotUntil!.millisecondsSinceEpoch,
      );
      cache.close();
      final markerDb = sqlite3.open(databasePath);
      try {
        expect(
          markerDb.select('SELECT value FROM metadata WHERE key = ?', [
            'follow_schedule_state_backfill_v1',
          ]).single['value'],
          'done',
        );
      } finally {
        markerDb.dispose();
      }

      cache = NetworkFavoriteCacheManager.forTesting();
      await cache.init(databasePath: databasePath, migrateLegacy: false);
      final resumed = cache.getComicUpdateInfo(
        'test-source',
        'pending-recovery',
        'remote',
      )!;
      expect(resumed.baselineAt!.millisecondsSinceEpoch, firstValues.baseline);
      expect(
        resumed.sourceActivityAt!.millisecondsSinceEpoch,
        firstValues.source,
      );
      expect(resumed.nextCheckAt!.millisecondsSinceEpoch, firstValues.next);
      expect(resumed.autoHotUntil!.millisecondsSinceEpoch, firstValues.auto);
      expect(resumed.oldScheduleJitterApplied, isFalse);
    },
  );

  test('done current runtime gaps are not inferred as legacy state', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[_comic('runtime-gap')], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);

    cache.close();
    final lastCheck = DateTime.now().subtract(const Duration(days: 1));
    final database = sqlite3.open(databasePath);
    database.execute(
      '''INSERT OR REPLACE INTO comic_check_state
           (source_key, comic_id, last_update_time, update_marker,
            last_check_time, has_new_update)
           VALUES (?, ?, ?, ?, ?, 0)''',
      [
        'test-source',
        'runtime-gap',
        '2026-08-01',
        'v1|time:2026-08-01',
        lastCheck.millisecondsSinceEpoch,
      ],
    );
    database.execute(
      '''INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)''',
      ['follow_schedule_state_backfill_v1', 'done'],
    );
    database.dispose();

    cache = NetworkFavoriteCacheManager.forTesting();
    await cache.init(databasePath: databasePath, migrateLegacy: false);
    final info = cache.getComicUpdateInfo(
      'test-source',
      'runtime-gap',
      'remote',
    )!;
    expect(info.lastCheckTime, isNotNull);
    expect(info.baselineAt, isNull);
    expect(info.sourceActivityAt, isNull);
    expect(info.nextCheckAt, isNull);
    expect(info.autoHotUntil, isNull);
    expect(info.oldScheduleJitterApplied, isFalse);
  });

  test(
    'first manual hot toggle creates a missing-baseline state row',
    () async {
      final data = _numericData(
        (page, [folder]) async =>
            Res(<Comic>[_comic('never-checked')], subData: 1),
      );
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);
      final t0 = DateTime(2026, 8, 1, 12);

      final enabled = cache.toggleManualHotWindow(
        'test-source',
        'never-checked',
        enabled: true,
        now: t0,
      );
      expect(enabled, isNotNull);
      expect(enabled!.manualHotEnabled, isTrue);
      expect(enabled.manualHotUntil, t0.add(const Duration(days: 14)));
      expect(enabled.baselineAt, isNull);
      expect(enabled.sourceActivityAt, isNull);
      expect(enabled.nextCheckAt, isNull);
      expect(
        cache
            .getScanCandidates(
              [folder],
              modeName: 'missing',
              ignoreRetryAfter: true,
              includeSuspect: false,
              now: t0,
            )
            .map((candidate) => candidate.comicId),
        contains('never-checked'),
      );

      final deadline = enabled.manualHotUntil;
      final disabled = cache.toggleManualHotWindow(
        'test-source',
        'never-checked',
        enabled: false,
        now: t0.add(const Duration(days: 2)),
      )!;
      expect(disabled.manualHotUntil, deadline);
      final reopened = cache.toggleManualHotWindow(
        'test-source',
        'never-checked',
        enabled: true,
        now: t0.add(const Duration(days: 3)),
      )!;
      expect(reopened.manualHotUntil, deadline);
    },
  );

  test(
    'closing manual hot window does not remove automatic hot window',
    () async {
      final data = _numericData(
        (page, [folder]) async => Res(<Comic>[_comic('one')], subData: 1),
      );
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);
      final t0 = DateTime(2026, 8, 1, 12);
      cache.recordComicCheckEverywhere(
        'test-source',
        'one',
        completedAt: t0,
        updateTime: '2026-08-01',
        updateMarker: 'v2|time:2026-08-01|chapters:1',
      );
      final updateAt = t0.add(const Duration(days: 1));
      cache.recordComicCheckEverywhere(
        'test-source',
        'one',
        completedAt: updateAt,
        updateTime: '2026-08-02',
        updateMarker: 'v2|time:2026-08-02|chapters:2',
      );
      var info = cache.toggleManualHotWindow(
        'test-source',
        'one',
        enabled: true,
        now: updateAt,
      )!;
      expect(info.isAutoHotActiveAt(updateAt), isTrue);
      info = cache.toggleManualHotWindow(
        'test-source',
        'one',
        enabled: false,
        now: updateAt.add(const Duration(hours: 1)),
      )!;
      expect(info.manualHotEnabled, isFalse);
      expect(
        info.isAutoHotActiveAt(updateAt.add(const Duration(hours: 1))),
        isTrue,
      );
      expect(
        info.isHotActiveAt(updateAt.add(const Duration(hours: 1))),
        isTrue,
      );
    },
  );

  test(
    'old database without comic_check_state backfills copied favorite state',
    () async {
      final oldPath =
          '${tempDir.path}${Platform.pathSeparator}missing-check-state.db';
      final oldDb = sqlite3.open(oldPath);
      oldDb.execute('''
        CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE favorite_folders (
          source_key TEXT NOT NULL, folder_id TEXT NOT NULL, title TEXT NOT NULL,
          updated_at INTEGER NOT NULL, PRIMARY KEY (source_key, folder_id)
        );
        CREATE TABLE favorite_pages (
          source_key TEXT NOT NULL, folder_id TEXT NOT NULL,
          page_index INTEGER NOT NULL, request_token TEXT NOT NULL,
          next_token TEXT, max_page INTEGER, updated_at INTEGER NOT NULL,
          PRIMARY KEY (source_key, folder_id, request_token)
        );
        CREATE TABLE favorite_items (
          source_key TEXT NOT NULL, folder_id TEXT NOT NULL,
          page_index INTEGER NOT NULL, comic_id TEXT NOT NULL,
          display_order INTEGER NOT NULL, comic_json TEXT NOT NULL,
          favorite_id TEXT, favorite_time TEXT NOT NULL,
          search_text TEXT NOT NULL DEFAULT '', last_update_time TEXT,
          last_check_time INTEGER, has_new_update INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (source_key, folder_id, page_index, comic_id)
        );
        CREATE TABLE favorite_membership (
          source_key TEXT NOT NULL, folder_id TEXT NOT NULL, comic_id TEXT NOT NULL,
          PRIMARY KEY (source_key, folder_id, comic_id)
        );
        CREATE TABLE scan_queue (
          run_id INTEGER NOT NULL, source_key TEXT NOT NULL,
          comic_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
          result TEXT, error TEXT,
          PRIMARY KEY (run_id, source_key, comic_id)
        );
      ''');
      final migrationNow = DateTime.now();
      final activity = migrationNow.subtract(const Duration(days: 2));
      final lastCheck = migrationNow.subtract(const Duration(hours: 23));
      oldDb.execute(
        '''INSERT INTO favorite_folders
           (source_key, folder_id, title, updated_at)
           VALUES (?, ?, ?, ?)''',
        [
          'test-source',
          'remote',
          'Remote',
          migrationNow.millisecondsSinceEpoch,
        ],
      );
      oldDb.execute(
        '''INSERT INTO favorite_items
           (source_key, folder_id, page_index, comic_id, display_order,
            comic_json, favorite_time, last_update_time, last_check_time,
            has_new_update)
           VALUES (?, ?, 1, ?, 0, ?, ?, ?, ?, 0)''',
        [
          'test-source',
          'remote',
          'missing-state',
          jsonEncode(_comic('missing-state').toJson()),
          '2026-08-01 00:00:00',
          activity.toIso8601String(),
          lastCheck.millisecondsSinceEpoch,
        ],
      );
      oldDb.execute('INSERT INTO favorite_membership VALUES (?, ?, ?)', [
        'test-source',
        'remote',
        'missing-state',
      ]);
      expect(
        oldDb.select(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'comic_check_state'",
        ),
        isEmpty,
      );
      oldDb.dispose();

      var migrated = NetworkFavoriteCacheManager.forTesting();
      await migrated.init(databasePath: oldPath, migrateLegacy: false);
      final first = migrated.getComicUpdateInfo(
        'test-source',
        'missing-state',
        'remote',
      )!;
      expect(
        first.baselineAt!.millisecondsSinceEpoch,
        lastCheck.millisecondsSinceEpoch,
      );
      expect(
        first.sourceActivityAt!.millisecondsSinceEpoch,
        activity.millisecondsSinceEpoch,
      );
      expect(
        first.nextCheckAt!.millisecondsSinceEpoch,
        lastCheck.add(const Duration(hours: 24)).millisecondsSinceEpoch,
      );
      expect(
        first.autoHotUntil!.millisecondsSinceEpoch,
        activity.add(kFollowUpdateHotWindow).millisecondsSinceEpoch,
      );
      expect(first.hasNewUpdate, isFalse);
      final firstValues = (
        baseline: first.baselineAt!.millisecondsSinceEpoch,
        source: first.sourceActivityAt!.millisecondsSinceEpoch,
        next: first.nextCheckAt!.millisecondsSinceEpoch,
        auto: first.autoHotUntil!.millisecondsSinceEpoch,
        hasNewUpdate: first.hasNewUpdate,
      );
      migrated.close();

      final metadataDb = sqlite3.open(oldPath);
      try {
        expect(
          metadataDb.select('SELECT value FROM metadata WHERE key = ?', [
            'follow_schedule_state_backfill_v1',
          ]).single['value'],
          'done',
        );
      } finally {
        metadataDb.dispose();
      }

      migrated = NetworkFavoriteCacheManager.forTesting();
      await migrated.init(databasePath: oldPath, migrateLegacy: false);
      final second = migrated.getComicUpdateInfo(
        'test-source',
        'missing-state',
        'remote',
      )!;
      expect(second.baselineAt!.millisecondsSinceEpoch, firstValues.baseline);
      expect(
        second.sourceActivityAt!.millisecondsSinceEpoch,
        firstValues.source,
      );
      expect(second.nextCheckAt!.millisecondsSinceEpoch, firstValues.next);
      expect(second.autoHotUntil!.millisecondsSinceEpoch, firstValues.auto);
      expect(second.hasNewUpdate, firstValues.hasNewUpdate);
      migrated.close();
    },
  );

  test('schedule migration is idempotent for old state tables', () async {
    final oldPath =
        '${tempDir.path}${Platform.pathSeparator}old-schedule-cache.db';
    final oldDb = sqlite3.open(oldPath);
    oldDb.execute('''
      CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE favorite_folders (
        source_key TEXT NOT NULL, folder_id TEXT NOT NULL, title TEXT NOT NULL,
        updated_at INTEGER NOT NULL, PRIMARY KEY (source_key, folder_id)
      );
      CREATE TABLE favorite_pages (
        source_key TEXT NOT NULL, folder_id TEXT NOT NULL,
        page_index INTEGER NOT NULL, request_token TEXT NOT NULL,
        next_token TEXT, max_page INTEGER, updated_at INTEGER NOT NULL,
        PRIMARY KEY (source_key, folder_id, request_token)
      );
      CREATE TABLE favorite_items (
        source_key TEXT NOT NULL, folder_id TEXT NOT NULL,
        page_index INTEGER NOT NULL, comic_id TEXT NOT NULL,
        display_order INTEGER NOT NULL, comic_json TEXT NOT NULL,
        favorite_id TEXT, favorite_time TEXT NOT NULL,
        search_text TEXT NOT NULL DEFAULT '', last_update_time TEXT,
        last_check_time INTEGER, has_new_update INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (source_key, folder_id, page_index, comic_id)
      );
      CREATE TABLE favorite_membership (
        source_key TEXT NOT NULL, folder_id TEXT NOT NULL, comic_id TEXT NOT NULL,
        PRIMARY KEY (source_key, folder_id, comic_id)
      );
      CREATE TABLE scan_queue (
        run_id INTEGER NOT NULL, source_key TEXT NOT NULL,
        comic_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
        result TEXT, error TEXT,
        PRIMARY KEY (run_id, source_key, comic_id)
      );
      CREATE TABLE comic_check_state (
        source_key TEXT NOT NULL, comic_id TEXT NOT NULL,
        last_update_time TEXT, update_marker TEXT, last_check_time INTEGER,
        has_new_update INTEGER NOT NULL DEFAULT 0, retry_after INTEGER,
        check_failures INTEGER NOT NULL DEFAULT 0,
        check_not_found_count INTEGER NOT NULL DEFAULT 0,
        check_suspect_gone INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (source_key, comic_id)
      );
    ''');
    final migrationNow = DateTime.now();
    final checkedAt = migrationNow.subtract(const Duration(days: 1));
    oldDb.execute(
      '''INSERT INTO favorite_items
         (source_key, folder_id, page_index, comic_id, display_order,
          comic_json, favorite_time, last_update_time, last_check_time)
         VALUES (?, ?, 1, ?, 0, ?, ?, ?, ?)''',
      [
        'test-source',
        'remote',
        'one',
        jsonEncode(_comic('one').toJson()),
        '2026-08-01 00:00:00',
        '2022-01-01',
        checkedAt.millisecondsSinceEpoch,
      ],
    );
    oldDb.execute('INSERT INTO favorite_membership VALUES (?, ?, ?)', [
      'test-source',
      'remote',
      'one',
    ]);
    oldDb.execute(
      '''INSERT INTO comic_check_state
         (source_key, comic_id, last_update_time, update_marker, last_check_time)
         VALUES (?, ?, ?, ?, ?)''',
      [
        'test-source',
        'one',
        '2022-01-01',
        'v1|time:2022-01-01',
        checkedAt.millisecondsSinceEpoch,
      ],
    );
    final fixtures = <({String id, Duration age})>[
      (id: 'just-over-day', age: const Duration(hours: 25)),
      (id: 'recent', age: const Duration(hours: 23)),
      (id: 'three-years', age: const Duration(days: 3 * 365)),
      (id: 'five-years', age: const Duration(days: 5 * 365)),
    ];
    for (final fixture in fixtures) {
      final activity = migrationNow.subtract(fixture.age);
      oldDb.execute(
        '''INSERT INTO favorite_items
           (source_key, folder_id, page_index, comic_id, display_order,
            comic_json, favorite_time, last_update_time, last_check_time)
           VALUES (?, ?, 1, ?, 0, ?, ?, ?, ?)''',
        [
          'test-source',
          'remote',
          fixture.id,
          jsonEncode(_comic(fixture.id).toJson()),
          '2026-08-01 00:00:00',
          activity.toIso8601String(),
          activity.millisecondsSinceEpoch,
        ],
      );
      oldDb.execute('INSERT INTO favorite_membership VALUES (?, ?, ?)', [
        'test-source',
        'remote',
        fixture.id,
      ]);
      oldDb.execute(
        '''INSERT INTO comic_check_state
           (source_key, comic_id, last_update_time, update_marker, last_check_time)
           VALUES (?, ?, ?, ?, ?)''',
        [
          'test-source',
          fixture.id,
          activity.toIso8601String(),
          'v1|time:${activity.toIso8601String()}',
          activity.millisecondsSinceEpoch,
        ],
      );
    }
    final pendingJitterActivity = migrationNow.subtract(
      const Duration(days: 3 * 365),
    );
    final pendingJitterCheck = migrationNow.subtract(const Duration(hours: 23));
    oldDb.execute(
      '''INSERT INTO favorite_items
         (source_key, folder_id, page_index, comic_id, display_order,
          comic_json, favorite_time, last_update_time, last_check_time)
         VALUES (?, ?, 1, ?, 0, ?, ?, ?, ?)''',
      [
        'test-source',
        'remote',
        'pending-jitter',
        jsonEncode(_comic('pending-jitter').toJson()),
        '2026-08-01 00:00:00',
        pendingJitterActivity.toIso8601String(),
        pendingJitterCheck.millisecondsSinceEpoch,
      ],
    );
    oldDb.execute('INSERT INTO favorite_membership VALUES (?, ?, ?)', [
      'test-source',
      'remote',
      'pending-jitter',
    ]);
    oldDb.execute(
      '''INSERT INTO comic_check_state
         (source_key, comic_id, last_update_time, update_marker, last_check_time)
         VALUES (?, ?, ?, ?, ?)''',
      [
        'test-source',
        'pending-jitter',
        pendingJitterActivity.toIso8601String(),
        'v1|time:${pendingJitterActivity.toIso8601String()}',
        pendingJitterCheck.millisecondsSinceEpoch,
      ],
    );
    oldDb.dispose();

    var migrated = NetworkFavoriteCacheManager.forTesting();
    await migrated.init(databasePath: oldPath, migrateLegacy: false);
    final first = migrated.getComicUpdateInfo('test-source', 'one', 'remote')!;
    expect(
      first.baselineAt,
      DateTime.fromMillisecondsSinceEpoch(checkedAt.millisecondsSinceEpoch),
    );
    expect(first.hasNewUpdate, isFalse);
    expect(first.sourceActivityAt, DateTime(2022, 1, 1));
    expect(first.nextCheckAt, isNull);
    expect(first.oldScheduleJitterApplied, isFalse);
    expect(
      migrated
          .getScanCandidates(
            [
              const NetworkFavoriteFolderRef(
                sourceKey: 'test-source',
                folderId: 'remote',
              ),
            ],
            modeName: 'regular',
            ignoreRetryAfter: true,
            includeSuspect: false,
            now: migrationNow,
          )
          .map((candidate) => candidate.comicId),
      containsAll(<String>[
        'one',
        'just-over-day',
        'three-years',
        'five-years',
      ]),
    );
    expect(
      migrated
          .getComicUpdateInfo('test-source', 'recent', 'remote')!
          .nextCheckAt,
      DateTime.fromMillisecondsSinceEpoch(
        migrationNow.add(const Duration(hours: 1)).millisecondsSinceEpoch,
      ),
    );

    final pendingAfterFirst = migrated.getComicUpdateInfo(
      'test-source',
      'pending-jitter',
      'remote',
    )!;
    final pendingLegacyDue = DateTime.fromMillisecondsSinceEpoch(
      pendingJitterCheck.add(const Duration(hours: 24)).millisecondsSinceEpoch,
    );
    expect(pendingAfterFirst.nextCheckAt, pendingLegacyDue);
    expect(pendingAfterFirst.oldScheduleJitterApplied, isFalse);
    migrated.close();

    migrated = NetworkFavoriteCacheManager.forTesting();
    await migrated.init(databasePath: oldPath, migrateLegacy: false);
    final pendingAfterSecond = migrated.getComicUpdateInfo(
      'test-source',
      'pending-jitter',
      'remote',
    )!;
    expect(pendingAfterSecond.nextCheckAt, pendingLegacyDue);
    expect(pendingAfterSecond.oldScheduleJitterApplied, isFalse);

    final successAt = migrationNow.add(const Duration(days: 1));
    migrated.recordComicCheckEverywhere(
      'test-source',
      'pending-jitter',
      completedAt: successAt,
      sourceActivityAt: pendingJitterActivity,
      updateMarker: 'v1|time:${pendingJitterActivity.toIso8601String()}',
    );
    final pendingExpected = computeNextSchedule(
      completedAt: successAt,
      effectiveActivityAt: pendingJitterActivity,
      manualHotEnabled: false,
      oldScheduleJitterApplied: false,
      sourceKey: 'test-source',
      comicId: 'pending-jitter',
    );
    var pendingAfterSuccess = migrated.getComicUpdateInfo(
      'test-source',
      'pending-jitter',
      'remote',
    )!;
    expect(
      pendingAfterSuccess.nextCheckAt!.millisecondsSinceEpoch,
      pendingExpected.nextCheckAt.millisecondsSinceEpoch,
    );
    expect(pendingAfterSuccess.oldScheduleJitterApplied, isTrue);
    final pendingSecondSuccessAt = successAt.add(const Duration(days: 1));
    migrated.recordComicCheckEverywhere(
      'test-source',
      'pending-jitter',
      completedAt: pendingSecondSuccessAt,
      sourceActivityAt: pendingJitterActivity,
      updateMarker: 'v1|time:${pendingJitterActivity.toIso8601String()}',
    );
    pendingAfterSuccess = migrated.getComicUpdateInfo(
      'test-source',
      'pending-jitter',
      'remote',
    )!;
    expect(
      pendingAfterSuccess.nextCheckAt!.millisecondsSinceEpoch,
      pendingSecondSuccessAt
          .add(const Duration(days: 7))
          .millisecondsSinceEpoch,
    );

    for (final fixture in fixtures.where(
      (fixture) => fixture.id == 'three-years' || fixture.id == 'five-years',
    )) {
      final activity = migrationNow.subtract(fixture.age);
      migrated.recordComicCheckEverywhere(
        'test-source',
        fixture.id,
        completedAt: successAt,
        sourceActivityAt: activity,
        updateMarker: 'v1|time:${activity.toIso8601String()}',
      );
      final expected = computeNextSchedule(
        completedAt: successAt,
        effectiveActivityAt: activity,
        manualHotEnabled: false,
        oldScheduleJitterApplied: false,
        sourceKey: 'test-source',
        comicId: fixture.id,
      );
      final afterSuccess = migrated.getComicUpdateInfo(
        'test-source',
        fixture.id,
        'remote',
      )!;
      expect(
        afterSuccess.nextCheckAt!.millisecondsSinceEpoch,
        expected.nextCheckAt.millisecondsSinceEpoch,
      );
      expect(afterSuccess.oldScheduleJitterApplied, isTrue);

      final secondSuccessAt = successAt.add(const Duration(days: 1));
      migrated.recordComicCheckEverywhere(
        'test-source',
        fixture.id,
        completedAt: secondSuccessAt,
        sourceActivityAt: activity,
        updateMarker: 'v1|time:${activity.toIso8601String()}',
      );
      final withoutSecondJitter = computeNextSchedule(
        completedAt: secondSuccessAt,
        effectiveActivityAt: activity,
        manualHotEnabled: false,
        oldScheduleJitterApplied: true,
        sourceKey: 'test-source',
        comicId: fixture.id,
      );
      expect(
        migrated
            .getComicUpdateInfo('test-source', fixture.id, 'remote')!
            .nextCheckAt!
            .millisecondsSinceEpoch,
        withoutSecondJitter.nextCheckAt.millisecondsSinceEpoch,
      );
    }
    final firstNext = first.nextCheckAt;
    final firstJitter = first.oldScheduleJitterApplied;
    migrated.close();

    migrated = NetworkFavoriteCacheManager.forTesting();
    await migrated.init(databasePath: oldPath, migrateLegacy: false);
    final second = migrated.getComicUpdateInfo('test-source', 'one', 'remote')!;
    expect(second.nextCheckAt, firstNext);
    expect(second.oldScheduleJitterApplied, firstJitter);
    migrated.close();

    final metadataDb = sqlite3.open(oldPath);
    try {
      expect(
        metadataDb.select('SELECT value FROM metadata WHERE key = ?', [
          'follow_schedule_state_backfill_v1',
        ]).single['value'],
        'done',
      );
    } finally {
      metadataDb.dispose();
    }
  });

  test('automatic hot window follows only real same-version updates', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[_comic('one')], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);
    final t0 = DateTime(2026, 8, 1, 12);
    cache.recordComicCheckEverywhere(
      'test-source',
      'one',
      completedAt: t0,
      updateTime: '2026-08-01',
      updateMarker: 'v2|time:2026-08-01|chapters:1',
    );
    expect(cache.getComicsWithUpdatesInfo(folder).single.autoHotUntil, isNull);

    final unchangedAt = t0.add(const Duration(days: 1));
    cache.recordComicCheckEverywhere(
      'test-source',
      'one',
      completedAt: unchangedAt,
      updateTime: '2026-08-01',
      updateMarker: 'v2|time:2026-08-01|chapters:1',
    );
    expect(cache.getComicsWithUpdatesInfo(folder).single.autoHotUntil, isNull);

    final changedAt = t0.add(const Duration(days: 2));
    cache.recordComicCheckEverywhere(
      'test-source',
      'one',
      completedAt: changedAt,
      updateTime: '2026-08-02',
      updateMarker: 'v2|time:2026-08-02|chapters:2',
    );
    final hotUntil = cache.getComicsWithUpdatesInfo(folder).single.autoHotUntil;
    expect(hotUntil, changedAt.add(const Duration(days: 14)));

    cache.recordComicCheckEverywhere(
      'test-source',
      'one',
      completedAt: changedAt.add(const Duration(days: 1)),
      updateTime: '2026-08-02',
      updateMarker: 'v2|time:2026-08-02|chapters:2',
    );
    expect(
      cache.getComicsWithUpdatesInfo(folder).single.autoHotUntil,
      hotUntil,
    );
  });

  test(
    'old schedule jitter resets when activity returns within two years',
    () async {
      final data = _numericData(
        (page, [folder]) async =>
            Res(<Comic>[_comic('jitter-reset')], subData: 1),
      );
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);
      final completed = DateTime(2026, 8, 1, 12);
      cache.recordComicCheckEverywhere(
        'test-source',
        'jitter-reset',
        completedAt: completed,
        sourceActivityAt: completed.subtract(const Duration(days: 800)),
        updateMarker: 'v1|old',
      );
      expect(
        cache.getComicsWithUpdatesInfo(folder).single.oldScheduleJitterApplied,
        isTrue,
      );

      cache.recordComicCheckEverywhere(
        'test-source',
        'jitter-reset',
        completedAt: completed.add(const Duration(days: 1)),
        sourceActivityAt: completed.subtract(const Duration(days: 700)),
        updateMarker: 'v1|old',
      );
      expect(
        cache.getComicsWithUpdatesInfo(folder).single.oldScheduleJitterApplied,
        isFalse,
      );
    },
  );

  test(
    'clearing baselines preserves the active manual hot preference',
    () async {
      final data = _numericData(
        (page, [folder]) async => Res(<Comic>[_comic('one')], subData: 1),
      );
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);
      final t0 = DateTime(2026, 8, 1, 12);
      cache.recordComicCheckEverywhere(
        'test-source',
        'one',
        completedAt: t0,
        updateTime: '2026-08-01',
        updateMarker: 'v2|time:2026-08-01|chapters:1',
      );
      final enabled = cache.toggleManualHotWindow(
        'test-source',
        'one',
        enabled: true,
        now: t0,
      )!;
      cache.clearAllBaselines(now: t0.add(const Duration(days: 1)));
      final cleared = cache.getComicsWithUpdatesInfo(folder).single;
      expect(cleared.baselineAt, isNull);
      expect(cleared.sourceActivityAt, isNull);
      expect(cleared.nextCheckAt, isNull);
      expect(cleared.autoHotUntil, isNull);
      expect(cleared.manualHotEnabled, isTrue);
      expect(cleared.manualHotUntil, enabled.manualHotUntil);
    },
  );

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
      cache.recordComicCheckEverywhere(
        'test-source',
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
      cache.recordComicCheckEverywhere(
        'test-source',
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

      cache.recordComicCheckEverywhere(
        'test-source',
        'one',
        updateTime: '2026-8-3',
        updateMarker: 'time:2026-8-3|chapters:5',
      );
      expect(cache.countUncheckedComics(folder), 2);
      cache.recordComicCheckEverywhere(
        'test-source',
        'two',
        updateTime: '2026-8-3',
        updateMarker: 'time:2026-8-3|chapters:6',
      );
      cache.recordComicCheckEverywhere(
        'test-source',
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

  test('missing scan only checks unchecked comics', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[
        _comic('one'),
        _comic('two'),
        _comic('three'),
      ], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);
    cache.recordComicCheckEverywhere(
      'test-source',
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

    await scanFollowUpdates(
      [folder],
      FollowUpdateMode.missing,
      cache: cache,
    ).toList();
    expect(detailCalls, 2);
    expect(cache.countUncheckedComics(folder), 0);

    await scanFollowUpdates(
      [folder],
      FollowUpdateMode.missing,
      cache: cache,
    ).toList();
    expect(detailCalls, 2);
  });

  test('regular scan skips recent checks and fills gaps', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[
        _comic('one'),
        _comic('two'),
        _comic('three'),
      ], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);
    cache.recordComicCheckEverywhere(
      'test-source',
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

    await scanFollowUpdates(
      [folder],
      FollowUpdateMode.regular,
      cache: cache,
    ).toList();
    expect(detailCalls, 2);
    expect(cache.countUncheckedComics(folder), 0);
  });

  test('force scan rechecks every comic', () async {
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
      cache.recordComicCheckEverywhere(
        'test-source',
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

    await scanFollowUpdates(
      [folder],
      FollowUpdateMode.force,
      cache: cache,
    ).toList();
    expect(detailCalls, 3);
  });

  test('canceled scan does not process comics', () async {
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

    await scanFollowUpdates(
      [folder],
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
    cache.markComicRetryLaterEverywhere('test-source', 'two');

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

    await scanFollowUpdates(
      [folder],
      FollowUpdateMode.missing,
      cache: cache,
    ).toList();
    expect(detailCalls, 2);

    await scanFollowUpdates(
      [folder],
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
    cache.recordComicCheckEverywhere(
      'test-source',
      'one',
      updateTime: '2026-8-3',
      updateMarker: 'time:2026-8-3|chapters:5',
    );
    cache.markComicRetryLaterEverywhere('test-source', 'two');
    cache.markComicRetryLaterEverywhere('test-source', 'three');

    final progress = await scanFollowUpdates(
      [folder],
      FollowUpdateMode.missing,
      cache: cache,
    ).toList();

    expect(progress.last.total, 0);
    expect(progress.last.current, 0);
    expect(cache.countCachedComics(folder), 3);
    // Failed-and-cooled comics were already attempted: they are not an
    // unchecked gap, so the baseline counts as complete.
    expect(cache.countUncheckedComics(folder), 0);
    expect(
      cache.countCachedComics(folder) - cache.countUncheckedComics(folder),
      3,
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

      // A future cooldown excludes the comic from the pending count; the
      // cooldown is comic-level, so one call cools it in every folder.
      cache.markComicRetryLaterEverywhere('test-source', 'two');
      expect(
        cache.countPendingUncheckedComicsInFolders([folder, otherFolder]),
        2,
      );

      // An expired cooldown counts again.
      cache.markComicRetryLaterEverywhere(
        'test-source',
        'two',
        delay: const Duration(seconds: -1),
      );
      cache.markComicRetryLaterEverywhere(
        'test-source',
        'two',
        delay: const Duration(seconds: -1),
      );
      expect(
        cache.countPendingUncheckedComicsInFolders([folder, otherFolder]),
        3,
      );

      // A successful check no longer counts as pending (comic-level state).
      cache.recordComicCheckEverywhere(
        'test-source',
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
      cache.markComicRetryLaterEverywhere('test-source', 'two');
      cache.markComicRetryLaterEverywhere('test-source', 'two');
      expect(
        cache.countPendingUncheckedComicsInFolders([folder, otherFolder]),
        1,
      );
      // Cooling comics are attempted, not unchecked: only 'three' remains.
      expect(cache.countUncheckedComicsInFolders([folder, otherFolder]), 1);

      // A suspect mark is also a completed attempt: it never counts as an
      // unchecked gap, even after the baseline is reset.
      cache.markComicSuspectGoneEverywhere('test-source', 'three');
      expect(cache.countUncheckedComicsInFolders([folder, otherFolder]), 0);
      expect(
        cache.countPendingUncheckedComicsInFolders([folder, otherFolder]),
        0,
      );
      cache.clearAllBaselines();
      // 'one'/'two' are reset to never-checked (baseline rebuild), but the
      // suspect mark keeps 'three' out of the unchecked gap.
      expect(cache.countUncheckedComicsInFolders([folder, otherFolder]), 2);
      expect(cache.countUncheckedComics(folder), 2);
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

    cache.recordComicCheckEverywhere(
      'test-source',
      'one',
      updateTime: '2026-8-3',
      updateMarker: 'time:2026-8-3|chapters:5',
    );
    expect(cache.countUncheckedComicsInFolders([folder, folderB]), 3);

    cache.recordComicCheckEverywhere(
      'test-source',
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

  test(
    'a 404 on a healthy source marks the comic suspect immediately',
    () async {
      final data = _numericData(
        (page, [folder]) async =>
            Res(<Comic>[_comic('ok'), _comic('bad')], subData: 1),
      );
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);

      var detailCalls = 0;
      final source = _detailSource((id) async {
        detailCalls++;
        if (id == 'ok') {
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
        }
        return Res.error('404 Invalid status code: 404');
      });
      ComicSourceManager().add(source);
      addTearDown(() => ComicSourceManager().remove('test-source'));

      Future<void> scan() => scanFollowUpdates(
        [folder],
        FollowUpdateMode.force,
        ignoreRetryAfter: true,
        cache: cache,
      ).toList();

      // The 'ok' comic keeps the source healthy, so the 404 is credible and
      // marks 'bad' as suspected removed right away; the end-of-queue re-check
      // skips comics that are already marked.
      await scan();
      var bad = cache
          .getComicsWithUpdatesInfo(folder)
          .firstWhere((c) => c.id == 'bad');
      expect(detailCalls, 2); // ok + bad
      expect(bad.isSuspectGone, isTrue);
      expect(bad.lastCheckTime, isNotNull);

      // Suspect comics are skipped by later scans.
      await scan();
      bad = cache
          .getComicsWithUpdatesInfo(folder)
          .firstWhere((c) => c.id == 'bad');
      expect(detailCalls, 3);
      expect(bad.isSuspectGone, isTrue);
    },
  );

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

    await scanFollowUpdates(
      [folder],
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
    cache.markComicSuspectGoneEverywhere('test-source', 'one');

    var detailCalls = 0;
    final source = _detailSource((id) async {
      detailCalls++;
      return Res.error('404 Invalid status code: 404');
    });
    ComicSourceManager().add(source);
    addTearDown(() => ComicSourceManager().remove('test-source'));

    await scanFollowUpdates(
      [folder],
      FollowUpdateMode.force,
      ignoreRetryAfter: true,
      cache: cache,
    ).toList();
    await scanFollowUpdates(
      [folder],
      FollowUpdateMode.force,
      ignoreRetryAfter: true,
      cache: cache,
    ).toList();
    expect(cache.getComicsWithUpdatesInfo(folder).single.isSuspectGone, isTrue);
    // Suspect comics are filtered out at queue build time: no requests.
    expect(detailCalls, 0);
  });

  test('successful check clears suspect state', () async {
    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[_comic('one')], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);
    cache.markComicSuspectGoneEverywhere('test-source', 'one');

    // A successful detail load (page path / recordComicCheck) clears the mark
    // and the accumulated hits.
    cache.recordComicCheckEverywhere(
      'test-source',
      'one',
      updateTime: '2026-8-3',
      updateMarker: 'time:2026-8-3|chapters:5',
    );
    final item = cache.getComicsWithUpdatesInfo(folder).single;
    expect(item.isSuspectGone, isFalse);
    expect(item.checkFailures, 0);
    expect(item.checkNotFoundCount, 0);
    expect(item.retryAfter, isNull);
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

      cache.markComicSuspectGoneEverywhere('test-source', 'one');

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

    await scanFollowUpdates(
      [folder],
      FollowUpdateMode.force,
      ignoreRetryAfter: true,
      cache: cache,
    ).toList();
    var item = cache.getComicsWithUpdatesInfo(folder).single;
    expect(detailCalls, 3);
    expect(item.checkFailures, 1);
    expect(item.checkNotFoundCount, 0);
    expect(item.retryAfter, isNotNull);

    await scanFollowUpdates(
      [folder],
      FollowUpdateMode.force,
      ignoreRetryAfter: true,
      cache: cache,
    ).toList();
    item = cache.getComicsWithUpdatesInfo(folder).single;
    expect(detailCalls, 6);
    expect(item.checkFailures, 2);
  });

  test(
    'recordComicNotFoundEverywhere marks suspect on first hit and is idempotent',
    () async {
      final data = _numericData(
        (page, [folder]) async => Res(<Comic>[_comic('one')], subData: 1),
      );
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);

      // The user saw a 404/400 on the detail page first-hand: one response is
      // enough to mark the comic as suspected removed.
      cache.recordComicNotFoundEverywhere('test-source', 'one');
      var item = cache.getComicsWithUpdatesInfo(folder).single;
      expect(item.isSuspectGone, isTrue);

      // Repeated hits stay idempotent (no window, no accumulation).
      cache.recordComicNotFoundEverywhere('test-source', 'one');
      item = cache.getComicsWithUpdatesInfo(folder).single;
      expect(item.isSuspectGone, isTrue);

      // A successful load clears the mark.
      cache.recordComicCheckEverywhere(
        'test-source',
        'one',
        updateTime: '2026-8-3',
        updateMarker: 'time:2026-8-3|chapters:5',
      );
      item = cache.getComicsWithUpdatesInfo(folder).single;
      expect(item.isSuspectGone, isFalse);
    },
  );

  test(
    'successful checks commit state and all favorite rows atomically',
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

      final baseline = ComicDetails.fromJson({
        'title': 'Baseline',
        'subtitle': 'Author',
        'cover': 'https://example.invalid/baseline.jpg',
        'tags': <String, List<String>>{},
        'chapters': <String, String>{'1': 'Chapter 1'},
        'sourceKey': 'test-source',
        'comicId': 'one',
        'updateTime': '2026-08-03T10:00:00Z',
      });
      cache.recordComicCheckEverywhere(
        'test-source',
        'one',
        updateTime: '2026-8-3',
        updateMarker: 'baseline-marker',
      );
      expect(
        cache.applySuccessfulComicCheck(
          folder,
          'one',
          updateTime: baseline.findUpdateTime(),
          updateMarker: 'baseline-marker',
          title: baseline.title,
          author: baseline.subTitle,
          chapterCount: baseline.chapters?.length,
          cover: baseline.cover,
        ),
        isFalse,
        reason: 'an equal opaque marker is unchanged',
      );
      expect(
        cache.getComicsWithUpdatesInfo(folder).single.autoHotUntil,
        isNull,
        reason: 'marker migration must not create an automatic hot window',
      );
      for (final f in [folder, folderB]) {
        final item = cache.getComicsWithUpdatesInfo(f).single;
        expect(item.name, 'Baseline');
        // An unchanged opaque marker keeps the existing cached cover.
        expect(item.coverPath, contains('one.jpg'));
        expect(item.hasNewUpdate, isFalse);
      }

      final db = sqlite3.open(databasePath);
      db.execute(
        'UPDATE favorite_items SET comic_json = ? WHERE folder_id = ?',
        ['not-json', folderB.folderId],
      );
      db.dispose();

      final changed = ComicDetails.fromJson({
        'title': 'Changed',
        'subtitle': 'New author',
        'cover': 'https://example.invalid/changed.jpg',
        'tags': <String, List<String>>{},
        'chapters': <String, String>{'2': 'Chapter 2'},
        'sourceKey': 'test-source',
        'comicId': 'one',
        'updateTime': '2026-08-04T00:00:00Z',
      });
      expect(
        () => cache.applySuccessfulComicCheck(
          folder,
          'one',
          updateTime: changed.findUpdateTime(),
          updateMarker: 'changed-marker',
          title: changed.title,
          author: changed.subTitle,
          chapterCount: changed.chapters?.length,
          cover: changed.cover,
        ),
        throwsFormatException,
      );

      final first = cache.getComicsWithUpdatesInfo(folder).single;
      expect(first.name, 'Baseline');
      expect(first.coverPath, contains('one.jpg'));
      final stateDb = sqlite3.open(databasePath);
      try {
        final state = stateDb.select(
          'SELECT update_marker FROM comic_check_state WHERE source_key = ? AND comic_id = ?',
          ['test-source', 'one'],
        );
        expect(state.single['update_marker'], 'baseline-marker');
      } finally {
        stateDb.dispose();
      }
    },
  );

  test('detail evidence projects into standard UpdateState', () {
    final info = ComicDetails.fromJson({
      'title': 'Comic',
      'subtitle': 'Author',
      'cover': '',
      'tags': <String, List<String>>{},
      'chapters': <String, String>{'1': 'Chapter 1', '2': 'Chapter 2'},
      'sourceKey': 'test-source',
      'comicId': 'one',
      'updateTime': '2026-08-03T10:00:00Z',
    });
    final state = TrackingNormalizer.fromComicDetails(info).state!;
    expect(state.updatedAt, DateTime.utc(2026, 8, 3, 10));
    expect(state.latestChapterId, '1');
    expect(state.chapterCount, 2);
    expect(state.recentChapterIds, ['1', '2']);
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

  test('scan run persistence round-trips and clears', () {
    final run = cache.createScanRun(
      mode: 'regular',
      ignoreRetryAfter: true,
      total: 2,
      items: const [('test-source', 'one'), ('test-source', 'two')],
    );
    expect(run.status, 'running');
    expect(run.mode, 'regular');
    expect(run.ignoreRetryAfter, isTrue);
    expect(cache.getCurrentScanRun()!.runId, run.runId);

    expect(cache.getDoneScanItems(run.runId), isEmpty);
    cache.markScanItemDone(run.runId, 'test-source', 'one', result: 'ok');
    expect(cache.getDoneScanItems(run.runId), {'test-source\u0000one'});

    cache.updateScanRunStatus(run.runId, 'finished');
    expect(cache.getCurrentScanRun()!.status, 'finished');
    expect(cache.getCurrentScanRun()!.finishedAt, isNotNull);

    cache.clearScanRun();
    expect(cache.getCurrentScanRun(), isNull);

    // A fresh run after a terminal one replaces the queue.
    final next = cache.createScanRun(
      mode: 'missing',
      ignoreRetryAfter: false,
      total: 1,
      items: const [('test-source', 'three')],
    );
    expect(next.runId, isNot(run.runId));
    expect(cache.getDoneScanItems(next.runId), isEmpty);
  });

  test('malformed scan run metadata degrades to no run', () {
    final db = sqlite3.open('${tempDir.path}${Platform.pathSeparator}cache.db');
    db.execute('INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)', [
      'follow_update_run',
      'not-json',
    ]);
    db.dispose();
    expect(cache.getCurrentScanRun(), isNull);
  });

  test(
    'everywhere variants write all folder rows and fall back when membership is empty',
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

      cache.updateBasicInfoEverywhere(folder, 'one', chapterCount: 9);
      for (final f in [folder, folderB]) {
        final item = cache.getComicsWithUpdatesInfo(f).single;
        expect(item.chapterCount, 9);
      }

      cache.recordComicCheckEverywhere(
        'test-source',
        'one',
        updateTime: '2026-8-3',
        updateMarker: 'time:2026-8-3|chapters:9',
      );
      for (final f in [folder, folderB]) {
        final item = cache.getComicsWithUpdatesInfo(f).single;
        expect(item.checkNotFoundCount, 0);
        expect(item.lastCheckTime, isNotNull);
      }

      // Comic-level state is shared by every folder row: a comic cached only in
      // one folder still gets its retry state from the same table.
      await cache.refreshPage(
        data,
        const NetworkFavoriteFolderRef(
          sourceKey: 'test-source',
          folderId: 'solo',
          title: 'Solo',
        ),
        1,
      );
      cache.markComicRetryLaterEverywhere(
        'test-source',
        'one',
        delay: const Duration(hours: 2),
      );
      final solo = cache
          .getComicsWithUpdatesInfo(
            const NetworkFavoriteFolderRef(
              sourceKey: 'test-source',
              folderId: 'solo',
              title: 'Solo',
            ),
          )
          .single;
      expect(solo.retryAfter, isNotNull);

      cache.markComicSuspectGoneEverywhere('test-source', 'one');
      expect(cache.isComicSuspectGone('test-source', 'one'), isTrue);
    },
  );

  test('removal learns the favorite id from a refreshed first page', () async {
    String? receivedFavoriteId;
    final data = FavoriteData(
      key: 'test-source',
      title: 'Test source',
      multiFolder: true,
      loadComic: (page, [folder]) async => Res(<Comic>[
        FavoriteItem(
          id: 'one',
          name: 'Comic',
          coverPath: 'https://example.invalid/one.jpg',
          author: 'Author',
          sourceKeyValue: 'test-source',
          tags: const ['tag'],
          remoteFavoriteId: 'fav-1',
        ),
      ], subData: 1),
      loadNext: null,
      loadFolders: ([String? _]) async =>
          const Res(<String, String>{'remote': 'Remote'}),
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
      data,
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
    await cache.refreshFolders(data);

    // Panel-style add: only the membership row is written, the folder page
    // cache (favorite_items) is untouched.
    final added = await cache.changeFavorite(
      data: data,
      folder: folder,
      comicId: 'one',
      isAdding: true,
    );
    expect(added.success, isTrue);
    expect(cache.countCachedComics(folder), 0);
    expect(cache.isFavoriteKnown('test-source', 'one'), isTrue);

    // Removal without a cached favorite id refreshes the first page, learns
    // the id from the server list and passes it to the source.
    final removed = await cache.changeFavorite(
      data: data,
      folder: folder,
      comicId: 'one',
      isAdding: false,
    );
    expect(removed.success, isTrue);
    expect(receivedFavoriteId, 'fav-1');
    expect(cache.isFavoriteKnown('test-source', 'one'), isFalse);
    expect(cache.countCachedComics(folder), 0);
  });

  group('favoriteFolderDisplayTitle', () {
    test('strips a trailing numeric count in parentheses', () {
      expect(favoriteFolderDisplayTitle('Favorites 0 (1234)'), 'Favorites 0');
      expect(favoriteFolderDisplayTitle('Favorites 1 (42)'), 'Favorites 1');
    });

    test('keeps titles without a trailing count', () {
      expect(favoriteFolderDisplayTitle('Favorites 0'), 'Favorites 0');
      expect(favoriteFolderDisplayTitle(''), '');
      expect(favoriteFolderDisplayTitle('My List (2nd)'), 'My List (2nd)');
      expect(
        favoriteFolderDisplayTitle('Favorites 0 (12) extra'),
        'Favorites 0 (12) extra',
      );
    });
  });
}
