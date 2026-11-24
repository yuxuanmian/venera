import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/ranking_medal.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/ranking_page.dart';
import 'package:venera/utils/translations.dart';

const _sourceKey = 'ranking_medal_test_source';
const _categoryKey = 'ranking-medal-test-category';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(AppTranslation.init);

  testWidgets('a ranking target opens the shared page for its source', (
    tester,
  ) async {
    _configureList(mode: 'detailed', paging: true);
    _registerSource(
      RankingData({'popular': 'Popular'}, (option, page) async {
        expect(option, 'popular');
        expect(page, 1);
        return Res([_comic('Ranked comic')], subData: 1);
      }, null),
    );
    final target = PageJumpTarget.parse(_sourceKey, {'page': 'ranking'});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => target.jump(context),
              child: const Text('More rankings'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('More rankings'));
    await tester.pumpAndSettle();

    expect(find.byType(RankingPage), findsOneWidget);
    expect(tester.widget<RankingMedal>(_medalInTile('Ranked comic')).rank, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'detailed ranking medals keep original places across pages and tabs',
    (tester) async {
      _configureList(mode: 'detailed', paging: true, blocked: ['Blocked']);
      final second = _comic('Popular second');
      final pages = <(String, int)>[];
      _registerSource(
        RankingData({'popular': 'Popular', 'recent': 'Recent'}, (
          option,
          page,
        ) async {
          pages.add((option, page));
          if (option == 'recent') {
            return Res([
              _comic('Recent first'),
              _comic('Recent second'),
              _comic('Recent third'),
            ], subData: 1);
          }
          return Res(
            page == 1
                ? [
                    _comic('Blocked first'),
                    second,
                    _comic('Popular third'),
                    _comic('Popular fourth'),
                  ]
                : [second, _comic('Next page')],
            subData: 2,
          );
        }, null),
      );
      await tester.binding.setSurfaceSize(const Size(320, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _openRanking(tester);

      final silver = _medalInTile('Popular second');
      expect(_ranks(tester), [2, 3]);
      expect(tester.widget<RankingMedal>(silver).rank, 2);
      expect(tester.getSize(silver), const Size(44, 51));
      expect(
        tester.getCenter(silver).dx,
        greaterThan(tester.getCenter(find.text('Popular second')).dx),
      );
      expect(_medalInTile('Popular fourth'), findsNothing);

      await tester.tap(find.text('Next'.tl).first);
      await tester.pumpAndSettle();
      expect(pages.last, ('popular', 2));
      expect(find.text('Next page'), findsOneWidget);
      expect(_ranks(tester), isEmpty);

      await tester.tap(find.text('Recent'));
      await tester.pumpAndSettle();
      expect(pages.last, ('recent', 1));
      expect(_ranks(tester), [1, 2, 3]);
      expect(tester.widget<RankingMedal>(_medalInTile('Recent first')).rank, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'brief cursor ranking shows small medals only on the first three entries',
    (tester) async {
      _configureList(mode: 'brief', paging: false);
      final first = _comic('First');
      final requests = <String?>[];
      _registerSource(
        RankingData({'popular': 'Popular'}, null, (_, next) async {
          requests.add(next);
          if (next == null) {
            return Res([
              first,
              _comic('Second'),
              _comic('Third'),
            ], subData: 'next');
          }
          return Res([first, _comic('Next page')]);
        }),
      );
      await _openRanking(tester);

      expect(requests, [null, 'next']);
      expect(find.text('First'), findsNWidgets(2));
      expect(_ranks(tester), [1, 2, 3]);
      for (final medal in find.byType(RankingMedal).evaluate()) {
        expect(medal.size, const Size(24, 28));
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('ranking keeps its tabs visible during first and paged loads', (
    tester,
  ) async {
    _configureList(mode: 'detailed', paging: true);
    await tester.binding.setSurfaceSize(const Size(320, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final first = Completer<Res<List<Comic>>>();
    final second = Completer<Res<List<Comic>>>();
    var recentRequests = 0;
    final recent = Completer<Res<List<Comic>>>();
    _registerSource(
      RankingData({'popular': 'Popular', 'recent': 'Recent'}, (option, page) {
        if (option == 'recent') {
          recentRequests++;
          return recentRequests == 1
              ? recent.future
              : Future.value(const Res(<Comic>[], subData: 1));
        }
        return page == 1 ? first.future : second.future;
      }, null),
    );
    await _openRanking(tester);
    expect(find.byType(SkeletonBlock), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Popular'), findsOneWidget);
    expect(find.text('Recent'), findsOneWidget);
    expect(find.byType(RankingMedal), findsNothing);

    first.complete(
      Res(
        List.generate(10, (index) => _comic('Popular entry $index')),
        subData: 2,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Popular entry 0'), findsOneWidget);
    expect(find.byType(SkeletonBlock), findsNothing);

    ScrollPosition currentPosition() => tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!
        .position;
    currentPosition().jumpTo(currentPosition().maxScrollExtent);
    await tester.pumpAndSettle();
    expect(currentPosition().pixels, greaterThan(0));
    await tester.tap(find.text('Next'.tl).hitTestable());
    await tester.pumpAndSettle();
    expect(currentPosition().pixels, 0);
    expect(find.byType(SkeletonBlock), findsWidgets);
    expect(find.text('Page 2 / 2'), findsOneWidget);
    expect(find.text('Recent'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.tap(find.text('Recent'));
    await tester.pumpAndSettle();
    second.complete(Res([_comic('Late popular entry')], subData: 2));
    await tester.pumpAndSettle();
    expect(find.text('Late popular entry'), findsNothing);
    expect(find.byType(SkeletonBlock), findsWidgets);

    recent.complete(const Res.error('Could not load this ranking'));
    await tester.pumpAndSettle();
    expect(find.byType(SkeletonBlock), findsNothing);
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('Could not load this ranking'), findsOneWidget);

    await tester.tap(find.text('Retry'.tl));
    await tester.pumpAndSettle();
    expect(recentRequests, 2);
    expect(find.text('No ranking entries'.tl), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('continuous ranking shows a grid row while loading more', (
    tester,
  ) async {
    _configureList(mode: 'brief', paging: false);
    final nextPage = Completer<Res<List<Comic>>>();
    final requests = <String?>[];
    _registerSource(
      RankingData({'popular': 'Popular'}, null, (_, next) {
        requests.add(next);
        return next == null
            ? Future.value(Res([_comic('First entry')], subData: 'next'))
            : nextPage.future;
      }),
    );
    await _openRanking(tester, theme: ThemeData.dark());
    expect(requests, [null, 'next']);
    expect(find.text('First entry'), findsWidgets);
    expect(find.byType(SkeletonBlock), findsWidgets);
    expect(find.byType(SliverListLoadingIndicator), findsNothing);
    final coverBlock = find.byType(SkeletonBlock).first;
    final color = Theme.of(tester.element(coverBlock)).colorScheme;
    final coverFill = find.descendant(
      of: coverBlock,
      matching: find.byType(DecoratedBox),
    );
    expect(
      (tester.widget<DecoratedBox>(coverFill).decoration as BoxDecoration)
          .color,
      color.surfaceContainer,
    );

    nextPage.complete(Res([_comic('Second entry')]));
    await tester.pumpAndSettle();
    expect(find.text('Second entry'), findsWidgets);
    expect(find.byType(SkeletonBlock), findsNothing);
    expect(_ranks(tester), [1]);
  });

  testWidgets('ranking loads the next cursor after an empty batch', (
    tester,
  ) async {
    _configureList(mode: 'brief', paging: false);
    final requests = <String?>[];
    _registerSource(
      RankingData({'popular': 'Popular'}, null, (_, next) async {
        requests.add(next);
        return next == null
            ? const Res(<Comic>[], subData: 'next')
            : Res([_comic('Next entry')]);
      }),
    );
    await _openRanking(tester);
    expect(requests, [null, 'next']);
    expect(find.text('Next entry'), findsWidgets);
    expect(find.byType(SkeletonBlock), findsNothing);
  });
}

Future<void> _openRanking(WidgetTester tester, {ThemeData? theme}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: const RankingPage(sourceKey: _sourceKey),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _medalInTile(String title) => find.descendant(
  of: find.ancestor(of: find.text(title), matching: find.byType(ComicTile)),
  matching: find.byType(RankingMedal),
);

List<int> _ranks(WidgetTester tester) => tester
    .widgetList<RankingMedal>(find.byType(RankingMedal))
    .map((medal) => medal.rank)
    .toList();

void _configureList({
  required String mode,
  required bool paging,
  List<String> blocked = const [],
}) {
  final settings = {
    'comicDisplayMode': mode,
    'comicListDisplayMode': paging ? 'paging' : 'continuous',
    'enabledSources': [_sourceKey],
    'blockedWords': blocked,
  };
  final previous = {
    for (final key in settings.keys) key: appdata.settings[key],
  };
  addTearDown(() {
    for (final entry in previous.entries) {
      appdata.settings[entry.key] = entry.value;
    }
  });
  for (final entry in settings.entries) {
    appdata.settings[entry.key] = entry.value;
  }
}

Comic _comic(String title) => Comic(
  title,
  'file://${File('assets/app_icon.png').absolute.path}',
  title,
  null,
  null,
  '',
  _sourceKey,
  null,
  null,
);

void _registerSource(RankingData ranking) {
  ComicSourceManager().add(
    ComicSource(
      'Ranking test source',
      _sourceKey,
      null,
      const CategoryData(
        title: 'Categories',
        categories: [],
        enableRankingPage: true,
        key: _categoryKey,
      ),
      CategoryComicsData(
        load: (_, _, _, _) async => const Res(<Comic>[]),
        rankingData: ranking,
      ),
      null,
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
    ),
  );
  addTearDown(() => ComicSourceManager().remove(_sourceKey));
}
