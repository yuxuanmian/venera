import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/semantic_search/controller.dart';
import 'package:venera/foundation/semantic_search/models.dart';
import 'package:venera/pages/search_page.dart';
import 'package:venera/pages/search_result_page.dart';
import 'package:venera/pages/semantic_search_page.dart';
import 'package:venera/utils/translations.dart';

import 'fixtures.dart';

/// Drains the shared comic card's cover-image retry backoff.
///
/// A widget test has no network, so the cover loader retries with a bounded
/// exponential delay (1+2+4+8s) and then gives up. Pumping that window keeps
/// the test from ending with pending timers; the surfaced image error is the
/// expected outcome of an unreachable cover and is consumed here.
Future<void> drainCoverLoads(WidgetTester tester) async {
  for (var i = 0; i < 18; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
  tester.takeException();
}

/// Builds the page with an injected controller so the gesture gate can be
/// tested without a published comic source or a JavaScript runtime.
Future<SemanticSearchController> pumpPage(
  WidgetTester tester,
  FakeSemanticResolver resolver, {
  List<String> options = const ['dd'],
}) async {
  final controller = SemanticSearchController(
    query: SemanticQuery(
      sourceKey: 'fixture_source',
      value: 'opaque value',
      options: options,
    ),
    resolver: resolver,
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: SemanticSearchPage(
        sourceKey: 'fixture_source',
        value: 'opaque value',
        controller: controller,
        initialOptions: options,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

FakeSemanticResolver _pagedResolver({int perWindow = 6, int? maxPage}) {
  final resolver = FakeSemanticResolver();
  var page = 1;
  resolver.onLoad = (invocation) async {
    final current = page;
    page++;
    final start = (current - 1) * perWindow;
    return semanticSuccess(
      List<Comic>.generate(
        perWindow,
        (index) => fixtureComic(start + index, sourceKey: 'fixture_source'),
      ),
      maxPage != null && current >= maxPage
          ? null
          : pageContinuation(current + 1, maxPage),
    );
  };
  return resolver;
}

void main() {
  setUpAll(AppTranslation.init);

  group('results presentation and page interactions (T080/T081)', () {
    /// A published source whose capability is built from plain Dart loaders, so
    /// the semantic page can be exercised end to end without a JavaScript
    /// runtime. The loaders stand in for what Pica's exact predicate returns.
    ComicSource sourceWithSemantic({
      required String key,
      required Future<Res<List<Comic>>> Function(
        String value,
        List<String> options,
        int page,
      )
      loader,
      List<SearchOptions> searchOptions = const <SearchOptions>[],
    }) {
      return ComicSource(
        'Semantic source',
        key,
        null,
        null,
        null,
        null,
        const [],
        SearchPageData(searchOptions, null, null),
        null,
        (id) async => Res<ComicDetails>.error('unused'),
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
        semanticSearchData: SemanticSearchData((
          value,
          options,
          page, {
          required requestScope,
        }) async {
          expect(requestScope, isNotNull);
          return loader(value, options, page);
        }, null),
      );
    }

    testWidgets('only the exact fixture ids reach the shared grid', (
      tester,
    ) async {
      const key = 'page_exact_presentation';
      final source = sourceWithSemantic(
        key: key,
        loader: (value, options, page) async => Res([
          fixtureComic(10, sourceKey: key),
          fixtureComic(11, sourceKey: key),
        ], subData: 1),
      );
      ComicSourceManager().add(source);
      addTearDown(() => ComicSourceManager().remove(key));

      await tester.pumpWidget(
        MaterialApp(
          home: const SemanticSearchPage(sourceKey: key, value: 'Fate'),
        ),
      );
      await tester.pumpAndSettle();

      // The grid renders the loader's result...
      final grid = tester.widget<SliverGridComics>(
        find.byType(SliverGridComics),
      );
      expect(grid.comics.map((comic) => comic.id), ['id-10', 'id-11']);
      // ...and uses the shared card's default detail navigation.
      expect(grid.onTap, isNull);
      expect(grid.onLastItemBuild, isNull);
      // Ids that only matched by title or by category must not appear.
      for (final excluded in ['title-only-1', 'categories-only-1']) {
        expect(find.text(excluded), findsNothing);
      }
      await drainCoverLoads(tester);
    });

    testWidgets('pull-to-refresh reloads from the start', (tester) async {
      const key = 'page_refresh';
      var calls = 0;
      final pages = <int>[];
      final source = sourceWithSemantic(
        key: key,
        loader: (value, options, page) async {
          calls++;
          pages.add(page);
          return Res([fixtureComic(calls, sourceKey: key)], subData: 9);
        },
      );
      ComicSourceManager().add(source);
      addTearDown(() => ComicSourceManager().remove(key));

      await tester.pumpWidget(
        MaterialApp(
          home: const SemanticSearchPage(sourceKey: key, value: 'Fate'),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);

      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 320),
        1000,
      );
      await tester.pumpAndSettle();

      expect(calls, 2, reason: 'RefreshIndicator must run one fresh cycle');
      expect(pages, [1, 1], reason: 'refresh restarts from the first page');
      await drainCoverLoads(tester);
    });

    testWidgets('a sort change resets instead of opening ordinary search', (
      tester,
    ) async {
      const key = 'page_sort';
      final seenOptions = <List<String>>[];
      final source = sourceWithSemantic(
        key: key,
        searchOptions: [
          SearchOptions(
            LinkedHashMap<String, String>.from({'dd': 'New', 'ld': 'Likes'}),
            'Sort',
            'select',
            null,
          ),
        ],
        loader: (value, options, page) async {
          seenOptions.add(List<String>.from(options));
          return Res([
            fixtureComic(seenOptions.length, sourceKey: key),
          ], subData: 9);
        },
      );
      ComicSourceManager().add(source);
      addTearDown(() => ComicSourceManager().remove(key));

      await tester.pumpWidget(
        MaterialApp(
          home: const SemanticSearchPage(sourceKey: key, value: 'Fate'),
        ),
      );
      await tester.pumpAndSettle();
      // The first invocation used the declared default option.
      expect(seenOptions.single, ['dd']);

      await tester.tap(find.byIcon(Icons.tune));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Likes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(seenOptions.length, 2);
      expect(seenOptions.last, [
        'ld',
      ], reason: 'the new options snapshot must reach the source request');
      expect(
        find.byType(SearchResultPage),
        findsNothing,
        reason: 'a sort change never rebuilds ordinary search',
      );
      await drainCoverLoads(tester);
    });

    testWidgets('the options dialog keeps its rows off the dialog edges', (
      tester,
    ) async {
      const key = 'page_sort_layout';
      final source = sourceWithSemantic(
        key: key,
        searchOptions: [
          SearchOptions(
            LinkedHashMap<String, String>.from({'dd': 'New', 'ld': 'Likes'}),
            'Sort',
            'select',
            null,
          ),
        ],
        loader: (value, options, page) async =>
            Res([fixtureComic(1, sourceKey: key)], subData: 1),
      );
      ComicSourceManager().add(source);
      addTearDown(() => ComicSourceManager().remove(key));

      await tester.pumpWidget(
        MaterialApp(
          home: const SemanticSearchPage(sourceKey: key, value: 'Fate'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.tune));
      await tester.pumpAndSettle();

      // `ContentDialog` adds no horizontal padding of its own and
      // `SearchOptionWidget` provides none either, so the dialog content must
      // inset the rows itself.
      final dialog = tester.getRect(find.byType(Dialog));
      final row = tester.getRect(find.byType(SearchOptionWidget));
      expect(
        row.left - dialog.left,
        greaterThanOrEqualTo(16),
        reason: 'the option label must not touch the dialog edge',
      );
      expect(
        dialog.right - row.right,
        greaterThanOrEqualTo(16),
        reason: 'the option chips must not touch the dialog edge',
      );
      await drainCoverLoads(tester);
    });

    testWidgets('disposing during an in-flight request is silent', (
      tester,
    ) async {
      const key = 'page_dispose_in_flight';
      final gate = Completer<void>();
      final source = sourceWithSemantic(
        key: key,
        loader: (value, options, page) async {
          await gate.future;
          return Res([fixtureComic(1, sourceKey: key)], subData: 1);
        },
      );
      ComicSourceManager().add(source);
      addTearDown(() => ComicSourceManager().remove(key));

      SemanticSearchController? controller;
      await tester.pumpWidget(
        MaterialApp(
          home: SemanticSearchPage(
            sourceKey: key,
            value: 'Fate',
            onControllerCreated: (value) => controller = value,
          ),
        ),
      );
      await tester.pump();
      expect(controller, isNotNull);
      expect(controller!.status, SemanticSearchStatus.loading);
      final scope = controller!.queryScope;

      await tester.pumpWidget(const SizedBox());
      expect(scope.isCanceled, isTrue);
      gate.complete();
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: 'a canceled in-flight invocation must not surface an error',
      );
      expect(controller!.errorMessage, isNull);
    });
  });

  group('semantic page shell', () {
    testWidgets('shows the fixed source context and opaque Tag value', (
      tester,
    ) async {
      final resolver = _pagedResolver(maxPage: 9);
      await pumpPage(tester, resolver);

      expect(find.textContaining('Tag: opaque value'), findsOneWidget);
      // No search field, no value editing, no source switch.
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.text('Search'), findsNothing);
      await drainCoverLoads(tester);
    });

    testWidgets('runs exactly one automatic initial cycle', (tester) async {
      final resolver = _pagedResolver(maxPage: 9);
      await pumpPage(tester, resolver);
      expect(resolver.requestCount, 1);
      await drainCoverLoads(tester);
    });

    testWidgets('near-end alone never adds a cycle', (tester) async {
      final resolver = _pagedResolver(maxPage: 9);
      final controller = await pumpPage(tester, resolver);
      expect(controller.status, SemanticSearchStatus.idle);
      await drainCoverLoads(tester);

      // Rebuilding and settling without a gesture must not request anything.
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(resolver.requestCount, 1);
    });
  });

  group('gesture epoch gate', () {
    testWidgets('one drag consumes at most one epoch', (tester) async {
      final resolver = _pagedResolver(perWindow: 6, maxPage: 30);
      final controller = await pumpPage(tester, resolver);
      expect(resolver.requestCount, 1);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pumpAndSettle();

      expect(
        resolver.requestCount,
        2,
        reason:
            'a single drag emits many ScrollUpdateNotifications but must open '
            'at most one cycle',
      );
      expect(controller.visible, hasLength(12));
      await drainCoverLoads(tester);
    });

    testWidgets('a second drag opens a second cycle', (tester) async {
      final resolver = _pagedResolver(perWindow: 6, maxPage: 30);
      await pumpPage(tester, resolver);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pumpAndSettle();

      expect(resolver.requestCount, 3);
      await drainCoverLoads(tester);
    });

    testWidgets('a scrollable list rejects the epoch while far from the end', (
      tester,
    ) async {
      // 30 items make the list far taller than the 600px test viewport.
      final resolver = _pagedResolver(perWindow: 30, maxPage: 60);
      await pumpPage(tester, resolver);
      expect(resolver.requestCount, 1);

      // A partial drag stays far from the end, so no intent may be produced
      // even though the source still has more pages.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(
        resolver.requestCount,
        1,
        reason: 'extentAfter is still far above half the viewport',
      );
      await drainCoverLoads(tester);
    });

    testWidgets('a short list accepts the same gesture near its end', (
      tester,
    ) async {
      final resolver = _pagedResolver(perWindow: 6, maxPage: 30);
      await pumpPage(tester, resolver);
      expect(resolver.requestCount, 1);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(resolver.requestCount, 2);
      await drainCoverLoads(tester);
    });

    testWidgets('finished ignores further gestures', (tester) async {
      final resolver = FakeSemanticResolver();
      resolver.onLoad = (invocation) async =>
          semanticSuccess(fixtureComics(3), null);
      final controller = await pumpPage(tester, resolver);

      expect(controller.status, SemanticSearchStatus.finished);
      expect(resolver.requestCount, 1);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(resolver.requestCount, 1);
      expect(find.text('Finished'), findsOneWidget);
      await drainCoverLoads(tester);
    });

    testWidgets('waiting accepts a trailing overscroll on an undersized list', (
      tester,
    ) async {
      final resolver = FakeSemanticResolver();
      var call = 0;
      resolver.onLoad = (invocation) async {
        call++;
        // Two consecutive empty windows land the controller in waiting.
        if (call <= 2) {
          return semanticSuccess(const [], cursorContinuation('c$call'));
        }
        return semanticSuccess(fixtureComics(2), null);
      };
      final controller = await pumpPage(tester, resolver);

      expect(controller.status, SemanticSearchStatus.waitingForContinue);
      expect(resolver.requestCount, 2);

      // AlwaysScrollable physics lets an empty page express the intent.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
      await tester.pumpAndSettle();

      expect(resolver.requestCount, 3);
      await drainCoverLoads(tester);
      expect(controller.visible, hasLength(2));
      await drainCoverLoads(tester);
    });

    testWidgets('an empty visible list is scrollable and can continue', (
      tester,
    ) async {
      final resolver = FakeSemanticResolver();
      var call = 0;
      resolver.onLoad = (invocation) async {
        call++;
        if (call <= 2) {
          return semanticSuccess(const [], cursorContinuation('c$call'));
        }
        return semanticSuccess(fixtureComics(1), cursorContinuation('done'));
      };
      final controller = await pumpPage(tester, resolver);
      expect(controller.visible, isEmpty);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(controller.visible, hasLength(1));
      await drainCoverLoads(tester);
    });
  });

  group('footer states', () {
    testWidgets('a first-page error is a full error with Retry', (
      tester,
    ) async {
      final resolver = FakeSemanticResolver();
      resolver.onLoad = (invocation) async =>
          Res<SemanticSourceResult>.error('boom');
      await pumpPage(tester, resolver);

      expect(find.text('boom'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byType(CustomScrollView), findsNothing);
    });

    testWidgets('a later error keeps the list and shows a footer Retry', (
      tester,
    ) async {
      final resolver = FakeSemanticResolver();
      var call = 0;
      resolver.onLoad = (invocation) async {
        call++;
        if (call == 1) {
          return semanticSuccess(fixtureComics(6), cursorContinuation('c1'));
        }
        return Res<SemanticSourceResult>.error('boom');
      };
      final controller = await pumpPage(tester, resolver);
      expect(controller.visible, hasLength(6));

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pumpAndSettle();

      expect(controller.status, SemanticSearchStatus.error);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byType(CustomScrollView), findsOneWidget);
      await drainCoverLoads(tester);
    });

    testWidgets('Retry replays the failed input', (tester) async {
      final resolver = FakeSemanticResolver();
      var call = 0;
      resolver.onLoad = (invocation) async {
        call++;
        if (call == 2) return Res<SemanticSourceResult>.error('boom');
        if (call == 1) {
          return semanticSuccess(fixtureComics(6), cursorContinuation('c1'));
        }
        return semanticSuccess(fixtureComics(1), null);
      };
      final controller = await pumpPage(tester, resolver);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(resolver.requestCount, 3);
      expect(
        resolver.invocations.last.inputContinuation,
        const CursorContinuation('c1'),
      );
      expect(controller.status, SemanticSearchStatus.finished);
      await drainCoverLoads(tester);
    });
  });

  group('compatibility and unsupported', () {
    testWidgets(
      'fallback shows a non-exact notice and no ordinary search box',
      (tester) async {
        final resolver = FakeSemanticResolver(
          mode: SemanticCapabilityMode.ordinaryFallback,
        );
        resolver.onLoad = (invocation) async =>
            semanticSuccess(fixtureComics(2), null);
        await pumpPage(tester, resolver);

        expect(
          find.textContaining('not guaranteed to be exact'),
          findsOneWidget,
        );
        await drainCoverLoads(tester);
        expect(find.byType(TextField), findsNothing);
      },
    );

    testWidgets('unsupported is a terminal non-retrying body', (tester) async {
      final resolver = FakeSemanticResolver(
        mode: SemanticCapabilityMode.unsupported,
      );
      final controller = await pumpPage(tester, resolver);

      expect(controller.status, SemanticSearchStatus.unsupported);
      expect(find.textContaining('cannot search by tag'), findsOneWidget);
      expect(resolver.requestCount, 0);

      await tester.drag(find.byType(Scaffold), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(resolver.requestCount, 0);
    });
  });
}
