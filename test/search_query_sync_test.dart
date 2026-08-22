import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/aggregated_search_page.dart';
import 'package:venera/pages/search_page.dart';
import 'package:venera/pages/search_result_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dataDirectory;
  late List<String> loadedQueries;
  late List<String> recordedHistory;

  const sourceKey = 'nhentai';

  setUpAll(() async {
    await AppTranslation.init();
    dataDirectory = await Directory.systemTemp.createTemp('venera-search-');
    loadedQueries = <String>[];
    recordedHistory = <String>[];
    App.dataPath = dataDirectory.path;
    appdata.settings['searchSources'] = [sourceKey];
    appdata.settings['defaultSearchTarget'] = sourceKey;
    appdata.settings['autoAddLanguageFilter'] = 'english';
    appdata.settings['comicListDisplayMode'] = 'continuous';

    final source = ComicSource(
      'Search test source',
      sourceKey,
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
    ComicSourceManager().add(source);
  });

  tearDown(() {
    loadedQueries.clear();
    recordedHistory.clear();
    appdata.searchHistory.clear();
  });

  tearDownAll(() async {
    ComicSourceManager().remove(sourceKey);
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

  test('unmounted controller keeps its current text', () {
    final controller = SearchBarController(currentText: 'first');

    expect(controller.text, 'first');
    controller.text = 'second';
    expect(controller.currentText, 'second');
    expect(controller.text, 'second');
  });

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
