import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/booklet_painter.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/home_module_layout.dart';
import 'package:venera/network/images.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/pages/home_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(AppTranslation.init);

  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('venera-home-layout-');
    App.dataPath = directory.path;
    appdata.settings[homeModuleLayoutSetting] = [
      'recentUpdates',
      'comicSource',
    ];
    appdata.settings['webdav'] = [];
  });

  tearDown(() async {
    await appdata.waitForPendingWrites();
    appdata.settings[homeModuleLayoutSetting] = null;
    await directory.delete(recursive: true);
  });

  test('settings distinguish defaults, custom order and a clean homepage', () {
    expect(HomeModule.readLayout(null), HomeModule.values);
    expect(HomeModule.readLayout([]), isEmpty);
    expect(HomeModule.readLayout(['local', 'unknown', 'history', 2, 'local']), [
      HomeModule.local,
      HomeModule.history,
    ]);
  });

  test('layout persists locally and user-data merges skip it', () async {
    await appdata.persistHomeModuleLayout([]);
    final persisted = Appdata.createForTesting(() async => directory);
    await persisted.init();

    expect(persisted.settings[homeModuleLayoutSetting], isEmpty);
    expect(
      persisted.toUserDataJson()['settings'],
      isNot(contains(homeModuleLayoutSetting)),
    );

    final incoming = await persisted.prepareUserDataCommit({
      'settings': {
        homeModuleLayoutSetting: ['history'],
        'comicTileScale': 1.2,
      },
    });
    try {
      await incoming.replace();
      incoming.installMemorySilently();
    } finally {
      incoming.release();
    }
    expect(persisted.settings[homeModuleLayoutSetting], isEmpty);
    expect(persisted.settings['comicTileScale'], 1.2);
  });

  testWidgets('whole-card long press, hide and multi-select restore', (
    tester,
  ) async {
    setViewport(tester, const Size(400, 720));
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: HomePage())),
    );

    final addModules = find.byTooltip('Add modules');
    final hideUpdates = find.byTooltip('Hide Recent updates from home');
    final hideSources = find.byTooltip('Hide Comic Source from home');
    final done = find.text('Done');
    expect(addModules, findsNothing);
    expect(find.byType(BlurEffect), findsNothing);
    expect(find.byType(SearchEntryHero), findsOneWidget);
    await tester.longPressAt(
      tester.getCenter(find.byType(FollowUpdatesWidget)),
    );
    await tester.pumpAndSettle();
    expect(addModules, findsOneWidget);
    expect(find.byType(BlurEffect), findsNWidgets(2));
    final hideRect = tester.getRect(hideUpdates);
    final handle = find.byKey(const ValueKey('move-recentUpdates'));
    final handleRect = tester.getRect(handle);
    expect(tester.getSize(hideUpdates), const Size(44, 44));
    expect(tester.getSize(handle), const Size(44, 44));
    expect(handleRect.right, closeTo(hideRect.right, .001));
    expect(handleRect.top, greaterThanOrEqualTo(hideRect.bottom - .001));
    expect(
      tester.getTopLeft(addModules).dy,
      greaterThan(tester.getBottomLeft(hideSources).dy),
    );

    Future<void> act(Finder finder) async {
      await tester.tap(finder);
      await settleLayoutWrite(tester);
    }

    // Tap away from the small visible ×, still inside its hit area.
    await tester.tapAt(hideRect.topLeft + const Offset(6, 7));
    await settleLayoutWrite(tester);
    expect(find.text('Recent updates'), findsNothing);
    expect(find.text('Undo'), findsNothing);
    expect(appdata.settings[homeModuleLayoutSetting], ['comicSource']);

    await act(hideSources);
    expect(addModules, findsOneWidget);
    expect(appdata.settings[homeModuleLayoutSetting], isEmpty);
    await tester.tap(done);
    await tester.pumpAndSettle();
    expect(addModules, findsNothing);
    expect(find.byType(SearchEntryHero), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is BookletPainter,
      ),
      findsOneWidget,
    );

    await tester.longPress(find.byKey(const ValueKey('empty-home')));
    await tester.pumpAndSettle();
    await tester.tap(addModules);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Comic Source'));
    await tester.tap(find.text('Recent updates'));
    await tester.pumpAndSettle();
    await act(find.widgetWithText(FilledButton, 'Add'));
    expect(appdata.settings[homeModuleLayoutSetting], [
      'comicSource',
      'recentUpdates',
    ]);
    expect(
      tester.getTopLeft(find.text('Comic Source')).dy,
      lessThan(tester.getTopLeft(find.text('Recent updates')).dy),
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(addModules, findsNothing);
    expect(find.byType(BlurEffect), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('drag cancels cleanly and saves only the final drop', (
    tester,
  ) async {
    appdata.settings[homeModuleLayoutSetting] = [
      'recentUpdates',
      'sync',
      'comicSource',
    ];
    setViewport(tester, const Size(1060, 650));
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: HomePage.editor())),
    );
    await tester.pumpAndSettle();

    final updates = find.byKey(const ValueKey('move-recentUpdates'));
    final sources = find.byKey(const ValueKey('move-comicSource'));
    final start = tester.getRect(updates).topLeft + const Offset(6, 7);
    final sourcePosition = tester.getCenter(sources);
    final end = sourcePosition + const Offset(0, 24);

    Future<TestGesture> dragDown() async {
      final gesture = await tester.startGesture(start);
      for (var step = 1; step <= 8; step++) {
        await gesture.moveTo(Offset.lerp(start, end, step / 8)!);
        await tester.pump(const Duration(milliseconds: 24));
      }
      return gesture;
    }

    final canceled = await dragDown();
    expect(tester.getCenter(sources).dy, lessThan(sourcePosition.dy));
    await canceled.cancel();
    await tester.pumpAndSettle();
    expect(appdata.settings[homeModuleLayoutSetting], [
      'recentUpdates',
      'sync',
      'comicSource',
    ]);

    final drag = await dragDown();
    await drag.up();
    await settleLayoutWrite(tester);
    expect(appdata.settings[homeModuleLayoutSetting], [
      'comicSource',
      'sync',
      'recentUpdates',
    ]);
    expect(
      tester.getCenter(sources).dy,
      lessThan(tester.getCenter(updates).dy),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('Done stays beside search while the add capsule scrolls', (
    tester,
  ) async {
    setViewport(tester, const Size(360, 195));
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: HomePage())),
    );
    await tester.longPressAt(
      tester.getCenter(find.byType(FollowUpdatesWidget)),
    );
    await tester.pumpAndSettle();
    final done = find.text('Done');
    final addModules = find.byTooltip('Add modules');
    final donePosition = tester.getCenter(done);
    expect(addModules.hitTestable(), findsNothing);
    await tester.dragFrom(const Offset(160, 153), const Offset(0, -145));
    await tester.pumpAndSettle();
    expect(addModules.hitTestable(), findsOneWidget);
    expect(tester.getCenter(done), donePosition);
    await tester.tap(done);
    await tester.pumpAndSettle();
    expect(addModules, findsNothing);
    expect(done, findsNothing);
  });

  testWidgets(
    'history covers still swipe and support a stationary long press',
    (tester) async {
      appdata.settings[homeModuleLayoutSetting] = ['history'];
      setViewport(tester, const Size(400, 720));
      final manager = HistoryManager.create();
      final oldHistory = HistoryManager.cache;
      HistoryManager.cache = manager;
      final oldCache = CacheManager.instance;
      late final CacheManager covers;
      addTearDown(() async {
        await manager.closeWhenIdle();
        HistoryManager.cache = oldHistory;
        covers.dispose();
        CacheManager.instance = oldCache;
      });
      await tester.runAsync(() async {
        covers = CacheManager.test(
          cachePath: '${directory.path}/covers',
          dbPath: '${directory.path}/covers.db',
        );
        CacheManager.instance = covers;
        await manager.init();
        final png = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
          '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        );
        const coverUrl = 'https://example.invalid/cover.png';
        for (var index = 0; index < 7; index++) {
          final record = History.fromMap({
            'type': 0,
            'id': 'history-$index',
            'title': 'History $index',
            'subtitle': '',
            'cover': coverUrl,
            'time': index,
            'ep': 1,
            'page': 1,
            'readEpisode': <String>['1'],
            'max_page': 1,
          });
          manager.addHistory(record);
          await covers.writeCache(
            ImageDownloader.thumbnailCacheKey(
              coverUrl,
              record.sourceKey,
              record.id,
            ),
            png,
          );
        }
      });
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: HomePage())),
      );
      final scrollable = find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      );
      await tester.drag(scrollable, const Offset(-185, 0));
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(scrollable).position.pixels,
        greaterThan(0),
      );
      expect(find.text('Done'), findsNothing);
      await tester.longPressAt(tester.getCenter(scrollable));
      await tester.pumpAndSettle();
      expect(find.text('Done'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets('appearance settings can open the editor on an empty home', (
    tester,
  ) async {
    appdata.settings[homeModuleLayoutSetting] = <String>[];
    setViewport(tester, const Size(400, 720));
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SettingsPage())),
    );
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home modules'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Add modules'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Home modules'), findsOneWidget);
  });

  testWidgets('reduced motion shows the static empty booklet', (tester) async {
    appdata.settings[homeModuleLayoutSetting] = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const Scaffold(body: HomePage()),
      ),
    );
    final paint = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is BookletPainter,
      ),
    );
    expect((paint.painter! as BookletPainter).turn.value, 1);
  });
}

void setViewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

Future<void> settleLayoutWrite(WidgetTester tester) async {
  await tester.pumpAndSettle();
  var finished = false;
  unawaited(appdata.waitForPendingWrites().then((_) => finished = true));
  for (var attempt = 0; attempt < 20 && !finished; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pumpAndSettle();
  }
  expect(finished, isTrue);
}
