import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/utils/translations.dart';

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
  });
}
