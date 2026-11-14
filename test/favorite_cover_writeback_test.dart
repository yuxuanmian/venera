import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_source/scan.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/utils/translations.dart';

const _sourceKey = 'cover_writeback_source';

FavoriteItem _favorite(
  String id, {
  String sourceKey = _sourceKey,
  String cover = 'https://example.com/old.jpg',
}) => FavoriteItem(
  id: id,
  name: 'Comic $id',
  coverPath: cover,
  author: 'Author $id',
  sourceKeyValue: sourceKey,
  tags: const ['tag'],
);

FavoriteData _numberedData(
  Map<int, List<Comic>> pages, {
  String sourceKey = _sourceKey,
  Map<String, String> folders = const {'': 'Favorites'},
  List<int>? calls,
}) => FavoriteData(
  key: sourceKey,
  title: 'Favorites',
  multiFolder: folders.length > 1,
  loadComic: (page, [_]) async {
    calls?.add(page);
    return Res(pages[page] ?? const [], subData: 2);
  },
  loadNext: null,
  loadFolders: ([_]) async => Res(folders),
);

FavoriteData _cursorData(
  Map<String?, Res<List<Comic>>> pages, {
  String sourceKey = _sourceKey,
}) => FavoriteData(
  key: sourceKey,
  title: 'Favorites',
  multiFolder: false,
  loadComic: null,
  loadNext: (token, [_]) async =>
      pages[token] ?? const Res<List<Comic>>([], subData: null),
);

ComicDetails _details(String id, String cover) => ComicDetails.fromJson({
  'title': 'Comic $id',
  'subtitle': 'Author',
  'cover': cover,
  'description': 'Description',
  'tags': <String, List<String>>{},
  'chapters': <String, String>{'1': 'Chapter'},
  'sourceKey': _sourceKey,
  'comicId': id,
});

ComicSource _source({
  FavoriteData? favoriteData,
  Future<Res<ComicDetails>> Function(String id)? loadComicInfo,
  AccountConfig? account,
  ScanCapabilities? scan,
}) => ComicSource(
  'Cover writeback test source',
  _sourceKey,
  account,
  null,
  null,
  favoriteData,
  const [],
  null,
  null,
  loadComicInfo ?? (id) async => Res.error('Unused'),
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
  scan: scan,
);

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  fail('Condition was not reached before $timeout');
}

String? _cachedCover(
  NetworkFavoriteCacheManager cache,
  NetworkFavoriteFolderRef folder,
  int page,
  String comicId,
) {
  final cached = cache.getCachedPage(folder, page);
  if (cached == null) return null;
  for (final comic in cached.comics) {
    if (comic.id == comicId) return comic.cover;
  }
  return null;
}

ComicTile _tileFor(WidgetTester tester, String comicId) => tester
    .widgetList<ComicTile>(find.byType(ComicTile))
    .singleWhere((tile) => tile.comic.id == comicId);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late NetworkFavoriteCacheManager cache;
  late String databasePath;
  late String oldImagePath;
  late String newImagePath;
  late Object? previousListMode;
  late Object? previousComicMode;
  late Object? previousEnabledSources;
  late Object? previousFavorites;
  late Object? previousFollowUpdatesEnabled;
  late Object? previousLanguage;

  setUpAll(() async {
    await AppTranslation.init();
    tempDir = await Directory.systemTemp.createTemp('venera-cover-writeback-');
    App.dataPath = tempDir.path;
    App.cachePath = tempDir.path;
    databasePath =
        '${tempDir.path}${Platform.pathSeparator}network_favorite_cache.db';
    await HistoryManager().init();
    cache = NetworkFavoriteCacheManager();
    await cache.init(databasePath: databasePath, migrateLegacy: false);

    final imageFile = File(
      '${Directory.current.path}${Platform.pathSeparator}assets'
      '${Platform.pathSeparator}app_icon.png',
    );
    oldImagePath = imageFile.path;
    newImagePath =
        '${tempDir.path}${Platform.pathSeparator}replacement-cover.png';
    await imageFile.copy(newImagePath);

    previousListMode = appdata.settings['comicListDisplayMode'];
    previousComicMode = appdata.settings['comicDisplayMode'];
    previousEnabledSources = appdata.settings['enabledSources'];
    previousFavorites = appdata.settings['favorites'];
    previousFollowUpdatesEnabled = appdata.settings['followUpdatesEnabled'];
    previousLanguage = appdata.settings['language'];
    appdata.settings['comicListDisplayMode'] = 'paging';
    appdata.settings['comicDisplayMode'] = 'detailed';
  });

  setUp(() {
    cache.clearAllCache();
    ComicSourceManager().remove(_sourceKey);
  });

  tearDown(() {
    ComicSourceManager().remove(_sourceKey);
  });

  tearDownAll(() async {
    appdata.settings['comicListDisplayMode'] = previousListMode;
    appdata.settings['comicDisplayMode'] = previousComicMode;
    appdata.settings['enabledSources'] = previousEnabledSources;
    appdata.settings['favorites'] = previousFavorites;
    appdata.settings['followUpdatesEnabled'] = previousFollowUpdatesEnabled;
    appdata.settings['language'] = previousLanguage;
    await judgmentStateRepository.close();
    cache.close();
    HistoryManager().close();
    try {
      await tempDir.delete(recursive: true);
    } on PathAccessException {
      // SQLite can release Windows handles just after close.
    }
  });

  group('favorite cover persistence', () {
    test(
      'CAS writes matching rows and notification is presentation-only',
      () async {
        const f1 = NetworkFavoriteFolderRef(
          sourceKey: _sourceKey,
          folderId: 'f1',
        );
        const f2 = NetworkFavoriteFolderRef(
          sourceKey: _sourceKey,
          folderId: 'f2',
        );
        final data = _numberedData(
          {
            1: [_favorite('comic', cover: 'https://example.com/original.jpg')],
          },
          folders: const {'f1': 'F1', 'f2': 'F2'},
        );
        await cache.refreshFolders(data);
        await cache.refreshPage(data, f1, 1);
        await cache.refreshPage(data, f2, 1);
        cache.takeFollowUpdateChangeBatch();

        final snapshot = cache.captureFavoriteCoverSnapshot(
          _sourceKey,
          'comic',
        );
        var notifications = 0;
        cache.addListener(() => notifications++);
        var coverNotifications = 0;
        cache.favoriteCoverChanges.addListener(() => coverNotifications++);
        final written = cache.writebackFavoriteCover(
          snapshot: snapshot,
          newCover: 'https://example.com/repaired.jpg',
        );

        expect(written, isTrue);
        expect(notifications, 0);
        expect(coverNotifications, 1);
        expect(cache.favoriteCoverChanges.value!.covers, {
          'comic': 'https://example.com/repaired.jpg',
        });
        expect(
          _cachedCover(cache, f1, 1, 'comic'),
          'https://example.com/repaired.jpg',
        );
        expect(
          _cachedCover(cache, f2, 1, 'comic'),
          'https://example.com/repaired.jpg',
        );
        expect(cache.takeFollowUpdateChangeBatch().changedSourceKeys, isEmpty);
      },
    );

    test('CAS leaves an intervening row untouched', () async {
      const f1 = NetworkFavoriteFolderRef(
        sourceKey: _sourceKey,
        folderId: 'f1',
      );
      const f2 = NetworkFavoriteFolderRef(
        sourceKey: _sourceKey,
        folderId: 'f2',
      );
      final initial = _numberedData(
        {
          1: [_favorite('comic', cover: 'https://example.com/original.jpg')],
        },
        folders: const {'f1': 'F1', 'f2': 'F2'},
      );
      await cache.refreshFolders(initial);
      await cache.refreshPage(initial, f1, 1);
      await cache.refreshPage(initial, f2, 1);
      final snapshot = cache.captureFavoriteCoverSnapshot(_sourceKey, 'comic');

      final intervening = _numberedData(
        {
          1: [_favorite('comic', cover: 'https://example.com/intervening.jpg')],
        },
        folders: const {'f1': 'F1', 'f2': 'F2'},
      );
      await cache.refreshPage(intervening, f1, 1);

      expect(
        cache.writebackFavoriteCover(
          snapshot: snapshot,
          newCover: 'https://example.com/detail.jpg',
        ),
        isTrue,
      );
      expect(
        _cachedCover(cache, f1, 1, 'comic'),
        'https://example.com/intervening.jpg',
      );
      expect(
        _cachedCover(cache, f2, 1, 'comic'),
        'https://example.com/detail.jpg',
      );
    });

    test('stale cache generation rejects a writeback', () async {
      const folder = NetworkFavoriteFolderRef(
        sourceKey: _sourceKey,
        folderId: '',
      );
      final data = _numberedData({
        1: [_favorite('comic', cover: 'https://example.com/original.jpg')],
      });
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);
      final snapshot = cache.captureFavoriteCoverSnapshot(_sourceKey, 'comic');

      cache.clearAllCache();
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);

      expect(
        cache.writebackFavoriteCover(
          snapshot: snapshot,
          newCover: 'https://example.com/detail.jpg',
        ),
        isFalse,
      );
      expect(
        _cachedCover(cache, folder, 1, 'comic'),
        'https://example.com/original.jpg',
      );
    });

    test('account invalidation rejects a no-unread source writeback', () async {
      const folder = NetworkFavoriteFolderRef(
        sourceKey: _sourceKey,
        folderId: '',
      );
      final data = _numberedData({
        1: [_favorite('comic', cover: 'https://example.com/original.jpg')],
      });
      ComicSourceManager().add(_source(favoriteData: data));
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);
      final snapshot = cache.captureFavoriteCoverSnapshot(_sourceKey, 'comic');

      cache.invalidateFavoriteSessionForSource(_sourceKey);

      expect(
        cache.writebackFavoriteCover(
          snapshot: snapshot,
          newCover: 'https://example.com/detail.jpg',
        ),
        isFalse,
      );
      expect(
        _cachedCover(cache, folder, 1, 'comic'),
        'https://example.com/original.jpg',
      );
    });

    test(
      'explicit refresh protects a repaired cover from known old URLs',
      () async {
        const folder = NetworkFavoriteFolderRef(
          sourceKey: _sourceKey,
          folderId: '',
        );
        final data = _numberedData({
          1: [_favorite('comic', cover: 'https://example.com/original.jpg')],
        });
        await cache.refreshFolders(data);
        await cache.refreshPage(data, folder, 1);
        final snapshot = cache.captureFavoriteCoverSnapshot(
          _sourceKey,
          'comic',
        );
        cache.writebackFavoriteCover(
          snapshot: snapshot,
          newCover: 'https://example.com/repaired.jpg',
        );

        await cache.refreshPage(data, folder, 1);
        expect(
          _cachedCover(cache, folder, 1, 'comic'),
          'https://example.com/repaired.jpg',
        );
        final blank = _numberedData({
          1: [_favorite('comic', cover: '   ')],
        });
        await cache.refreshPage(blank, folder, 1);
        expect(
          _cachedCover(cache, folder, 1, 'comic'),
          'https://example.com/repaired.jpg',
        );

        final unrelated = _numberedData({
          1: [_favorite('comic', cover: 'https://example.com/newer.jpg')],
        });
        await cache.refreshPage(unrelated, folder, 1);
        expect(
          _cachedCover(cache, folder, 1, 'comic'),
          'https://example.com/newer.jpg',
        );
        await cache.refreshPage(data, folder, 1, preserveExistingCover: true);
        expect(
          _cachedCover(cache, folder, 1, 'comic'),
          'https://example.com/newer.jpg',
        );
      },
    );
  });

  group('user-invoked full cache', () {
    test('numbered full cache adopts a nonblank remote cover', () async {
      const folder = NetworkFavoriteFolderRef(
        sourceKey: _sourceKey,
        folderId: '',
      );
      final initial = _numberedData({
        1: [_favorite('comic', cover: 'https://example.com/original.jpg')],
      });
      await cache.refreshFolders(initial);
      await cache.refreshPage(initial, folder, 1);

      final calls = <int>[];
      final refreshed = _numberedData({
        1: [_favorite('comic', cover: 'https://example.com/full-cache.jpg')],
        2: const [],
      }, calls: calls);
      await cache
          .cacheAllPages(refreshed, folder, isCanceled: () => false)
          .drain<void>();

      expect(calls, [1, 2]);
      expect(
        _cachedCover(cache, folder, 1, 'comic'),
        'https://example.com/full-cache.jpg',
      );
    });

    test(
      'known old URL survives a page move and a newer URL is accepted',
      () async {
        const folder = NetworkFavoriteFolderRef(
          sourceKey: _sourceKey,
          folderId: '',
        );
        final initial = _numberedData({
          1: [_favorite('comic', cover: 'https://example.com/original.jpg')],
        });
        await cache.refreshFolders(initial);
        await cache.refreshPage(initial, folder, 1);
        final snapshot = cache.captureFavoriteCoverSnapshot(
          _sourceKey,
          'comic',
        );
        cache.writebackFavoriteCover(
          snapshot: snapshot,
          newCover: 'https://example.com/repaired.jpg',
        );

        final movedWithOldCover = _numberedData({
          1: const [],
          2: [_favorite('comic', cover: 'https://example.com/original.jpg')],
        });
        await cache
            .cacheAllPages(movedWithOldCover, folder, isCanceled: () => false)
            .drain<void>();
        expect(
          _cachedCover(cache, folder, 2, 'comic'),
          'https://example.com/repaired.jpg',
        );

        final movedWithNewCover = _numberedData({
          1: const [],
          2: [_favorite('comic', cover: 'https://example.com/newer.jpg')],
        });
        await cache
            .cacheAllPages(movedWithNewCover, folder, isCanceled: () => false)
            .drain<void>();
        expect(
          _cachedCover(cache, folder, 2, 'comic'),
          'https://example.com/newer.jpg',
        );
      },
    );

    test(
      'full cache rejects a later page after the account epoch changes',
      () async {
        const folder = NetworkFavoriteFolderRef(
          sourceKey: _sourceKey,
          folderId: '',
        );
        final initial = _numberedData({
          1: [_favorite('comic', cover: 'https://example.com/original.jpg')],
        });
        await cache.refreshFolders(initial);
        await cache.refreshPage(initial, folder, 1);

        final secondPageStarted = Completer<void>();
        final secondPageResult = Completer<Res<List<Comic>>>();
        final refreshed = FavoriteData(
          key: _sourceKey,
          title: 'Favorites',
          multiFolder: false,
          loadComic: (page, [_]) async {
            if (page == 1) {
              return Res([
                _favorite('comic', cover: 'https://example.com/original.jpg'),
              ], subData: 2);
            }
            secondPageStarted.complete();
            return secondPageResult.future;
          },
          loadNext: null,
        );
        final progress = cache
            .cacheAllPages(refreshed, folder, isCanceled: () => false)
            .toList();
        await secondPageStarted.future;

        cache.invalidateFavoriteSessionForSource(_sourceKey);
        secondPageResult.complete(
          Res([
            _favorite('comic', cover: 'https://example.com/wrong-account.jpg'),
          ], subData: 2),
        );
        final events = await progress;

        expect(events.any((event) => event.errorMessage != null), isTrue);
        expect(
          _cachedCover(cache, folder, 1, 'comic'),
          'https://example.com/original.jpg',
        );
        expect(cache.getCachedPage(folder, 2), isNull);
      },
    );

    test('fresh folder repair outranks stale in-flight provenance', () async {
      const f1 = NetworkFavoriteFolderRef(
        sourceKey: _sourceKey,
        folderId: 'f1',
      );
      const f2 = NetworkFavoriteFolderRef(
        sourceKey: _sourceKey,
        folderId: 'f2',
      );
      final initial = _numberedData(
        {
          1: [_favorite('comic', cover: 'https://example.com/original.jpg')],
        },
        folders: const {'f1': 'F1', 'f2': 'F2'},
      );
      await cache.refreshFolders(initial);
      await cache.refreshPage(initial, f1, 1);
      await cache.refreshPage(initial, f2, 1);
      final snapshot = cache.captureFavoriteCoverSnapshot(_sourceKey, 'comic');
      cache.writebackFavoriteCover(
        snapshot: snapshot,
        newCover: 'https://example.com/repaired-v1.jpg',
      );

      final firstPageStarted = Completer<void>();
      final firstPageRelease = Completer<void>();
      final moved = FavoriteData(
        key: _sourceKey,
        title: 'Favorites',
        multiFolder: true,
        loadComic: (page, [_]) async {
          if (page == 1) {
            firstPageStarted.complete();
            await firstPageRelease.future;
            return const Res<List<Comic>>([], subData: 2);
          }
          return Res([
            _favorite('comic', cover: 'https://example.com/original.jpg'),
          ], subData: 2);
        },
        loadNext: null,
      );
      final progress = cache
          .cacheAllPages(moved, f1, isCanceled: () => false)
          .drain<void>();
      await firstPageStarted.future;

      final newer = _numberedData(
        {
          1: [_favorite('comic', cover: 'https://example.com/repaired-v2.jpg')],
        },
        folders: const {'f1': 'F1', 'f2': 'F2'},
      );
      await cache.refreshPage(newer, f2, 1);
      firstPageRelease.complete();
      await progress;

      expect(
        _cachedCover(cache, f1, 2, 'comic'),
        'https://example.com/repaired-v2.jpg',
      );
    });

    test('cursor full cache adopts a nonblank remote cover', () async {
      const folder = NetworkFavoriteFolderRef(
        sourceKey: _sourceKey,
        folderId: '',
      );
      final initial = _cursorData({
        null: Res([
          _favorite('comic', cover: 'https://example.com/original.jpg'),
        ], subData: 'next'),
        'next': const Res<List<Comic>>([], subData: null),
      });
      await cache.refreshNextPage(initial, folder, null);

      final refreshed = _cursorData({
        null: Res([
          _favorite('comic', cover: 'https://example.com/full-cache.jpg'),
        ], subData: 'next'),
        'next': const Res<List<Comic>>([], subData: null),
      });
      await cache
          .cacheAllPages(refreshed, folder, isCanceled: () => false)
          .drain<void>();

      final cached = cache.getCachedNextPage(folder, null)!;
      expect(cached.comics.single.cover, 'https://example.com/full-cache.jpg');
    });

    test('full cache blank cover keeps the existing URL', () async {
      const folder = NetworkFavoriteFolderRef(
        sourceKey: _sourceKey,
        folderId: '',
      );
      final initial = _numberedData({
        1: [_favorite('comic', cover: 'https://example.com/original.jpg')],
      });
      await cache.refreshFolders(initial);
      await cache.refreshPage(initial, folder, 1);

      final blank = _numberedData({
        1: [_favorite('comic', cover: '   ')],
      });
      await cache
          .cacheAllPages(blank, folder, isCanceled: () => false)
          .drain<void>();

      expect(
        _cachedCover(cache, folder, 1, 'comic'),
        'https://example.com/original.jpg',
      );
    });
  });

  group('ComicPage decoded cover callback', () {
    testWidgets('successful detail image writes its exact cover', (
      tester,
    ) async {
      const folder = NetworkFavoriteFolderRef(
        sourceKey: _sourceKey,
        folderId: '',
      );
      final data = _numberedData({
        1: [_favorite('detail-success', cover: 'file://$oldImagePath')],
      });
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);
      var detailRequests = 0;
      ComicSourceManager().add(
        _source(
          favoriteData: data,
          loadComicInfo: (id) async {
            detailRequests++;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            return Res(_details(id, 'file://$newImagePath'));
          },
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ComicPage(
            id: 'detail-success',
            sourceKey: _sourceKey,
            cover: 'file://$oldImagePath',
          ),
        ),
      );
      await tester.pump();
      await _waitFor(
        tester,
        () =>
            _cachedCover(cache, folder, 1, 'detail-success') ==
            'file://$newImagePath',
      );

      final stored = cache.getCachedPage(folder, 1)!.comics.single;
      expect(stored.supersededCovers, ['file://$oldImagePath']);
      expect(detailRequests, 1);
    });

    testWidgets('failed detail image preserves the favorite cover', (
      tester,
    ) async {
      const folder = NetworkFavoriteFolderRef(
        sourceKey: _sourceKey,
        folderId: '',
      );
      final data = _numberedData({
        1: [_favorite('detail-failure', cover: 'file://$oldImagePath')],
      });
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);
      final missingPath =
          '${tempDir.path}${Platform.pathSeparator}missing-cover.png';
      ComicSourceManager().add(
        _source(
          favoriteData: data,
          loadComicInfo: (id) async => Res(_details(id, 'file://$missingPath')),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ComicPage(
            id: 'detail-failure',
            sourceKey: _sourceKey,
            cover: 'file://$oldImagePath',
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        _cachedCover(cache, folder, 1, 'detail-failure'),
        'file://$oldImagePath',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('blank detail cover displays fallback without writeback', (
      tester,
    ) async {
      const folder = NetworkFavoriteFolderRef(
        sourceKey: _sourceKey,
        folderId: '',
      );
      final data = _numberedData({
        1: [_favorite('detail-blank', cover: 'file://$oldImagePath')],
      });
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);
      ComicSourceManager().add(
        _source(
          favoriteData: data,
          loadComicInfo: (id) async => Res(_details(id, '   ')),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ComicPage(
            id: 'detail-blank',
            sourceKey: _sourceKey,
            cover: 'file://$oldImagePath',
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      final stored = cache.getCachedPage(folder, 1)!.comics.single;
      expect(stored.cover, 'file://$oldImagePath');
      expect(stored.supersededCovers, isEmpty);
    });

    testWidgets('memory-cache image hit still triggers writeback', (
      tester,
    ) async {
      const folder = NetworkFavoriteFolderRef(
        sourceKey: _sourceKey,
        folderId: '',
      );
      final data = _numberedData({
        1: [_favorite('detail-memory', cover: 'file://$oldImagePath')],
      });
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);

      final provider = CachedImageProvider(
        'file://$newImagePath',
        sourceKey: _sourceKey,
        cid: 'detail-memory',
      );
      await tester.pumpWidget(MaterialApp(home: Image(image: provider)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
      await tester.pump();
      await tester.pumpWidget(const SizedBox());

      ComicSourceManager().add(
        _source(
          favoriteData: data,
          loadComicInfo: (id) async =>
              Res(_details(id, 'file://$newImagePath')),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ComicPage(
            id: 'detail-memory',
            sourceKey: _sourceKey,
            cover: 'file://$oldImagePath',
          ),
        ),
      );
      await tester.pump();
      await _waitFor(
        tester,
        () =>
            _cachedCover(cache, folder, 1, 'detail-memory') ==
            'file://$newImagePath',
      );

      expect(cache.getCachedPage(folder, 1)!.comics.single.supersededCovers, [
        'file://$oldImagePath',
      ]);
    });
  });

  group('favorite card presentation', () {
    testWidgets('continuous page two updates in place and keeps its hero id', (
      tester,
    ) async {
      final previousMode = appdata.settings['comicListDisplayMode'];
      appdata.settings['comicListDisplayMode'] = 'continuous';
      addTearDown(() {
        appdata.settings['comicListDisplayMode'] = previousMode;
      });
      const folder = NetworkFavoriteFolderRef(
        sourceKey: _sourceKey,
        folderId: '',
        title: 'Favorites',
      );
      final data = _numberedData({
        1: [_favorite('page-one', cover: 'file://$oldImagePath')],
        2: [_favorite('page-two', cover: 'file://$oldImagePath')],
      });
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);
      await cache.refreshPage(data, folder, 2);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: NetworkFavoritePage(data: data)),
        ),
      );
      await tester.pump();
      await _waitFor(
        tester,
        () => find.text('Comic page-two').evaluate().isNotEmpty,
      );
      final heroIdBefore = _tileFor(tester, 'page-two').heroID;

      final snapshot = cache.captureFavoriteCoverSnapshot(
        _sourceKey,
        'page-two',
      );
      cache.writebackFavoriteCover(
        snapshot: snapshot,
        newCover: 'file://$newImagePath',
      );
      await _waitFor(
        tester,
        () =>
            _tileFor(tester, 'page-two').comic.cover == 'file://$newImagePath',
      );

      expect(_tileFor(tester, 'page-two').heroID, heroIdBefore);
    });

    testWidgets('paged revisit sees a background page cover update', (
      tester,
    ) async {
      final previousMode = appdata.settings['comicListDisplayMode'];
      appdata.settings['comicListDisplayMode'] = 'paging';
      addTearDown(() {
        appdata.settings['comicListDisplayMode'] = previousMode;
      });
      const folder = NetworkFavoriteFolderRef(
        sourceKey: _sourceKey,
        folderId: '',
        title: 'Favorites',
      );
      final data = _numberedData({
        1: [_favorite('page-one', cover: 'file://$oldImagePath')],
        2: [_favorite('page-two', cover: 'file://$oldImagePath')],
      });
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);
      await cache.refreshPage(data, folder, 2);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: NetworkFavoritePage(data: data)),
        ),
      );
      await tester.pump();
      await _waitFor(
        tester,
        () => find.text('Comic page-one').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Next'));
      await _waitFor(
        tester,
        () => find.text('Comic page-two').evaluate().isNotEmpty,
      );

      final snapshot = cache.captureFavoriteCoverSnapshot(
        _sourceKey,
        'page-one',
      );
      cache.writebackFavoriteCover(
        snapshot: snapshot,
        newCover: 'file://$newImagePath',
      );
      await tester.tap(find.text('Back'));
      await _waitFor(
        tester,
        () => find.text('Comic page-one').evaluate().isNotEmpty,
      );
      expect(_tileFor(tester, 'page-one').comic.cover, 'file://$newImagePath');
    });

    testWidgets('favorites page updates the current card cover', (
      tester,
    ) async {
      const folder = NetworkFavoriteFolderRef(
        sourceKey: _sourceKey,
        folderId: '',
        title: 'Favorites',
      );
      final data = _numberedData({
        1: [_favorite('favorites-ui', cover: 'file://$oldImagePath')],
      });
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: NetworkFavoritePage(data: data)),
        ),
      );
      await tester.pump();
      await _waitFor(
        tester,
        () => find.text('Comic favorites-ui').evaluate().isNotEmpty,
      );

      final snapshot = cache.captureFavoriteCoverSnapshot(
        _sourceKey,
        'favorites-ui',
      );
      cache.writebackFavoriteCover(
        snapshot: snapshot,
        newCover: 'file://$newImagePath',
      );
      await _waitFor(tester, () {
        return _tileFor(tester, 'favorites-ui').comic.cover ==
            'file://$newImagePath';
      });
    });

    testWidgets('follow-up page updates the active list cover', (tester) async {
      const folder = NetworkFavoriteFolderRef(
        sourceKey: _sourceKey,
        folderId: 'remote',
        title: 'Remote',
      );
      final data = FavoriteData(
        key: _sourceKey,
        title: 'Favorites',
        multiFolder: true,
        loadComic: (page, [_]) async => Res([
          _favorite('follow-ui', cover: 'file://$oldImagePath'),
        ], subData: 1),
        loadNext: null,
        loadFolders: ([_]) async => const Res({'remote': 'Remote'}),
      );
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);

      ComicSourceManager().add(
        _source(
          favoriteData: data,
          account: AccountConfig(
            null,
            null,
            null,
            () {},
            null,
            null,
            null,
            null,
          ),
          scan: ScanCapabilities.supported(
            primary: ScanProducer.comic,
            comic: ScanCapability.comic(
              (comicId, request) async => null,
              evidenceSchema: '{"latestchapterid":"last_chapter.id"}',
            ),
          ),
        )..data['account'] = <String, dynamic>{'fixture': true},
      );

      final db = sqlite3.open(databasePath);
      db.execute(
        '''UPDATE favorite_folders SET full_cache_at = ?
           WHERE source_key = ? AND folder_id = ?''',
        [DateTime.now().millisecondsSinceEpoch, _sourceKey, 'remote'],
      );
      db.dispose();
      expect(cache.getFullCacheStatus(folder).isComplete, isTrue);

      appdata.settings['enabledSources'] = <String>[_sourceKey];
      appdata.settings['favorites'] = <String>[_sourceKey];
      appdata.settings['followUpdatesEnabled'] = true;
      appdata.settings['language'] = 'system';
      await judgmentStateRepository.ensureOpen();
      await judgmentStateRepository.applyBatch([
        JudgmentState(
          sourceKey: _sourceKey,
          comicId: 'follow-ui',
          lastDecision: JudgmentConclusion.changed,
          lastReason: JudgmentReason.later,
          decidedAtMs: 1,
          hasNewUpdate: true,
          algorithmVersion: judgmentAlgorithmVersion,
        ),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: const FollowUpdatesPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Favorites are not fully cached yet'.tl), findsNothing);
      await _waitFor(
        tester,
        () => find.text('Comic follow-ui').evaluate().isNotEmpty,
      );
      final snapshot = cache.captureFavoriteCoverSnapshot(
        _sourceKey,
        'follow-ui',
      );
      cache.writebackFavoriteCover(
        snapshot: snapshot,
        newCover: 'file://$newImagePath',
      );
      await _waitFor(tester, () {
        return _tileFor(tester, 'follow-ui').comic.cover ==
            'file://$newImagePath';
      });
    });
  });
}
