import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/source_adapter.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/utils/translations.dart';

import 'scan_kernel/fakes.dart';

String? _testImagePath;

FavoriteItem _comic(String sourceKey, String id) => FavoriteItem(
  id: id,
  name: id,
  coverPath: 'file://${_testImagePath!}',
  author: 'Author',
  sourceKeyValue: sourceKey,
  tags: const [],
);

FavoriteData _pagingData(
  String sourceKey,
  Map<int, List<Comic>> pages,
  Map<int, int> calls,
) => FavoriteData(
  key: sourceKey,
  title: sourceKey,
  multiFolder: false,
  loadComic: (page, [_]) async {
    calls[page] = (calls[page] ?? 0) + 1;
    return Res(pages[page] ?? const [], subData: 2);
  },
  loadNext: null,
);

Future<void> _pumpFrames(WidgetTester tester, {int count = 8}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late NetworkFavoriteCacheManager cache;
  late String databasePath;
  late String oldListMode;
  late String oldComicMode;

  setUpAll(() async {
    await AppTranslation.init();
    tempDir = await Directory.systemTemp.createTemp('venera-favorites-ui-');
    App.dataPath = tempDir.path;
    databasePath =
        '${tempDir.path}${Platform.pathSeparator}network-favorites.db';
    final imageFile = File('${tempDir.path}${Platform.pathSeparator}cover.png');
    await imageFile.writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
    _testImagePath = imageFile.path;
    cache = NetworkFavoriteCacheManager();
    await cache.init(databasePath: databasePath, migrateLegacy: false);
    oldListMode = appdata.settings['comicListDisplayMode'] as String;
    oldComicMode = appdata.settings['comicDisplayMode'] as String;
    appdata.settings['comicListDisplayMode'] = 'paging';
    appdata.settings['comicDisplayMode'] = 'detailed';
  });

  setUp(() {
    cache.clearAllCache();
  });

  tearDownAll(() async {
    appdata.settings['comicListDisplayMode'] = oldListMode;
    appdata.settings['comicDisplayMode'] = oldComicMode;
    await judgmentStateRepository.close();
    cache.close();
    try {
      await tempDir.delete(recursive: true);
    } on PathAccessException {
      // sqlite3 can release its Windows file handle just after test teardown.
    }
  });

  Future<void> pumpSource(
    WidgetTester tester,
    FavoriteData data,
    PageStorageBucket bucket, {
    Key? key,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        builder: (_, child) => OverlayWidget(child!),
        home: Scaffold(
          body: PageStorage(
            bucket: bucket,
            child: NetworkFavoritePage(key: key, data: data),
          ),
        ),
      ),
    );
    await _pumpFrames(tester);
  }

  Future<void> showPageTwo(WidgetTester tester) async {
    expect(find.text('Page 1 / 2'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await _pumpFrames(tester);
    expect(find.text('Page 2 / 2'), findsOneWidget);
  }

  Future<void> showCursorPageTwo(WidgetTester tester) async {
    expect(find.text('Page 1 / ?'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await _pumpFrames(tester);
    expect(find.text('Page 2 / ?'), findsOneWidget);
  }

  Future<void> storeDetectedUpdate(String source, String comic) async {
    await judgmentStateRepository.applyBatch([
      JudgmentState(
        sourceKey: source,
        comicId: comic,
        lastDecision: JudgmentConclusion.changed,
        lastReason: JudgmentReason.different,
        decidedAtMs: 1,
        hasNewUpdate: true,
      ),
    ]);
  }

  testWidgets('favorites show a detected update in both cover layouts', (
    tester,
  ) async {
    const source = 'detected-update-ui';
    const longTitle =
        'A very long comic title that keeps wrapping after its update dot';
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 740);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.runAsync(() => storeDetectedUpdate(source, 'changed'));
    final pages = {
      1: <Comic>[
        Comic.fromJson({
          ..._comic(source, 'changed').toJson(),
          'title': longTitle,
        }, source),
        _comic(source, 'unchanged'),
      ],
    };
    final data = _pagingData(source, pages, {});
    addTearDown(() => appdata.settings['comicDisplayMode'] = 'detailed');
    for (final mode in ['detailed', 'brief']) {
      appdata.settings['comicDisplayMode'] = mode;
      await pumpSource(tester, data, PageStorageBucket(), key: UniqueKey());
      expect(find.text('NEW'), findsOneWidget);
      final title = tester.widget<Text>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              widget.textSpan?.toPlainText(includePlaceholders: false) ==
                  longTitle,
        ),
      );
      final firstSpan = (title.textSpan! as TextSpan).children!.first;
      expect(firstSpan, isA<WidgetSpan>());
      expect((firstSpan as WidgetSpan).alignment, PlaceholderAlignment.middle);
      final tiles = tester.widgetList<ComicTile>(find.byType(ComicTile));
      expect(
        tiles
            .where((tile) => tile.showUpdateRibbon)
            .map((tile) => tile.comic.id),
        ['changed'],
      );
    }
  });

  testWidgets('source unread badges also apply to cached favorite search', (
    tester,
  ) async {
    const sourceKey = 'source-unread-update-ui';
    const folder = NetworkFavoriteFolderRef(sourceKey: sourceKey, folderId: '');
    final data = FavoriteData(
      key: sourceKey,
      title: sourceKey,
      multiFolder: false,
      loadComic: (_, [folder]) async => throw StateError('Legacy page load'),
      loadNext: null,
      loadCachePage: (_, _, _) async => Res(
        FavoriteCachePage(
          [
            _comic(sourceKey, 'book-updated'),
            _comic(sourceKey, 'book-read'),
            _comic(sourceKey, 'book-unknown'),
          ],
          1,
          3,
          sourceUnread: const {'book-updated': true, 'book-read': false},
        ),
      ),
    );
    final source = makeScanTestSource(
      sourceKey,
      favoriteData: data,
      scan: ScanCapabilities.supported(
        primary: ScanProducer.collection,
        collection: ScanCapability.collection(
          (_, _, _) async => const {},
          evidenceSchema: '{"sourceunread":"is_new"}',
        ),
      ),
    );
    ComicSourceManager().add(source);
    addTearDown(() => ComicSourceManager().remove(sourceKey));
    await tester.runAsync(() async {
      await storeDetectedUpdate(sourceKey, 'book-read');
      await storeDetectedUpdate(sourceKey, 'book-unknown');
      await cache
          .cacheAllPages(data, folder, isCanceled: () => false)
          .drain<void>();
    });
    await pumpSource(tester, data, PageStorageBucket());
    expect(find.text('NEW'), findsOneWidget);
    await tester.tap(find.byTooltip('Search'));
    await _pumpFrames(tester);
    await tester.enterText(find.byType(TextField), 'book');
    await _pumpFrames(tester);
    expect(find.text('NEW'), findsOneWidget);
    final tiles = tester.widgetList<ComicTile>(find.byType(ComicTile));
    expect(
      tiles.where((tile) => tile.showUpdateRibbon).map((tile) => tile.comic.id),
      ['book-updated'],
    );
  });

  testWidgets('a failed cache batch shows one warning and keeps the snapshot', (
    tester,
  ) async {
    const source = 'favorites-warning';
    const folder = NetworkFavoriteFolderRef(sourceKey: source, folderId: '');
    const warning = 'Could not cache favorites. Try again later.';
    final calls = <int>[];
    final failedPage = Completer<void>();
    final latePage = Completer<void>();
    var refreshing = false;
    final data = FavoriteData(
      key: source,
      title: source,
      multiFolder: false,
      loadComic: (_, [folder]) async => throw StateError('Legacy page load'),
      loadNext: null,
      loadCachePage: (page, _, _) async {
        calls.add(page);
        if (refreshing && (page == 2 || page == 5)) {
          await (page == 2 ? latePage : failedPage).future;
          throw const SocketException('Connection lost');
        }
        final id = '${refreshing ? 'new' : 'old'}-$page';
        return Res(FavoriteCachePage([_comic(source, id)], 6, 6));
      },
    );
    await tester.runAsync(
      () => cache
          .cacheAllPages(data, folder, isCanceled: () => false)
          .drain<void>(),
    );
    final published = cache.getFullCacheStatus(folder).completedAt;
    calls.clear();
    refreshing = true;
    await pumpSource(tester, data, PageStorageBucket());
    cache.collections.settleNow();
    await _pumpFrames(tester);
    expect(calls, [1, 2, 3, 4, 5]);

    failedPage.complete();
    await _pumpFrames(tester);
    expect(find.text(warning), findsOneWidget);
    expect(cache.getFullCacheStatus(folder).completedAt, published);
    expect(cache.getCachedPage(folder, 1)!.comics.single.id, 'old-1');

    latePage.complete();
    await _pumpFrames(tester);
    expect(find.text(warning), findsOneWidget);
    expect(calls, [1, 2, 3, 4, 5]);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text(warning), findsNothing);
  });

  testWidgets(
    'collection resume keeps its page and an external addition reopens its homepage',
    (tester) async {
      const source = 'atomic-favorites-ui';
      const folder = NetworkFavoriteFolderRef(sourceKey: source, folderId: '');
      var ids = ['first-book', 'second-book'];
      final calls = <int>[];
      final data = FavoriteData(
        key: source,
        title: source,
        multiFolder: false,
        loadComic: (_, [folder]) async => throw StateError('Legacy page load'),
        loadNext: null,
        loadCachePage: (page, _, total) async {
          calls.add(page);
          return Res(
            FavoriteCachePage(
              [_comic(source, ids[page - 1])],
              ids.length,
              ids.length,
            ),
          );
        },
      );
      await tester.runAsync(
        () => cache
            .cacheAllPages(data, folder, isCanceled: () => false)
            .drain<void>(),
      );
      calls.clear();
      final bucket = PageStorageBucket();
      await pumpSource(tester, data, bucket, key: UniqueKey());
      await showPageTwo(tester);
      expect(calls, [1]);

      final detail = App.rootNavigatorKey.currentState!.push<void>(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('detail'))),
      );
      await tester.pumpAndSettle();
      cache.collections.recordChange(folder, 'second-book', false, null);
      App.rootNavigatorKey.currentState!.pop();
      await detail;
      await tester.pumpAndSettle();
      expect(find.text('Page 2 / 2'), findsOneWidget);
      expect(find.text('second-book'), findsNothing);
      expect(calls, [1]);

      final b = _pagingData('other-favorites-ui', {
        1: [_comic('other-favorites-ui', 'other-book')],
      }, {});
      await pumpSource(tester, b, bucket, key: UniqueKey());
      cache.collections.recordChange(
        folder,
        'new-book',
        true,
        _comic(source, 'new-book'),
      );
      ids = ['first-book', 'new-book'];
      await pumpSource(tester, data, bucket, key: UniqueKey());
      expect(find.text('Page 1 / 2'), findsOneWidget);
      expect(find.text('new-book'), findsOneWidget);
      expect(calls, [1, 1]);
      await tester.pump(const Duration(milliseconds: 420));
      await _pumpFrames(tester);
      expect(calls, [1, 1, 2]);
      expect(find.text('Page 1 / 2'), findsOneWidget);
      expect(find.text('new-book'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'cache notification keeps page two and explicit refresh targets it',
    (tester) async {
      final sourceKey = 'cache-notification-source';
      final calls = <int, int>{};
      final data = _pagingData(sourceKey, {
        1: [_comic(sourceKey, 'page-one')],
        2: [_comic(sourceKey, 'page-two')],
      }, calls);
      final folder = NetworkFavoriteFolderRef(
        sourceKey: sourceKey,
        folderId: '',
        title: sourceKey,
      );
      await cache.refreshPage(data, folder, 1);
      await cache.refreshPage(data, folder, 2);
      calls.clear();

      final bucket = PageStorageBucket();
      await pumpSource(tester, data, bucket);
      await showPageTwo(tester);
      expect(find.text('page-two'), findsOneWidget);

      final db = sqlite3.open(databasePath);
      db.execute(
        '''UPDATE favorite_pages SET updated_at = 0
           WHERE source_key = ? AND folder_id = ? AND page_index = 1''',
        [sourceKey, ''],
      );
      db.dispose();
      cache.notifyCacheChanged();
      await _pumpFrames(tester);

      expect(find.text('Page 2 / 2'), findsOneWidget);
      expect(find.text('page-two'), findsOneWidget);
      expect(calls, isEmpty);

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();
      expect(find.text('Page 2 / 2'), findsOneWidget);
      expect(find.text('page-two'), findsOneWidget);
      expect(calls[2], 1);
      expect(calls[1], isNull);
    },
  );

  testWidgets('clearing the cache discards stored pages and reloads page one', (
    tester,
  ) async {
    final sourceKey = 'clear-generation-source';
    final calls = <int, int>{};
    final data = _pagingData(sourceKey, {
      1: [_comic(sourceKey, 'fresh-page-one')],
      2: [_comic(sourceKey, 'stale-page-two')],
    }, calls);
    final folder = NetworkFavoriteFolderRef(
      sourceKey: sourceKey,
      folderId: '',
      title: sourceKey,
    );
    await cache.refreshPage(data, folder, 1);
    await cache.refreshPage(data, folder, 2);
    calls.clear();

    final bucket = PageStorageBucket();
    await pumpSource(tester, data, bucket);
    await showPageTwo(tester);
    expect(find.text('stale-page-two'), findsOneWidget);

    final generation = cache.cacheGeneration;
    cache.clearAllCache();
    expect(cache.cacheGeneration, generation + 1);
    await _pumpFrames(tester, count: 12);

    expect(find.text('Page 1 / 2'), findsOneWidget);
    expect(find.text('fresh-page-one'), findsOneWidget);
    expect(find.text('stale-page-two'), findsNothing);
    expect(calls[1], 1);
    expect(calls[2], isNull);
  });

  testWidgets(
    'same source and folder restores its page while another source is isolated',
    (tester) async {
      final sourceA = 'storage-source-a';
      final sourceB = 'storage-source-b';
      final callsA = <int, int>{};
      final callsB = <int, int>{};
      final dataA = _pagingData(sourceA, {
        1: [_comic(sourceA, 'a-one')],
        2: [_comic(sourceA, 'a-two')],
      }, callsA);
      final dataB = _pagingData(sourceB, {
        1: [_comic(sourceB, 'b-one')],
        2: [_comic(sourceB, 'b-two')],
      }, callsB);
      final folderA = NetworkFavoriteFolderRef(
        sourceKey: sourceA,
        folderId: '',
        title: sourceA,
      );
      final folderB = NetworkFavoriteFolderRef(
        sourceKey: sourceB,
        folderId: '',
        title: sourceB,
      );
      await cache.refreshPage(dataA, folderA, 1);
      await cache.refreshPage(dataA, folderA, 2);
      await cache.refreshPage(dataB, folderB, 1);
      await cache.refreshPage(dataB, folderB, 2);
      callsA.clear();
      callsB.clear();

      final bucket = PageStorageBucket();
      await pumpSource(tester, dataA, bucket, key: UniqueKey());
      await showPageTwo(tester);
      expect(find.text('a-two'), findsOneWidget);

      await pumpSource(tester, dataB, bucket, key: UniqueKey());
      expect(find.text('Page 1 / 2'), findsOneWidget);
      expect(find.text('b-one'), findsOneWidget);
      expect(find.text('a-two'), findsNothing);

      await pumpSource(tester, dataA, bucket, key: UniqueKey());
      expect(find.text('Page 2 / 2'), findsOneWidget);
      expect(find.text('a-two'), findsOneWidget);
      expect(callsA, isEmpty);
      expect(callsB, isEmpty);
    },
  );

  testWidgets('search results use scroll storage separate from paging state', (
    tester,
  ) async {
    const sourceKey = 'search-storage-source';
    final calls = <int, int>{};
    final data = _pagingData(sourceKey, {
      1: [_comic(sourceKey, 'search-target')],
    }, calls);
    final folder = NetworkFavoriteFolderRef(
      sourceKey: sourceKey,
      folderId: '',
      title: sourceKey,
    );
    await cache.refreshPage(data, folder, 1);

    await pumpSource(tester, data, PageStorageBucket());
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.enterText(find.byType(TextField), 'target');
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
    );
    expect(tester.testTextInput.isVisible, isTrue);
    expect(find.text('search-target'), findsOneWidget);
  });

  testWidgets(
    'main navigation preserves cached favorite search after opening detail',
    (tester) async {
      const sourceKey = 'main-navigation-search-source';
      final calls = <int, int>{};
      final data = _pagingData(sourceKey, {
        1: [_comic(sourceKey, 'search-target')],
      }, calls);
      final folder = NetworkFavoriteFolderRef(
        sourceKey: sourceKey,
        folderId: '',
        title: sourceKey,
      );
      await cache.refreshPage(data, folder, 1);

      final observer = NaviObserver();
      final navigatorKey = GlobalKey<NavigatorState>();
      App.mainNavigatorKey = navigatorKey;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: NaviPane(
            paneItems: [
              PaneItemEntry(
                label: 'Favorites',
                icon: Icons.favorite_border,
                activeIcon: Icons.favorite,
              ),
            ],
            paneActions: const [],
            pageBuilder: (_) => NetworkFavoritePage(data: data),
            observer: observer,
            navigatorKey: navigatorKey,
          ),
        ),
      );
      await _pumpFrames(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'target');
      await _pumpFrames(tester);
      expect(find.text('search-target'), findsOneWidget);

      final detailRoute = navigatorKey.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (context) => Scaffold(
            appBar: AppBar(
              leading: IconButton(
                key: const ValueKey('detail-back'),
                onPressed: () => Navigator.maybePop(context),
                icon: const Icon(Icons.arrow_back),
              ),
              title: const Text('detail'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('detail'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('detail-back')));
      await detailRoute;
      await _pumpFrames(tester, count: 20);

      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'target',
      );
      expect(find.text('search-target'), findsOneWidget);

      final secondDetailRoute = navigatorKey.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('detail-again')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('detail-again'), findsOneWidget);
      navigatorKey.currentState!.pop();
      await secondDetailRoute;
      await _pumpFrames(tester, count: 20);

      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'target',
      );
      expect(find.text('search-target'), findsOneWidget);
    },
  );

  testWidgets(
    'cursor page one backfill preserves page two and its next cursor',
    (tester) async {
      const sourceKey = 'cursor-backfill-source';
      final previousBlockedWords = appdata.settings['blockedWords'];
      appdata.settings['blockedWords'] = ['cursor-page'];
      addTearDown(
        () => appdata.settings['blockedWords'] = previousBlockedWords,
      );
      final calls = <String?>[];
      var rootCalls = 0;
      var holdRootRefresh = false;
      final rootRefreshGate = Completer<void>();
      final data = FavoriteData(
        key: sourceKey,
        title: sourceKey,
        multiFolder: false,
        loadComic: null,
        loadNext: (token, [_]) async {
          calls.add(token);
          if (token == null) {
            rootCalls++;
            if (holdRootRefresh) await rootRefreshGate.future;
            final nextToken = rootCalls == 1 ? 'cursor-1' : 'cursor-1-new';
            return Res(<Comic>[
              _comic(sourceKey, 'cursor-page-1'),
            ], subData: nextToken);
          }
          if (token == 'cursor-1') {
            return Res(<Comic>[
              _comic(sourceKey, 'cursor-page-2'),
            ], subData: 'cursor-2');
          }
          if (token == 'cursor-1-new') {
            return Res(<Comic>[
              _comic(sourceKey, 'cursor-page-2-refresh'),
            ], subData: 'cursor-2');
          }
          if (token == 'cursor-2') {
            return Res(<Comic>[_comic(sourceKey, 'cursor-page-3')]);
          }
          return Res.error('unexpected cursor: $token');
        },
      );
      final folder = NetworkFavoriteFolderRef(
        sourceKey: sourceKey,
        folderId: '',
        title: sourceKey,
      );
      await cache.refreshNextPage(data, folder, null);
      await cache.refreshNextPage(data, folder, 'cursor-1');
      calls.clear();
      holdRootRefresh = true;

      final db = sqlite3.open(databasePath);
      db.execute(
        '''UPDATE favorite_pages SET updated_at = 0
           WHERE source_key = ? AND folder_id = ? AND request_token = ?''',
        [sourceKey, '', 'next:'],
      );
      db.dispose();

      final bucket = PageStorageBucket();
      await pumpSource(tester, data, bucket);
      await showCursorPageTwo(tester);
      expect(calls, contains(null));

      rootRefreshGate.complete();
      await _pumpFrames(tester, count: 12);
      expect(find.text('Page 2 / ?'), findsOneWidget);
      expect(calls.where((token) => token == null), hasLength(1));
      expect(calls, isNot(contains('cursor-1-new')));

      await tester.tap(find.text('Next'));
      await _pumpFrames(tester, count: 12);
      expect(find.text('Page 3 / 3'), findsOneWidget);
      expect(calls, contains('cursor-2'));
      expect(calls, isNot(contains('cursor-1-new')));
    },
  );

  testWidgets('cursor page two refresh uses its own request token', (
    tester,
  ) async {
    const sourceKey = 'cursor-refresh-source';
    final previousBlockedWords = appdata.settings['blockedWords'];
    appdata.settings['blockedWords'] = ['refresh-page'];
    addTearDown(() => appdata.settings['blockedWords'] = previousBlockedWords);
    final calls = <String?>[];
    final data = FavoriteData(
      key: sourceKey,
      title: sourceKey,
      multiFolder: false,
      loadComic: null,
      loadNext: (token, [_]) async {
        calls.add(token);
        if (token == null) {
          return Res(<Comic>[
            _comic(sourceKey, 'refresh-page-1'),
          ], subData: 'cursor-1');
        }
        if (token == 'cursor-1') {
          return Res(<Comic>[
            _comic(sourceKey, 'refresh-page-2'),
          ], subData: 'cursor-2');
        }
        return Res.error('unexpected cursor: $token');
      },
    );
    final folder = NetworkFavoriteFolderRef(
      sourceKey: sourceKey,
      folderId: '',
      title: sourceKey,
    );
    await cache.refreshNextPage(data, folder, null);
    await cache.refreshNextPage(data, folder, 'cursor-1');
    calls.clear();

    final bucket = PageStorageBucket();
    await pumpSource(tester, data, bucket);
    await showCursorPageTwo(tester);
    await pumpSource(tester, data, bucket, key: UniqueKey());
    expect(find.text('Page 2 / ?'), findsOneWidget);
    expect(calls, isEmpty);
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(find.text('Page 2 / ?'), findsOneWidget);
    expect(calls, ['cursor-1']);
  });

  testWidgets('snapshot cursor browsing follows only the selected folder', (
    tester,
  ) async {
    const source = 'cursor-snapshot-ui';
    final calls = <(String, String?)>[];
    final previousDelay = cache.collections.settleDelay;
    cache.collections.settleDelay = const Duration(minutes: 1);
    addTearDown(() => cache.collections.settleDelay = previousDelay);
    final data = FavoriteData(
      key: source,
      title: source,
      multiFolder: true,
      loadComic: null,
      loadFolders: ([_]) async =>
          const Res({'0': 'Category A', '1': 'Category B'}),
      loadNext: (_, [folder]) async => throw StateError('Legacy request'),
      loadCacheNext: (next, folder) async {
        calls.add((folder, next));
        return Res(
          FavoriteCachePage(
            [_comic(source, '$folder-${next ?? 'home'}')],
            null,
            null,
            next: next == null ? '$folder-tail' : null,
          ),
        );
      },
    );
    await cache.refreshFolders(data);
    await pumpSource(tester, data, PageStorageBucket());
    await tester.tap(find.text('Category A'));
    await tester.pumpAndSettle();
    expect(find.text('Page 1 / ?'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await _pumpFrames(tester);
    expect(find.text('Page 2 / 2'), findsOneWidget);
    expect(calls, [('0', null), ('0', '0-tail')]);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Category B'));
    await tester.pumpAndSettle();
    expect(calls, [('0', null), ('0', '0-tail'), ('1', null)]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('different favorite folders do not share page storage', (
    tester,
  ) async {
    const sourceKey = 'folder-storage-source';
    final calls = <String, Map<int, int>>{'folder-a': {}, 'folder-b': {}};
    final data = FavoriteData(
      key: sourceKey,
      title: sourceKey,
      multiFolder: true,
      loadComic: (page, [folder]) async {
        final folderId = folder!;
        final folderCalls = calls[folderId]!;
        folderCalls[page] = (folderCalls[page] ?? 0) + 1;
        return Res(<Comic>[
          _comic(sourceKey, '$folderId-page-$page'),
        ], subData: 2);
      },
      loadNext: null,
      loadFolders: ([_]) async =>
          const Res({'folder-a': 'Folder A', 'folder-b': 'Folder B'}),
    );
    await cache.refreshFolders(data);
    final folderA = NetworkFavoriteFolderRef(
      sourceKey: sourceKey,
      folderId: 'folder-a',
      title: 'Folder A',
    );
    final folderB = NetworkFavoriteFolderRef(
      sourceKey: sourceKey,
      folderId: 'folder-b',
      title: 'Folder B',
    );
    await cache.refreshPage(data, folderA, 1);
    await cache.refreshPage(data, folderA, 2);
    await cache.refreshPage(data, folderB, 1);
    await cache.refreshPage(data, folderB, 2);

    final bucket = PageStorageBucket();
    await pumpSource(tester, data, bucket);
    await tester.tap(find.text('Folder A'));
    await tester.pumpAndSettle();
    await showPageTwo(tester);
    expect(find.text('folder-a-page-2'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Folder B'));
    await tester.pumpAndSettle();
    expect(find.text('Page 1 / 2'), findsOneWidget);
    expect(find.text('folder-b-page-1'), findsOneWidget);
    expect(find.text('folder-a-page-2'), findsNothing);

    // Dispose the page before the binding verifies that no image retries are
    // still pending. The providers may already be waiting on their bounded
    // retry delays, so advance fake time far enough for those futures to
    // observe cancellation.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(seconds: 10));
  });
}
