import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_source/scan.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_update_availability.dart';
import 'package:venera/foundation/follow_updates_service.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late Object? previousEnabled;
  late Object? previousFavorites;
  late Object? previousFollowUpdates;

  /// A source the user has selected, enabled, signed in to and that can be
  /// scanned.
  ///
  /// It has no cached folders, which is the state the gate exists to catch: the
  /// criterion set is non-empty while the cache is empty, so the gate must stay
  /// closed.  With an empty criterion set the page would take the *different*
  /// "nothing to follow" branch and this file would stop testing the gate.
  const uiSourceKey = 'retirement_ui_source';

  ComicSource buildUiSource() => ComicSource(
    'Retirement UI fake',
    uiSourceKey,
    AccountConfig(null, null, null, () {}, null, null, null, null),
    null,
    null,
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
    scan: ScanCapabilities.supported(
      primary: ScanProducer.comic,
      comic: ScanCapability.comic(
        (comicId, request) async => null,
        evidenceSchema: '{"latestchapterid":"last_chapter.id"}',
      ),
    ),
  );

  setUpAll(() async {
    await AppTranslation.init();
  });

  setUp(() async {
    previousEnabled = appdata.settings['enabledSources'];
    previousFavorites = appdata.settings['favorites'];
    previousFollowUpdates = appdata.settings['followUpdatesEnabled'];
    appdata.settings['enabledSources'] = <String>[uiSourceKey];
    appdata.settings['favorites'] = <String>[uiSourceKey];
    final source = buildUiSource();
    source.data['account'] = <String, dynamic>{'fixture': true};
    final manager = ComicSourceManager();
    manager.remove(uiSourceKey);
    manager.add(source);
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
    ComicSourceManager().remove(uiSourceKey);
    FollowUpdatesService.cancelChecking();
    NetworkFavoriteCacheManager().close();
    try {
      await directory.delete(recursive: true);
    } on PathAccessException {
      // Windows may release a SQLite handle just after close.
    }
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: const FollowUpdatesPage(),
      ),
    );
    await tester.pump();
  }

  testWidgets('the recent updates gate explains how to sync the source', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.text('Favorites are not fully cached yet'.tl), findsOneWidget);
    expect(
      find.text('Select the source in Favorites and sync its favorites.'.tl),
      findsOneWidget,
    );
    expect(find.text(followUpdateScannerUnavailableMessage.tl), findsNothing);
    expect(find.text('No recent updates found'.tl), findsNothing);
  });

  testWidgets('opening the idle page leaves the check and cache idle', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Recent updates'.tl), findsOneWidget);
    expect(find.byTooltip('Check Now'.tl), findsNothing);
    expect(find.text('Cache favorites completely'.tl), findsNothing);
    expect(FollowUpdatesService.taskRunning, isFalse);
    expect(FollowUpdatesService.isCachingFavorites, isFalse);
  });

  testWidgets(
    'a saved disabled setting leaves recent updates available without a toggle',
    (tester) async {
      appdata.settings['followUpdatesEnabled'] = false;
      await pumpPage(tester);

      expect(find.text('Recent updates'.tl), findsOneWidget);
      expect(
        find.text('Favorites are not fully cached yet'.tl),
        findsOneWidget,
      );
      expect(find.text('Follow updates disabled'.tl), findsNothing);
      expect(find.text('Enable Follow Updates'.tl), findsNothing);
      expect(find.byType(SwitchListTile), findsNothing);
    },
  );
}
