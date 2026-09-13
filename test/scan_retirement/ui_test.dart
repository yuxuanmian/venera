import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
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
  late Object? previousFollowUpdatesFolder;

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
    previousFollowUpdatesFolder = appdata.settings['followUpdatesFolder'];
    appdata.settings['enabledSources'] = <String>[uiSourceKey];
    appdata.settings['favorites'] = <String>[uiSourceKey];
    appdata.settings['followUpdatesEnabled'] = true;
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
    appdata.settings['followUpdatesFolder'] = previousFollowUpdatesFolder;
    ComicSourceManager().remove(uiSourceKey);
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

  /// The gate's explanation heading.
  ///
  /// The enabled page no longer announces an unavailable scanner: follow-up is
  /// live again, and the page's job is now to explain **which pre-condition** is
  /// missing rather than that the feature is dead.
  Finder gateHeading() => find.text('Favorites are not fully cached yet'.tl);

  testWidgets(
    'the enabled page explains the missing pre-condition, not a dead scanner',
    (tester) async {
      await pumpPage(tester);

      expect(gateHeading(), findsOneWidget);
      expect(
        find.text(followUpdateScannerUnavailableMessage.tl),
        findsNothing,
        reason: 'the scanner is no longer unavailable',
      );
      // A gate that is not satisfied shows no list in any form — not even an
      // empty-state placeholder, which would read as a complete answer
      // (Contract F2.3).
      expect(find.text('No updates found'.tl), findsNothing);
      // And it offers the entry point that resolves it (F2.3).
      expect(find.text('Cache favorites completely'.tl), findsOneWidget);
    },
  );

  testWidgets('the enabled page stays operable and non-modal', (tester) async {
    await pumpPage(tester);

    // Contract F1.3 / FR-005: the page must remain usable and must not cover
    // itself with a modal or an indeterminate spinner.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Follow Updates'.tl), findsWidgets);

    // The progress entry is always present; it only reports, and never starts
    // work.  The manual "Check Now" entry lives in the list header, so it is
    // deliberately absent while the gate holds the list back.
    expect(find.byTooltip('Update check progress'.tl), findsOneWidget);
    expect(
      find.byTooltip('Check Now'.tl),
      findsNothing,
      reason:
          'a gate that is not satisfied shows no list, and the manual check '
          'entry belongs to that list header',
    );

    await tester.tap(find.byTooltip('Update check progress'.tl));
    await tester.pump(const Duration(milliseconds: 1));

    // Reporting the state of an idle round must not start one.
    expect(FollowUpdatesService.taskRunning, isFalse);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets(
    'enable and disable round-trip ten times without leaving work running',
    (tester) async {
      appdata.settings['followUpdatesEnabled'] = false;
      await pumpPage(tester);

      for (var i = 0; i < 10; i++) {
        await tester.tap(find.text('Enable Follow Updates'.tl));
        await tester.pump(const Duration(milliseconds: 1));
        expect(appdata.settings['followUpdatesEnabled'], isTrue);

        await tester.tap(find.byTooltip('more'.tl));
        await tester.pumpAndSettle();
        expect(find.text('Disable'.tl), findsOneWidget);
        await tester.tap(find.text('Disable'.tl));
        await tester.pumpAndSettle();
        expect(appdata.settings['followUpdatesEnabled'], isFalse);

        // Disabling must not leave a round behind.  This test drives a release
        // build's code path but not its device: no scan target is reachable
        // without an installed source, so nothing is acquired either way.
        FollowUpdatesService.cancelChecking();
        await tester.pump(const Duration(milliseconds: 1));
        expect(FollowUpdatesService.taskRunning, isFalse);
        await tester.pump(const Duration(seconds: 2));
      }

      expect(find.text('Enable Follow Updates'.tl), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );
}
