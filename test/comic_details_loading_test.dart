import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/search_result_page.dart';
import 'package:venera/pages/semantic_search_page.dart';
import 'package:venera/utils/translations.dart';

class _DetailFixture {
  _DetailFixture({
    required this.sourceKey,
    required this.comicId,
    required this.loadFolders,
    this.chapters = const {'ep': 'Chapter'},
    this.readChapterIds,
  });

  final String sourceKey;

  final String comicId;

  final Future<Res<Map<String, String>>> Function(String comicId) loadFolders;
  final Map<String, Object> chapters;
  final List<String>? readChapterIds;

  ComicSource buildSource() {
    final coverPath =
        'file://${Directory.current.path}${Platform.pathSeparator}assets'
        '${Platform.pathSeparator}app_icon.png';
    final favoriteData = FavoriteData(
      key: sourceKey,
      title: 'Favorites',
      multiFolder: true,
      loadComic: null,
      loadNext: null,
      loadFolders: ([String? id]) => loadFolders(id ?? comicId),
    );
    final source = ComicSource(
      'Test source',
      sourceKey,
      null,
      null,
      null,
      favoriteData,
      const [],
      null,
      null,
      (id) async => Res(
        ComicDetails.fromJson({
          'title': 'Comic $id',
          'subtitle': 'Author',
          'cover': coverPath,
          'description': 'Details loaded',
          'tags': <String, List<String>>{},
          'chapters': chapters,
          if (readChapterIds != null) 'readChapterIds': readChapterIds,
          'sourceKey': sourceKey,
          'comicId': id,
          'isFavorite': false,
          'isLiked': false,
        }),
      ),
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
    source.data['account'] = const ['logged-in'];
    return source;
  }
}

Future<void> _pumpDetail(
  WidgetTester tester,
  _DetailFixture fixture, {
  Brightness brightness = Brightness.light,
}) async {
  ComicSourceManager().add(fixture.buildSource());
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: ComicPage(id: fixture.comicId, sourceKey: fixture.sourceKey),
    ),
  );
  await tester.pump();
}

void _expectChapterRead(WidgetTester tester, String title, bool read) {
  final chapter = find.text(title);
  final tile = find.ancestor(of: chapter, matching: find.byType(InkWell)).first;
  final material = find
      .ancestor(of: tile, matching: find.byType(Material))
      .first;
  final check = find.descendant(
    of: tile,
    matching: find.byIcon(Icons.check_rounded),
  );
  final shape =
      tester.widget<Material>(material).shape! as RoundedRectangleBorder;
  final color = Theme.of(tester.element(chapter)).brightness == Brightness.light
      ? Colors.green.shade800
      : Colors.green.shade100;
  expect(shape.side, read ? BorderSide(color: color) : BorderSide.none);
  expect(check, read ? findsOneWidget : findsNothing);
  expect(tester.widget<Text>(chapter).style?.color, isNull);
  expect(tester.widget<InkWell>(tile).onTap, isNotNull);
  if (read) {
    expect(tester.widget<Icon>(check).color, color);
    expect(tester.getCenter(check).dx, greaterThan(tester.getCenter(tile).dx));
    expect(tester.getCenter(check).dy, lessThan(tester.getCenter(tile).dy));
    expect(
      tester.widget<Text>(chapter).semanticsLabel,
      '$title, ${'Already read'.tl}',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    await AppTranslation.init();
    tempDir = await Directory.systemTemp.createTemp('venera-detail-loading-');
    App.dataPath = tempDir.path;
    App.cachePath = tempDir.path;
    await HistoryManager().init();
    await NetworkFavoriteCacheManager().init(
      databasePath: '${tempDir.path}${Platform.pathSeparator}favorites.db',
      migrateLegacy: false,
    );
  });

  for (final sourceSupportsReadStatus in [false, true]) {
    testWidgets(
      'flat chapters preserve local marks with remote status ${sourceSupportsReadStatus ? 'present' : 'absent'}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(380, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final fixture = _DetailFixture(
          sourceKey: 'chapter-status-source-$sourceSupportsReadStatus',
          comicId: 'chapters-$sourceSupportsReadStatus',
          loadFolders: (_) async => const Res({}),
          chapters: const {
            'a': '01',
            'b': 'Source chapter',
            'c': 'Unread chapter',
          },
          readChapterIds: sourceSupportsReadStatus
              ? const ['b', 'unknown']
              : null,
        );
        final model = (await fixture.buildSource().loadComicInfo!(
          fixture.comicId,
        )).data;
        HistoryManager().addHistory(
          History.fromModel(model: model, ep: 1, page: 7, readChapters: {'1'}),
        );

        await _pumpDetail(tester, fixture);
        _expectChapterRead(tester, '01', true);
        _expectChapterRead(tester, 'Source chapter', sourceSupportsReadStatus);
        _expectChapterRead(tester, 'Unread chapter', false);
        await tester.tap(find.byTooltip('Order'.tl));
        await tester.pump();
        _expectChapterRead(tester, '01', true);
        _expectChapterRead(tester, 'Source chapter', sourceSupportsReadStatus);
        _expectChapterRead(tester, 'Unread chapter', false);
        expect(
          find.text('${'Last Reading'.tl}: 01 P7'),
          findsOneWidget,
        );
        final history = HistoryManager().find(model.id, model.comicType)!;
        expect(history.readEpisode, {'1'});
        expect(history.ep, 1);
        expect(history.page, 7);
      },
    );
  }

  testWidgets(
    'grouped chapters combine source and both local history formats',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = _DetailFixture(
        sourceKey: 'grouped-chapter-status-source',
        comicId: 'grouped-chapters',
        loadFolders: (_) async => const Res({}),
        chapters: const {
          'First group': {'a': 'First chapter'},
          'Second group': {
            'b': 'Legacy chapter',
            'c': 'Local chapter',
            'd': 'Source chapter',
            'e': 'Unread chapter',
          },
        },
        readChapterIds: const ['d'],
      );
      final model = (await fixture.buildSource().loadComicInfo!(
        fixture.comicId,
      )).data;
      HistoryManager().addHistory(
        History.fromModel(
          model: model,
          ep: 2,
          page: 7,
          group: 2,
          readChapters: {'2', '2-2'},
        ),
      );

      await _pumpDetail(tester, fixture, brightness: Brightness.dark);
      _expectChapterRead(tester, 'Legacy chapter', true);
      _expectChapterRead(tester, 'Local chapter', true);
      _expectChapterRead(tester, 'Source chapter', true);
      _expectChapterRead(tester, 'Unread chapter', false);
      expect(
        find.text('${'Last Reading'.tl}: Second group Local chapter P7'),
        findsOneWidget,
      );
    },
  );

  testWidgets('details render while loadFolders is pending', (tester) async {
    final folders = Completer<Res<Map<String, String>>>();
    const sourceKey = 'detail-pending-source';
    const comicId = 'pending-comic';
    final fixture = _DetailFixture(
      sourceKey: sourceKey,
      comicId: comicId,
      loadFolders: (_) => folders.future,
    );
    await _pumpDetail(tester, fixture);

    expect(find.text('Comic $comicId'), findsWidgets);
    expect(find.byType(NetworkError), findsNothing);

    folders.complete(const Res({'folder': 'Folder'}, subData: ['folder']));
    await tester.pump();
    await tester.pump();

    expect(
      NetworkFavoriteCacheManager().isFavoriteKnown(sourceKey, comicId),
      isTrue,
    );
  });

  testWidgets('folder refresh errors do not replace the detail body', (
    tester,
  ) async {
    final folders = Completer<Res<Map<String, String>>>();
    const sourceKey = 'detail-error-source';
    const comicId = 'error-comic';
    await _pumpDetail(
      tester,
      _DetailFixture(
        sourceKey: sourceKey,
        comicId: comicId,
        loadFolders: (_) => folders.future,
      ),
    );
    folders.complete(const Res.error('folder request failed'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Comic $comicId'), findsWidgets);
    expect(find.byType(NetworkError), findsNothing);
  });

  testWidgets('disposing before folder refresh completes is safe', (
    tester,
  ) async {
    final folders = Completer<Res<Map<String, String>>>();
    const sourceKey = 'detail-dispose-source';
    const comicId = 'dispose-comic';
    await _pumpDetail(
      tester,
      _DetailFixture(
        sourceKey: sourceKey,
        comicId: comicId,
        loadFolders: (_) => folders.future,
      ),
    );
    await tester.pumpWidget(const SizedBox());
    folders.complete(const Res({'folder': 'Folder'}, subData: ['folder']));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('empty remote membership preserves known favorite', (
    tester,
  ) async {
    const sourceKey = 'detail-known-source';
    const comicId = 'known-comic';
    final cache = NetworkFavoriteCacheManager();
    cache.replaceComicMembership(sourceKey, comicId, const ['old-folder']);
    final folders = Completer<Res<Map<String, String>>>();
    await _pumpDetail(
      tester,
      _DetailFixture(
        sourceKey: sourceKey,
        comicId: comicId,
        loadFolders: (_) => folders.future,
      ),
    );
    folders.complete(const Res({'folder': 'Folder'}, subData: <String>[]));
    await tester.pump();
    await tester.pump();

    expect(cache.isFavoriteKnown(sourceKey, comicId), isTrue);
  });

  testWidgets('empty remote membership clears unknown favorite', (
    tester,
  ) async {
    const sourceKey = 'detail-unknown-source';
    const comicId = 'unknown-comic';
    final folders = Completer<Res<Map<String, String>>>();
    await _pumpDetail(
      tester,
      _DetailFixture(
        sourceKey: sourceKey,
        comicId: comicId,
        loadFolders: (_) => folders.future,
      ),
    );
    folders.complete(const Res({'folder': 'Folder'}, subData: <String>[]));
    await tester.pump();
    await tester.pump();

    expect(
      NetworkFavoriteCacheManager().isFavoriteKnown(sourceKey, comicId),
      isFalse,
    );
  });

  test('loaded comic cover takes priority over the widget placeholder', () {
    expect(
      selectComicCoverUrl(
        '  https://example.com/old.jpg  ',
        '  https://example.com/new.jpg  ',
      ),
      'https://example.com/new.jpg',
    );
    expect(
      selectComicCoverUrl('  https://example.com/old.jpg  ', '   '),
      'https://example.com/old.jpg',
    );
    expect(selectComicCoverUrl('   ', '  '), '');
    expect(selectComicCoverUrl(null, '  '), '');

    final provider = CachedImageProvider(
      selectComicCoverUrl(
        '  https://example.com/old.jpg  ',
        '  https://example.com/new.jpg  ',
      ),
      sourceKey: 'detail-source',
      cid: 'comic-id',
    );
    expect(provider.url, 'https://example.com/new.jpg');
  });

  testWidgets('author search chooses a candidate before navigating', (
    tester,
  ) async {
    const sourceKey = 'detail-author-search-source';
    const comicId = 'author-search-comic';
    final selectedQueries = <String>[];
    final source = ComicSource(
      'Author search source',
      sourceKey,
      null,
      null,
      null,
      null,
      const [],
      SearchPageData(
        null,
        (keyword, page, options) async => const Res(<Comic>[]),
        null,
      ),
      null,
      (id) async => Res(
        ComicDetails.fromJson({
          'title': 'Author search comic',
          'subtitle': 'Author',
          'cover': '',
          'description': '',
          'tags': <String, List<String>>{
            'artist': ['社团（作者）'],
          },
          'chapters': <String, String>{'chapter': 'Chapter'},
          'sourceKey': sourceKey,
          'comicId': id,
        }),
      ),
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
      (namespace, tag) {
        selectedQueries.add('$namespace:$tag');
        return PageJumpTarget(sourceKey, 'search', {'text': '$namespace:$tag'});
      },
      null,
      null,
      false,
      false,
      null,
      null,
    );
    ComicSourceManager().add(source);
    addTearDown(() => ComicSourceManager().remove(sourceKey));

    final navigatorKey = GlobalKey<NavigatorState>();
    App.mainNavigatorKey = navigatorKey;
    addTearDown(() => App.mainNavigatorKey = null);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: ComicPage(id: comicId, sourceKey: sourceKey),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('社团（作者）'));
    await tester.pumpAndSettle();

    expect(find.text('Choose an author to search'.tl), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('comic-author-copy-candidate-作者')),
    );
    await tester.pumpAndSettle();

    expect(selectedQueries, ['artist:作者']);
    expect(find.byType(SearchResultPage), findsOneWidget);
    final searchField = tester.widget<TextField>(find.byType(TextField));
    expect(searchField.controller!.text, 'artist:作者');
  });

  group('detail tag click five states (feature 008)', () {
    /// Builds a source whose detail tags and `onClickTag` are scripted.
    ComicSource tagSource({
      required String sourceKey,
      required Map<String, List<String>> tags,
      HandleClickTagEvent? handleClickTagEvent,
      SearchFunction? searchLoader,
    }) {
      // A real on-disk cover keeps the shared card widget from starting a
      // network image load, which would leave pending timers in widget tests.
      final coverPath =
          'file://${Directory.current.path}${Platform.pathSeparator}assets'
          '${Platform.pathSeparator}app_icon.png';
      return ComicSource(
        'Tag source',
        sourceKey,
        null,
        null,
        null,
        null,
        const [],
        SearchPageData(null, searchLoader, null),
        null,
        (id) async => Res(
          ComicDetails.fromJson({
            'title': 'Tag comic',
            'subtitle': '',
            'cover': coverPath,
            'description': '',
            'tags': tags,
            'chapters': <String, String>{'chapter': 'Chapter'},
            'sourceKey': sourceKey,
            'comicId': id,
          }),
        ),
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
        handleClickTagEvent,
        null,
        null,
        false,
        false,
        null,
        null,
      );
    }

    Future<GlobalKey<NavigatorState>> pumpTagComic(
      WidgetTester tester,
      ComicSource source,
      String comicId,
    ) async {
      ComicSourceManager().add(source);
      addTearDown(() => ComicSourceManager().remove(source.key));
      final navigatorKey = GlobalKey<NavigatorState>();
      App.mainNavigatorKey = navigatorKey;
      addTearDown(() => App.mainNavigatorKey = null);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: ComicPage(id: comicId, sourceKey: source.key),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      return navigatorKey;
    }

    testWidgets('a missing handler falls back to ordinary search with the raw '
        'field value', (tester) async {
      const sourceKey = 'tag-missing-handler';
      final queries = <String>[];
      final source = tagSource(
        sourceKey: sourceKey,
        tags: <String, List<String>>{
          'Tags': ['  Fate  '],
        },
        handleClickTagEvent: null,
        searchLoader: (keyword, page, options) async {
          queries.add(keyword);
          return const Res(<Comic>[]);
        },
      );
      await pumpTagComic(tester, source, 'tag-comic-missing');

      await tester.tap(find.text('  Fate  '));
      await tester.pumpAndSettle();

      expect(find.byType(SearchResultPage), findsOneWidget);
      expect(queries, [
        '  Fate  ',
      ], reason: 'the fallback must use the raw field value, untrimmed');
      final searchField = tester.widget<TextField>(find.byType(TextField));
      expect(searchField.controller!.text, '  Fate  ');
    });

    testWidgets('an explicit null handler is a no-op', (tester) async {
      const sourceKey = 'tag-explicit-null';
      final source = tagSource(
        sourceKey: sourceKey,
        tags: <String, List<String>>{
          'Tags': ['Silent'],
        },
        handleClickTagEvent: (namespace, tag) => null,
      );
      await pumpTagComic(tester, source, 'tag-comic-null');

      await tester.tap(find.text('Silent'));
      await tester.pumpAndSettle();

      expect(find.byType(SearchResultPage), findsNothing);
      expect(find.byType(SemanticSearchPage), findsNothing);
      expect(find.byType(ComicPage), findsOneWidget);
    });

    testWidgets('a tagSearch target opens the semantic page with the opaque '
        'keyword from the target source', (tester) async {
      const sourceKey = 'tag-navigation-source';
      final seen = <String>[];
      final source = tagSource(
        sourceKey: sourceKey,
        tags: <String, List<String>>{
          'Tags': ['Fate Series'],
        },
        handleClickTagEvent: (namespace, tag) {
          seen.add('$namespace|$tag');
          return PageJumpTarget(sourceKey, 'tagSearch', {'keyword': tag});
        },
      );
      await pumpTagComic(tester, source, 'tag-comic-search');

      await tester.tap(find.text('Fate Series'));
      await tester.pumpAndSettle();

      expect(seen, ['Tags|Fate Series']);
      expect(find.byType(SemanticSearchPage), findsOneWidget);
      final page = tester.widget<SemanticSearchPage>(
        find.byType(SemanticSearchPage),
      );
      expect(page.sourceKey, sourceKey);
      expect(page.value, 'Fate Series');
      expect(find.textContaining('Tag: Fate Series'), findsOneWidget);
      // The semantic page never offers a search box.
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('the legacy action shape keeps its opaque keyword', (
      tester,
    ) async {
      const sourceKey = 'tag-legacy-shape';
      final source = tagSource(
        sourceKey: sourceKey,
        tags: <String, List<String>>{
          'Tags': ['Legacy Tag'],
        },
        handleClickTagEvent: (namespace, tag) => PageJumpTarget.parse(
          sourceKey,
          {'action': 'tagSearch', 'keyword': tag},
        ),
      );
      await pumpTagComic(tester, source, 'tag-comic-legacy');

      await tester.tap(find.text('Legacy Tag'));
      await tester.pumpAndSettle();

      expect(find.byType(SemanticSearchPage), findsOneWidget);
      final page = tester.widget<SemanticSearchPage>(
        find.byType(SemanticSearchPage),
      );
      expect(page.value, 'Legacy Tag');
    });

    testWidgets('a non-author namespace never opens the candidate menu', (
      tester,
    ) async {
      const sourceKey = 'tag-non-author';
      final seen = <String>[];
      final source = tagSource(
        sourceKey: sourceKey,
        tags: <String, List<String>>{
          'Tags': ['社团（作者）'],
        },
        handleClickTagEvent: (namespace, tag) {
          seen.add(tag);
          return null;
        },
      );
      await pumpTagComic(tester, source, 'tag-comic-non-author');

      await tester.tap(find.text('社团（作者）'));
      await tester.pumpAndSettle();

      expect(find.text('Choose an author to search'.tl), findsNothing);
      expect(seen, ['社团（作者）']);
    });

    testWidgets('cancelling the author menu never navigates', (tester) async {
      const sourceKey = 'tag-author-cancel';
      final seen = <String>[];
      final source = tagSource(
        sourceKey: sourceKey,
        tags: <String, List<String>>{
          'artist': ['社团（作者）'],
        },
        handleClickTagEvent: (namespace, tag) {
          seen.add(tag);
          return PageJumpTarget(sourceKey, 'search', {'text': tag});
        },
      );
      await pumpTagComic(tester, source, 'tag-comic-author-cancel');

      await tester.tap(find.text('社团（作者）'));
      await tester.pumpAndSettle();
      expect(find.text('Choose an author to search'.tl), findsOneWidget);

      // Dismiss the chooser without selecting a candidate.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      expect(seen, isEmpty);
      expect(find.byType(SearchResultPage), findsNothing);
      expect(find.byType(ComicPage), findsOneWidget);
    });
  });
}
