import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_update_availability.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late Object? previousEnabled;
  late Object? previousFavorites;
  late Object? previousFollowUpdates;
  late Object? previousFollowUpdatesFolder;

  setUpAll(() async {
    await AppTranslation.init();
  });

  setUp(() async {
    previousEnabled = appdata.settings['enabledSources'];
    previousFavorites = appdata.settings['favorites'];
    previousFollowUpdates = appdata.settings['followUpdatesEnabled'];
    previousFollowUpdatesFolder = appdata.settings['followUpdatesFolder'];
    appdata.settings['enabledSources'] = <String>[];
    appdata.settings['favorites'] = <String>[];
    appdata.settings['followUpdatesEnabled'] = true;
    directory = await Directory.systemTemp.createTemp('venera-retirement-ui-');
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    await NetworkFavoriteCacheManager().init(
      databasePath: '${directory.path}${Platform.pathSeparator}ui.db',
      migrateLegacy: false,
    );
  });

  tearDown(() async {
    appdata.settings['enabledSources'] = previousEnabled;
    appdata.settings['favorites'] = previousFavorites;
    appdata.settings['followUpdatesEnabled'] = previousFollowUpdates;
    appdata.settings['followUpdatesFolder'] = previousFollowUpdatesFolder;
    FollowUpdatesService.cancelChecking();
    NetworkFavoriteCacheManager().close();
    try {
      await directory.delete(recursive: true);
    } on PathAccessException {
      // An unawaited appdata save may release its Windows file handle shortly
      // after the widget test completes.
    }
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: const FollowUpdatesPage(),
        builder: (context, child) => OverlayWidget(child!),
      ),
    );
    await tester.pump();
  }

  int unavailableMessageCount(WidgetTester tester) =>
      find.text(followUpdateScannerUnavailableMessage.tl).evaluate().length;

  Future<void> tapPauseEntryAndExpectFreshFeedback(
    WidgetTester tester,
    Finder entry,
  ) async {
    final before = unavailableMessageCount(tester);
    await tester.tap(entry);
    await tester.pump(const Duration(milliseconds: 1));
    expect(unavailableMessageCount(tester), greaterThan(before));
    expect(FollowUpdatesService.taskRunning.value, isFalse);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets(
    'enabled page explains unavailable scanner and keeps history idle',
    (tester) async {
      await pumpPage(tester);

      expect(
        find.text(followUpdateScannerUnavailableMessage.tl),
        findsOneWidget,
      );
      expect(find.text('Displayed scan state is historical'.tl), findsWidgets);
      expect(find.text('Checking updates'.tl), findsNothing);
      expect(find.text('Retry'.tl), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );

  testWidgets('all enabled pause entries give immediate unavailable feedback', (
    tester,
  ) async {
    await pumpPage(tester);

    for (var i = 0; i < 10; i++) {
      await tapPauseEntryAndExpectFreshFeedback(
        tester,
        find.byTooltip('Check Now'.tl),
      );
    }
    for (var i = 0; i < 10; i++) {
      await tapPauseEntryAndExpectFreshFeedback(
        tester,
        find.byTooltip('Update check progress'.tl),
      );
    }

    expect(find.text(followUpdateScannerUnavailableMessage.tl), findsWidgets);
    expect(find.text('Refresh started'.tl), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets(
    'enable feedback stays immediate across ten real enable-disable cycles',
    (tester) async {
      appdata.settings['followUpdatesEnabled'] = false;
      await pumpPage(tester);

      for (var i = 0; i < 10; i++) {
        await tapPauseEntryAndExpectFreshFeedback(
          tester,
          find.text('Enable Follow Updates'.tl),
        );
        expect(appdata.settings['followUpdatesEnabled'], isTrue);

        await tester.tap(find.byTooltip('more'.tl));
        await tester.pumpAndSettle();
        expect(find.text('Disable'.tl), findsOneWidget);
        await tester.tap(find.text('Disable'.tl));
        await tester.pumpAndSettle();
        expect(appdata.settings['followUpdatesEnabled'], isFalse);
        expect(FollowUpdatesService.taskRunning.value, isFalse);
        await tester.pump(const Duration(seconds: 2));
      }

      expect(find.text('Enable Follow Updates'.tl), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );
}
