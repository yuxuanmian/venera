import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/categories_page.dart';
import 'package:venera/pages/explore_page.dart';
import 'package:venera/pages/main_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  setUp(() {
    appdata.settings['categories'] = <String>[];
    appdata.settings['explore_pages'] = <String>[];
    appdata.settings['comicListDisplayMode'] = 'paging';
    appdata.implicitData.remove('categoryBrowseSources');
    appdata.implicitData.remove('categorySourceOrder');
  });

  tearDown(() => ComicSourceManager().installPreparedSources(const []));

  testWidgets(
    'old Explore startup restores its source and opens only the selected feed',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 740));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final requests = <String>[];
      final slowPage = Completer<Res<List<ExplorePagePart>>>();
      final alpha = _source(
        'alpha',
        'Alpha',
        explore: [
          _feed('Shared feed', () {
            requests.add('alpha');
            return slowPage.future;
          }),
        ],
      );
      final beta = _source(
        'beta',
        'Beta',
        explore: [
          _feed('Shared feed', () async {
            requests.add('beta');
            return const Res([ExplorePagePart('Beta section', [], null)]);
          }),
          _feed('Second feed', () async => const Res([])),
        ],
        categories: true,
      );
      ComicSourceManager().installPreparedSources([alpha, beta]);
      appdata.settings['enabledSources'] = ['alpha', 'beta'];
      appdata.settings['initialPage'] = '2';
      appdata.settings['explore_pages'] = ['Second feed'];
      appdata.settings['categories'] = ['Shared categories'];

      await tester.pumpWidget(const MaterialApp(home: MainPage()));
      await tester.pumpAndSettle();

      final navigation = tester.widget<NaviPane>(find.byType(NaviPane));
      expect(navigation.initialPage, 2);
      expect(navigation.paneItems.map((item) => item.label), [
        'Home'.tl,
        'Favorites'.tl,
        'Categories'.tl,
      ]);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.byType(AppTabBar), findsOneWidget);
      expect(requests, isEmpty);
      expect(
        tester.getTopLeft(find.text('Beta category')).dy,
        lessThan(tester.getTopLeft(find.text('Shared feed')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Shared feed')).dy,
        lessThan(tester.getTopLeft(find.text('Second feed')).dy),
      );

      await tester.tap(_sourceTab('alpha'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Shared feed'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(requests, ['alpha']);

      await tester.tap(find.byTooltip('Back'.tl));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('category-source-picker')));
      await tester.pumpAndSettle();
      final picker = find.byKey(const Key('category-source-picker-page'));
      final alphaResult = find.descendant(
        of: picker,
        matching: find.byKey(const ValueKey('alpha')),
      );
      final betaResult = find.descendant(
        of: picker,
        matching: find.byKey(const ValueKey('beta')),
      );
      expect(
        tester.getTopLeft(alphaResult).dy,
        lessThan(tester.getTopLeft(betaResult).dy),
      );
      await tester.enterText(find.byType(TextField), 'bet');
      await tester.pumpAndSettle();
      expect(alphaResult, findsNothing);
      await tester.tap(betaResult);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Shared feed'));
      slowPage.complete(
        const Res([ExplorePagePart('Alpha section', [], null)]),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SourceExplorePage), findsOneWidget);
      expect(find.text('Beta section'), findsOneWidget);
      expect(find.text('Alpha section'), findsNothing);
      expect(requests, ['alpha', 'beta']);
    },
  );

  testWidgets(
    'desktop uses top tabs and restores the original filled category tags',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1050, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final requests = <String>[];
      final alpha = _source(
        'alpha',
        'Alpha',
        categories: true,
        requests: requests,
      );
      final beta = _source(
        'beta',
        'Beta',
        categories: true,
        requests: requests,
      );
      ComicSourceManager().installPreparedSources([alpha, beta]);
      appdata.settings['enabledSources'] = ['alpha', 'beta'];
      appdata.settings['initialPage'] = '3';
      appdata.settings['categories'] = ['Shared categories'];

      await tester.pumpWidget(const MaterialApp(home: MainPage()));
      await tester.pumpAndSettle();
      expect(tester.widget<NaviPane>(find.byType(NaviPane)).initialPage, 2);
      expect(find.text('Alpha category'), findsOneWidget);
      expect(
        tester.getCenter(_sourceTab('alpha')).dy,
        tester.getCenter(_sourceTab('beta')).dy,
      );
      await tester.tap(_sourceTab('beta'));
      await tester.pumpAndSettle();
      final label = find.text('Beta category');
      final tagSurface = find.ancestor(
        of: label,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Material &&
              widget.borderRadius == BorderRadius.circular(8),
        ),
      );
      expect(
        tester.widget<Material>(tagSurface).color,
        Theme.of(
          tester.element(label),
        ).colorScheme.primaryContainer.withValues(alpha: 0.72),
      );
      await tester.tap(find.text('Beta category'));
      await tester.pumpAndSettle();
      expect(requests, ['beta']);
      await tester.tap(find.byTooltip('Back'.tl));
      await tester.pumpAndSettle();
      expect(find.text('Beta category'), findsOneWidget);
      await tester.drag(find.byType(TabBarView), const Offset(700, 0));
      await tester.pumpAndSettle();
      expect(find.text('Alpha category'), findsOneWidget);
      await tester.tap(_sourceTab('beta'));
      await tester.pumpAndSettle();

      appdata.settings['enabledSources'] = ['alpha'];
      await tester.pumpAndSettle();
      expect(find.text('Alpha category'), findsOneWidget);
      expect(find.text('Beta category'), findsNothing);
      appdata.settings['enabledSources'] = <String>[];
      await tester.pumpAndSettle();
      expect(find.text('Manage'.tl), findsOneWidget);
    },
  );

  testWidgets(
    'a long header shows the remembered source and keeps search visible',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 650));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final sources = [
        for (var index = 0; index < 12; index++)
          _source('src_$index', 'Catalog source $index', categories: true),
      ];
      ComicSourceManager().installPreparedSources(sources);
      appdata.settings['enabledSources'] = sources
          .map((source) => source.key)
          .toList();
      appdata.implicitData['categoryBrowseSources'] = ['src_11'];

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CategoriesPage())),
      );
      await tester.pumpAndSettle();

      final header = tester.getRect(find.byType(AppTabBar));
      expect(header.contains(tester.getCenter(_sourceTab('src_11'))), isTrue);
      expect(find.text('Catalog source 11 category'), findsOneWidget);
      await tester.tap(find.byKey(const Key('category-source-picker')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'src_5');
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('category-source-picker-page')),
          matching: find.byKey(const ValueKey('src_5')),
        ),
      );
      await tester.pumpAndSettle();
      expect(header.contains(tester.getCenter(_sourceTab('src_5'))), isTrue);
      expect(find.text('Catalog source 5 category'), findsOneWidget);
    },
  );

  testWidgets(
    'source order is saved on Done and retains disabled sources in their slots',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 650));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final sources = [
        _source('alpha', 'Alpha', categories: true),
        _source('beta', 'Beta', categories: true),
        _source('gamma', 'Gamma', categories: true),
        _source('delta', 'Delta', categories: true),
      ];
      ComicSourceManager().installPreparedSources(sources);
      appdata.settings['enabledSources'] = ['alpha', 'beta', 'gamma'];

      Future<void> openCategories() async {
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: CategoriesPage())),
        );
        await tester.pumpAndSettle();
      }

      List<String> tabOrder() => tester
          .widget<AppTabBar>(find.byType(AppTabBar))
          .tabs
          .map((tab) => (tab.key! as ValueKey<String>).value)
          .toList();

      Future<void> moveGammaBeforeAlpha() async {
        await tester.tap(find.byKey(const Key('category-source-picker')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('category-source-picker-page')),
          findsOneWidget,
        );
        await tester.tap(find.text('Sort'.tl));
        await tester.pumpAndSettle();
        final alpha = find.text('Alpha');
        final gamma = find.text('Gamma');
        expect(
          tester.getCenter(alpha).dy,
          lessThan(tester.getCenter(gamma).dy),
        );
        final handle = find.descendant(
          of: find.byKey(const ValueKey('gamma')),
          matching: find.byType(ReorderableDragStartListener),
        );
        final drag = await tester.startGesture(tester.getCenter(handle));
        await tester.pump(const Duration(milliseconds: 100));
        await drag.moveBy(const Offset(0, -24));
        await tester.pump();
        await drag.moveBy(const Offset(0, -22));
        await tester.pump();
        await drag.up();
        await tester.pumpAndSettle();
        expect(
          tester.getCenter(gamma).dy,
          lessThan(tester.getCenter(alpha).dy),
        );
      }

      await openCategories();
      expect(tabOrder(), ['alpha', 'beta', 'gamma']);
      appdata.settings['enabledSources'] = ['alpha', 'gamma'];
      await tester.pumpAndSettle();

      await moveGammaBeforeAlpha();
      await tester.tap(find.byTooltip('Back'.tl));
      await tester.pumpAndSettle();
      expect(tabOrder(), ['alpha', 'gamma']);

      await moveGammaBeforeAlpha();
      await tester.tap(find.text('Done'.tl));
      await tester.pumpAndSettle();
      expect(tabOrder(), ['gamma', 'alpha']);
      expect(find.text('Alpha category'), findsOneWidget);
      expect(appdata.implicitData['categorySourceOrder'], [
        'gamma',
        'beta',
        'alpha',
      ]);

      appdata.settings['enabledSources'] = ['delta', 'alpha', 'beta', 'gamma'];
      await tester.pumpAndSettle();
      expect(tabOrder(), ['gamma', 'beta', 'alpha', 'delta']);

      await tester.pumpWidget(const SizedBox.shrink());
      await openCategories();
      expect(tabOrder(), ['gamma', 'beta', 'alpha', 'delta']);
      expect(find.text('Alpha category'), findsOneWidget);
    },
  );

  testWidgets(
    'returning from an explore page restores the category scroll offset',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 550));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final source = _source(
        'alpha',
        'Alpha',
        categories: true,
        explore: [
          for (var index = 1; index <= 24; index++)
            _feed('Feed $index', () async => const Res([])),
        ],
      );
      ComicSourceManager().installPreparedSources([source]);
      appdata.settings['enabledSources'] = ['alpha'];
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CategoriesPage())),
      );
      await tester.pumpAndSettle();
      final scrollable = find.descendant(
        of: find.byKey(const PageStorageKey('categories:alpha')),
        matching: find.byType(Scrollable),
      );
      await tester.drag(scrollable, const Offset(0, -1800));
      await tester.pumpAndSettle();
      final offset = tester.state<ScrollableState>(scrollable).position.pixels;
      expect(offset, greaterThan(0));
      await tester.tap(find.text('Feed 24'));
      await tester.pumpAndSettle();
      expect(find.byType(SourceExplorePage), findsOneWidget);
      await tester.tap(find.byTooltip('Back'.tl));
      await tester.pumpAndSettle();
      expect(tester.state<ScrollableState>(scrollable).position.pixels, offset);
    },
  );
}

Finder _sourceTab(String key) => find.descendant(
  of: find.byType(AppTabBar),
  matching: find.byKey(ValueKey(key)),
);

ExplorePageData _feed(
  String title,
  Future<Res<List<ExplorePagePart>>> Function() load,
) => ExplorePageData(
  title,
  ExplorePageType.singlePageWithMultiPart,
  null,
  null,
  load,
  null,
);

ComicSource _source(
  String key,
  String label, {
  bool categories = false,
  List<ExplorePageData> explore = const [],
  List<String>? requests,
}) => ComicSource(
  label,
  key,
  null,
  categories
      ? CategoryData(
          title: 'Shared categories',
          categories: [
            FixedCategoryPart('Genre', [
              CategoryItem(
                '$label category',
                PageJumpTarget(key, 'category', {'category': 'Genre'}),
              ),
            ]),
          ],
          enableRankingPage: false,
          key: 'Shared categories',
        )
      : null,
  categories
      ? CategoryComicsData(
          options: const [],
          load: (category, param, options, page) async {
            requests?.add(key);
            return const Res(<Comic>[], subData: 1);
          },
        )
      : null,
  null,
  explore,
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
