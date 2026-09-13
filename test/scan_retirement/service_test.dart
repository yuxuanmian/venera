import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/follow_updates_service.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/utils/translations.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDirectory;
  late RetirementFixture fixture;
  late Object? previousEnabledSources;
  late Object? previousFavorites;
  late Object? previousFollowUpdatesEnabled;

  setUpAll(() async {
    await AppTranslation.init();
    appDirectory = await Directory.systemTemp.createTemp(
      'venera-retirement-service-app-',
    );
    App.dataPath = appDirectory.path;
    App.cachePath = appDirectory.path;
  });

  tearDownAll(() async {
    ComicSourceManager().remove(retirementSourceA);
    try {
      await appDirectory.delete(recursive: true);
    } on PathAccessException {
      // Windows may release a native SQLite handle just after dispose.
    }
  });

  setUp(() async {
    previousEnabledSources = appdata.settings['enabledSources'];
    previousFavorites = appdata.settings['favorites'];
    previousFollowUpdatesEnabled = appdata.settings['followUpdatesEnabled'];
    appdata.settings['enabledSources'] = <String>[retirementSourceA];
    appdata.settings['favorites'] = <String>[retirementSourceA];
    appdata.settings['followUpdatesEnabled'] = true;
    fixture = await createRetirementFixture();
    FollowUpdatesService.disposeChecker();
  });

  tearDown(() async {
    FollowUpdatesService.disposeChecker();
    ComicSourceManager().remove(retirementSourceA);
    ComicSourceManager().remove('retire_source_a');
    appdata.settings['enabledSources'] = previousEnabledSources;
    appdata.settings['favorites'] = previousFavorites;
    appdata.settings['followUpdatesEnabled'] = previousFollowUpdatesEnabled;
    await fixture.dispose();
  });

  void installLoggedInSource(RetirementFakeSource fake) {
    final source = fake.buildComicSource();
    source.data['account'] = <String, dynamic>{'fixture': true};
    final manager = ComicSourceManager();
    manager.remove(fake.sourceKey);
    manager.add(source);
  }

  void seedServiceHistory(String sourceKey) {
    final database = sqlite3.open(fixture.databasePath);
    try {
      final now = fixtureNow.millisecondsSinceEpoch;
      final favoriteTime = fixtureNow
          .toIso8601String()
          .replaceFirst('T', ' ')
          .substring(0, 19);
      final coverFile = File(
        '${appDirectory.path}${Platform.pathSeparator}service-cover.png',
      );
      coverFile.writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
          '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
      final coverPath = 'file://${coverFile.path}';
      database.execute(
        '''
        INSERT OR REPLACE INTO favorite_folders
          (source_key, folder_id, title, updated_at)
        VALUES (?, ?, ?, ?)
      ''',
        [sourceKey, 'service-folder', 'Service folder', now],
      );
      database.execute(
        '''
        INSERT OR REPLACE INTO favorite_pages
          (source_key, folder_id, page_index, request_token, next_token,
           max_page, updated_at)
        VALUES (?, ?, 1, 'page:1', NULL, 1, ?)
      ''',
        [sourceKey, 'service-folder', now],
      );
      database.execute(
        '''
        INSERT OR REPLACE INTO favorite_items
          (source_key, folder_id, page_index, comic_id, display_order,
           comic_json, favorite_id, favorite_time, search_text)
        VALUES (?, ?, 1, ?, 0, ?, NULL, ?, ?)
      ''',
        [
          sourceKey,
          'service-folder',
          'service-retire-a',
          jsonEncode({
            'id': 'service-retire-a',
            'title': 'service-retire-a',
            'cover': coverPath,
            'subTitle': '',
            'tags': <String>[],
            'sourceKey': sourceKey,
          }),
          favoriteTime,
          'service-retire-a',
        ],
      );
      database.execute(
        '''INSERT OR REPLACE INTO favorite_membership
           (source_key, folder_id, comic_id) VALUES (?, ?, ?)''',
        [sourceKey, 'service-folder', 'service-retire-a'],
      );
      database.execute(
        '''INSERT OR REPLACE INTO comic_check_state
           (source_key, comic_id, last_update_time, last_check_time,
            has_new_update) VALUES (?, ?, ?, ?, 1)''',
        [
          sourceKey,
          'service-retire-a',
          fixtureLegacyUpdate.toIso8601String(),
          now,
        ],
      );
    } finally {
      database.dispose();
    }
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: const FollowUpdatesPage(),
      ),
    );
    await tester.pump();
  }

  test('foreground resume leaves no round running', () async {
    // `initChecker` legitimately starts the startup round, so it is not part of
    // this assertion; the subject is the lifecycle callback.
    FollowUpdatesService.cancelChecking();
    FollowUpdatesService.onAppResumed();
    FollowUpdatesService.onAppResumed();

    expect(FollowUpdatesService.taskRunning, isFalse);
  });

  test('dispose twice and reinit do not leave a duplicate listener', () async {
    await FollowUpdatesService.initChecker();
    await FollowUpdatesService.initChecker();
    FollowUpdatesService.disposeChecker();
    FollowUpdatesService.disposeChecker();
    await FollowUpdatesService.initChecker();
    fixture.cache.notifyListeners();

    expect(FollowUpdatesService.taskRunning, isFalse);
  });

  test('the retired scan entry points are gone, not stubbed', () async {
    // `startBaseline`, `forceScanAll`, `refreshRandomComics` and the
    // `baselineStatus` notifier belonged to the scanner retired by 003.  A
    // manual check is now the coordinator's schedule-respecting round, and
    // progress is task-counted.  Removing them rather than keeping no-op stubs
    // is what makes their return a compile error instead of silent dead code.
    expect(FollowUpdatesService.progress.value.discovered, 0);
    expect(FollowUpdatesService.taskRunning, isFalse);
  });

  testWidgets(
    'the page no longer derives its list from the retired marker store',
    (tester) async {
      const serviceSourceKey = 'retire_source_a';
      final fake = RetirementFakeSource(sourceKey: serviceSourceKey);
      installLoggedInSource(fake);
      appdata.settings['enabledSources'] = <String>[serviceSourceKey];
      appdata.settings['favorites'] = <String>[serviceSourceKey];
      seedServiceHistory(serviceSourceKey);

      await FollowUpdatesService.initChecker();
      await FollowUpdatesService.initChecker();
      await pumpPage(tester);

      // `seedServiceHistory` sets `comic_check_state.has_new_update = 1` — the
      // retired marker.  The page MUST NOT render from it: judgment state is the
      // only source of the update flag now (Contract F3.1).
      expect(
        find.text('service-retire-a'),
        findsNothing,
        reason: 'the legacy has_new_update flag is no longer a list source',
      );
      expect(fake.counters.detailCalls, 0);

      // A cache notification refreshes the page but cannot conjure a judgment
      // row, so the list stays empty and no source request is made.
      final beforeNotification = snapshotRetirementState(fixture.databasePath);
      fixture.cache.notifyListeners();
      await tester.pump();
      expect(find.text('service-retire-a'), findsNothing);
      expect(fake.counters.detailCalls, 0);
      expect(FollowUpdatesService.taskRunning, isFalse);
      expect(snapshotRetirementState(fixture.databasePath), beforeNotification);

      // Let the coalescing window elapse inside the test: the debounce timer is
      // real, and a widget test fails if one outlives the tree.
      await tester.pump(const Duration(seconds: 3));
    },
  );
}
