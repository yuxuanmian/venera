import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
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

  void setHasNewUpdate(int value, String sourceKey, String comicId) {
    final database = sqlite3.open(fixture.databasePath);
    try {
      database.execute(
        '''UPDATE comic_check_state SET has_new_update = ?
           WHERE source_key = ? AND comic_id = ?''',
        [value, sourceKey, comicId],
      );
    } finally {
      database.dispose();
    }
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

  test('init, cancel, and retired scan methods remain idle', () async {
    FollowUpdatesService.initChecker();
    FollowUpdatesService.initChecker();
    FollowUpdatesService.cancelChecking();
    FollowUpdatesService.onAppResumed();
    FollowUpdatesService.startBaseline();
    await FollowUpdatesService.runCheckNow();
    await FollowUpdatesService.forceScanAll();
    await FollowUpdatesService.refreshRandomComics();

    expect(FollowUpdatesService.taskRunning.value, isFalse);
    expect(FollowUpdatesService.baselineStatus.value, isNull);
  });

  test('dispose twice and reinit do not leave a duplicate listener', () {
    FollowUpdatesService.initChecker();
    FollowUpdatesService.initChecker();
    FollowUpdatesService.disposeChecker();
    FollowUpdatesService.disposeChecker();
    FollowUpdatesService.initChecker();
    fixture.cache.notifyListeners();

    expect(FollowUpdatesService.taskRunning.value, isFalse);
    expect(FollowUpdatesService.baselineStatus.value, isNull);
  });

  testWidgets(
    'the real historical page refreshes through one reusable cache listener',
    (tester) async {
      const serviceSourceKey = 'retire_source_a';
      final fake = RetirementFakeSource(sourceKey: serviceSourceKey);
      installLoggedInSource(fake);
      appdata.settings['enabledSources'] = <String>[serviceSourceKey];
      appdata.settings['favorites'] = <String>[serviceSourceKey];
      seedServiceHistory(serviceSourceKey);

      FollowUpdatesService.initChecker();
      FollowUpdatesService.initChecker();
      await pumpPage(tester);
      expect(find.text('service-retire-a'), findsWidgets);

      // A cache notification with the service attached refreshes the actual
      // FollowUpdatesPage against the same singleton database.
      setHasNewUpdate(0, serviceSourceKey, 'service-retire-a');
      final beforeNotification = snapshotRetirementState(fixture.databasePath);
      fixture.cache.notifyListeners();
      await tester.pump();
      expect(find.text('service-retire-a'), findsNothing);
      expect(fake.counters.detailCalls, 0);
      expect(FollowUpdatesService.taskRunning.value, isFalse);
      expect(snapshotRetirementState(fixture.databasePath), beforeNotification);

      // After disposal the view must not refresh from cache notifications.
      FollowUpdatesService.disposeChecker();
      setHasNewUpdate(1, serviceSourceKey, 'service-retire-a');
      fixture.cache.notifyListeners();
      await tester.pump();
      expect(find.text('service-retire-a'), findsNothing);
      expect(fake.counters.detailCalls, 0);

      // Reinitialization restores one listener and one subsequent refresh.
      FollowUpdatesService.initChecker();
      fixture.cache.notifyListeners();
      await tester.pump();
      expect(find.text('service-retire-a'), findsWidgets);
      expect(fake.counters.detailCalls, 0);
      expect(FollowUpdatesService.taskRunning.value, isFalse);
    },
  );
}
