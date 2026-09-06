import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/utils/app_links.dart';
import 'package:venera/utils/translations.dart';

ComicSource _source({LinkHandler? linkHandler}) => ComicSource(
  'Test source',
  'test_source',
  null,
  null,
  null,
  null,
  [
    ExplorePageData(
      'configured',
      ExplorePageType.multiPageComicList,
      null,
      null,
      null,
      null,
    ),
  ],
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  'test_source.js',
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
  linkHandler,
  false,
  false,
  null,
  null,
);

void main() {
  setUpAll(AppTranslation.init);

  testWidgets(
    'disabled sources remain selectable and enabling only changes preference',
    (tester) async {
      final source = _source();
      final manager = ComicSourceManager();
      manager.add(source);
      final oldPages = appdata.settings['explore_pages'];
      appdata.settings['explore_pages'] = ['configured'];
      addTearDown(() {
        appdata.settings['explore_pages'] = oldPages;
        manager.remove(source.key);
      });
      final preferences = SourcePreferences(initial: []);

      await tester.pumpWidget(
        MaterialApp(home: ComicSourcePage(preferences: preferences)),
      );
      final switchFinder = find.byKey(const Key('source-switch-test_source'));
      expect(switchFinder, findsOneWidget);
      expect(tester.widget<Switch>(switchFinder).value, isFalse);

      await tester.tap(switchFinder);
      await tester.pump();

      expect(preferences.enabledSources, ['test_source']);
      expect(tester.widget<Switch>(switchFinder).value, isTrue);
      preferences.dispose();
    },
  );

  test('disabled external links only prompt for source management', () async {
    final source = _source(
      linkHandler: LinkHandler(['example.com'], (_) => 'comic-1'),
    );
    final manager = ComicSourceManager();
    manager.add(source);
    final oldEnabled = appdata.settings['enabledSources'];
    appdata.settings['enabledSources'] = <String>[];
    addTearDown(() {
      appdata.settings['enabledSources'] = oldEnabled;
      manager.remove(source.key);
    });
    String? message;

    final handled = await handleAppLink(
      Uri.parse('https://example.com/comic/1'),
      onDisabledSource: (value) => message = value,
    );

    expect(handled, isTrue);
    expect(message, isNotNull);
  });
}
