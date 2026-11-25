import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/aggregated_search_page.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/search_page.dart';
import 'package:venera/pages/search_result_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dataDirectory;
  late List<String> loadedQueries;
  late List<String> recordedHistory;
  late Object? previousEnabledSources;

  const sourceKey = 'nhentai';

  ComicSource buildSource(
    String name,
    String key, {
    RegExp? idMatcher,
    LoadComicFunc? loadComicInfo,
  }) => ComicSource(
    name,
    key,
    null,
    null,
    null,
    null,
    const [],
    SearchPageData(null, (keyword, page, options) async {
      loadedQueries.add(keyword);
      return Res(const <Comic>[], subData: 1);
    }, null),
    null,
    loadComicInfo,
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
    idMatcher,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );

  setUpAll(() async {
    await AppTranslation.init();
    dataDirectory = await Directory.systemTemp.createTemp('venera-search-');
    loadedQueries = <String>[];
    recordedHistory = <String>[];
    App.dataPath = dataDirectory.path;
    App.cachePath = dataDirectory.path;
    await HistoryManager().init();
    await NetworkFavoriteCacheManager().init(migrateLegacy: false);
    previousEnabledSources = appdata.settings['enabledSources'];
    appdata.settings['enabledSources'] = [sourceKey];
    appdata.settings['searchSources'] = [sourceKey];
    appdata.settings['defaultSearchTarget'] = sourceKey;
    appdata.settings['autoAddLanguageFilter'] = 'english';
    appdata.settings['comicListDisplayMode'] = 'continuous';

    ComicSourceManager().add(buildSource('Search test source', sourceKey));
  });

  tearDown(() {
    loadedQueries.clear();
    recordedHistory.clear();
    appdata.searchHistory.clear();
  });

  tearDownAll(() async {
    ComicSourceManager().remove(sourceKey);
    appdata.settings['enabledSources'] = previousEnabledSources;
    NetworkFavoriteCacheManager().close();
    HistoryManager().close();
    await dataDirectory.delete(recursive: true);
  });

  String visibleSearchText(WidgetTester tester) {
    return tester.widget<TextField>(find.byType(TextField)).controller!.text;
  }

  Future<void> submitSearch(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> returnToSearchPage(WidgetTester tester) async {
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> pumpSearchPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: SearchPage(onSearchHistoryAdded: recordedHistory.add),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpHomeSearch(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: NaviPane(
          paneItems: [
            PaneItemEntry(
              label: 'Home',
              icon: Icons.home_outlined,
              activeIcon: Icons.home,
            ),
          ],
          paneActions: const [],
          observer: NaviObserver(),
          navigatorKey: GlobalKey(),
          pageBuilder: (_) => Builder(
            builder: (context) => Scaffold(
              body: Container(
                height: 46,
                width: double.infinity,
                margin: const EdgeInsets.all(8),
                child: SearchEntryHero(
                  onTap: () => context.to(
                    () => SearchPage(
                      fromHome: true,
                      onSearchHistoryAdded: recordedHistory.add,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('unmounted controller keeps its current text', () {
    final controller = SearchBarController(currentText: 'first');

    expect(controller.text, 'first');
    controller.text = 'second';
    expect(controller.currentText, 'second');
    expect(controller.text, 'second');
  });

  testWidgets('home search capsule flattens and fades in both directions', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 780);
    addTearDown(tester.view.reset);
    await pumpHomeSearch(tester);

    final entry = find.byType(SearchEntryHero);
    final homeRect = tester.getRect(entry);
    final color = Theme.of(
      tester.element(entry),
    ).colorScheme.surfaceContainerHigh;
    final flight = find.byWidgetPredicate(
      (widget) =>
          widget is Material &&
          widget.animationDuration == Duration.zero &&
          widget.color == color &&
          widget.borderRadius is BorderRadius,
    );
    double radius() =>
        (tester.widget<Material>(flight).borderRadius! as BorderRadius)
            .topLeft
            .x;
    double opacity() => tester
        .widget<Opacity>(
          find.ancestor(of: flight, matching: find.byType(Opacity)).first,
        )
        .opacity;

    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.getSize(flight).width, inExclusiveRange(homeRect.width, 360));
    expect(radius(), closeTo(16, 1));
    expect(opacity(), closeTo(.5, .04));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration!.contentPadding, isNull);
    expect(tester.getSize(entry).width, 360);
    expect(
      find.descendant(of: entry, matching: find.byType(Material)),
      findsNothing,
    );
    expect(flight, findsNothing);

    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(radius(), closeTo(16, 1));
    expect(opacity(), closeTo(.5, .04));
    await tester.pump(const Duration(milliseconds: 75));
    expect(radius(), greaterThan(24));
    expect(opacity(), greaterThan(.75));
    await tester.pumpAndSettle();
    expect(tester.getRect(entry), homeRect);
    expect(flight, findsNothing);
  });

  testWidgets(
    'home search accepts input after a single tap and drops focus on submit',
    (tester) async {
      await pumpHomeSearch(tester);
      await tester.tap(find.byType(SearchEntryHero));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.testTextInput.isVisible, isTrue);
      tester.testTextInput.enterText('immediate query');
      await tester.pumpAndSettle();
      expect(visibleSearchText(tester), 'immediate query');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      await returnToSearchPage(tester);
      expect(visibleSearchText(tester), 'immediate query');
      expect(tester.testTextInput.isVisible, isFalse);
    },
  );

  testWidgets(
    'AppSearchBar keeps programmatic, typed, and clear text aligned',
    (tester) async {
      var searches = 0;
      final controller = SearchBarController(onSearch: (_) => searches++);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AppSearchBar(controller: controller)),
        ),
      );

      controller.text = 'programmatic';
      await tester.pump();
      expect(visibleSearchText(tester), 'programmatic');
      expect(controller.currentText, 'programmatic');
      expect(searches, 0);

      await tester.enterText(find.byType(TextField), 'typed');
      expect(controller.text, 'typed');
      expect(controller.currentText, 'typed');

      await tester.tap(find.byIcon(Icons.clear));
      await tester.pump();
      expect(visibleSearchText(tester), isEmpty);
      expect(controller.text, isEmpty);
      expect(controller.currentText, isEmpty);
      expect(searches, 0);
    },
  );

  testWidgets('SliverSearchBar keeps user edits in its controller', (
    tester,
  ) async {
    final controller = SearchBarController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [SliverSearchBar(controller: controller)],
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'typed');
    expect(controller.text, 'typed');
    expect(controller.currentText, 'typed');

    controller.text = 'programmatic';
    await tester.pump();
    expect(visibleSearchText(tester), 'programmatic');
    expect(controller.currentText, 'programmatic');
  });

  testWidgets('ordinary search returns the last committed query', (
    tester,
  ) async {
    await pumpSearchPage(tester);

    await submitSearch(tester, 'first');
    expect(find.byType(SearchResultPage), findsOneWidget);
    expect(loadedQueries.last, 'first language:english');
    expect(recordedHistory, ['first language:english']);

    await submitSearch(tester, 'second');
    expect(loadedQueries.last, 'second language:english');
    expect(recordedHistory, [
      'first language:english',
      'second language:english',
    ]);

    await returnToSearchPage(tester);
    expect(visibleSearchText(tester), 'second');
  });

  testWidgets('pasted JM numbers offer a direct work lookup', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final loadedComicIds = <String>[];
    ComicSourceManager().add(
      buildSource(
        'JM test source',
        'jm',
        idMatcher: RegExp(r'^(?:[0-9]+|jm[0-9]+)$'),
        loadComicInfo: (id) async {
          loadedComicIds.add(id);
          return Res(
            ComicDetails.fromJson({
              'title': 'Fixture $id',
              'cover': '',
              'tags': <String, List<String>>{},
              'chapters': {'chapter': 'Chapter'},
              'comicId': id,
              'sourceKey': 'jm',
              'isFavorite': false,
            }),
          );
        },
      ),
    );
    appdata.settings['enabledSources'] = [sourceKey, 'jm'];
    addTearDown(() {
      ComicSourceManager().remove('jm');
      appdata.settings['enabledSources'] = [sourceKey];
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: const OverlayWidget(SearchPage()),
      ),
    );
    await tester.pumpAndSettle();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final openComic = find.text("${'Open comic'.tl}: JM test source");
    final field = find.byType(TextField);

    for (final (input, viaInputMethod) in const [
      ('123456', false),
      ('JM123456', false),
      ('jm123456', true),
      ('  Jm123456  ', false),
    ]) {
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        return switch (call.method) {
          'Clipboard.getData' => {'text': input},
          'Clipboard.hasStrings' => {'value': true},
          _ => null,
        };
      });
      await tester.enterText(field, '');
      if (viaInputMethod) {
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: input,
            selection: TextSelection.collapsed(offset: input.length),
          ),
        );
      } else {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      }
      await tester.pumpAndSettle();
      expect(visibleSearchText(tester), input);
      expect(openComic, findsOneWidget);
      expect(find.text('Extract'.tl), findsNothing);

      await tester.tap(openComic);
      await tester.pumpAndSettle();
      final page = tester.widget<ComicPage>(find.byType(ComicPage));
      expect(page.sourceKey, 'jm');
      expect(page.id, '123456');
      expect(loadedComicIds.last, '123456');
      App.rootNavigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
    }
    expect(loadedComicIds, List.filled(4, '123456'));

    appdata.settings['enabledSources'] = [sourceKey];
    await tester.enterText(field, 'JM123456');
    await tester.pumpAndSettle();
    expect(openComic, findsNothing);
  });

  testWidgets('unsubmitted result-page draft does not overwrite parent', (
    tester,
  ) async {
    await pumpSearchPage(tester);

    await submitSearch(tester, 'first');
    await tester.enterText(find.byType(TextField), 'draft');
    await tester.pump();

    await returnToSearchPage(tester);
    expect(visibleSearchText(tester), 'first');
  });

  testWidgets('aggregated search returns its last committed query', (
    tester,
  ) async {
    appdata.settings['defaultSearchTarget'] = '_aggregated_';
    await pumpSearchPage(tester);

    await submitSearch(tester, 'first');
    expect(find.byType(AggregatedSearchPage), findsOneWidget);

    await submitSearch(tester, 'second');
    await returnToSearchPage(tester);

    expect(visibleSearchText(tester), 'second');
  });
}
