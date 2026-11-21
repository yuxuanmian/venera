import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates_service.dart';
import 'package:venera/foundation/schedule/sqlite_schedule_repository.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/utils/translations.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDirectory;
  late String databasePath;
  final cache = NetworkFavoriteCacheManager();
  late Object? previousEnabledSources;
  late Object? previousFavorites;

  setUpAll(() async {
    await AppTranslation.init();
  });

  setUp(() async {
    appDirectory = await Directory.systemTemp.createTemp(
      'venera-retirement-service-app-',
    );
    App.dataPath = appDirectory.path;
    App.cachePath = appDirectory.path;
    databasePath =
        '${appDirectory.path}${Platform.pathSeparator}network_favorite_cache.db';
    previousEnabledSources = appdata.settings['enabledSources'];
    previousFavorites = appdata.settings['favorites'];
    appdata.settings['enabledSources'] = <String>[retirementSourceA];
    appdata.settings['favorites'] = <String>[retirementSourceA];
    await cache.init(databasePath: databasePath, migrateLegacy: false);
    seedRetirementHistory(databasePath);
    FollowUpdatesService.disposeChecker();
  });

  tearDown(() async {
    FollowUpdatesService.disposeChecker();
    ComicSourceManager().remove(retirementSourceA);
    ComicSourceManager().remove('retire_source_a');
    appdata.settings['enabledSources'] = previousEnabledSources;
    appdata.settings['favorites'] = previousFavorites;
    await judgmentStateRepository.close();
    await scheduleStateRepository.close();
    cache.close();
    try {
      await appDirectory.delete(recursive: true);
    } on PathAccessException {
      // Windows may release a native SQLite handle just after dispose.
    }
  });

  void installLoggedInSource(RetirementFakeSource fake) {
    final source = fake.buildComicSource(declaresSourceUnread: true);
    source.data['account'] = <String, dynamic>{'fixture': true};
    final manager = ComicSourceManager();
    manager.remove(fake.sourceKey);
    manager.add(source);
  }

  void seedServiceHistory(String sourceKey) {
    final database = sqlite3.open(databasePath);
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
    cache.notifyListeners();

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

  testWidgets('legacy unread stays isolated from tracking and recent updates', (
    tester,
  ) async {
    const serviceSourceKey = 'retire_source_a';
    final fake = RetirementFakeSource(sourceKey: serviceSourceKey);
    installLoggedInSource(fake);
    appdata.settings['enabledSources'] = <String>[serviceSourceKey];
    appdata.settings['favorites'] = <String>[serviceSourceKey];
    seedServiceHistory(serviceSourceKey);

    await tester.runAsync(() async {
      await FollowUpdatesService.initChecker();
      await FollowUpdatesService.initChecker();
    });
    // Startup ran with an incomplete cache. Detach its background consumer
    // so the notification below exercises the page's local refresh in isolation.
    FollowUpdatesService.disposeChecker();
    final database = sqlite3.open(databasePath);
    try {
      database.execute(
        '''UPDATE favorite_folders SET full_cache_at = ?
             WHERE source_key = ? AND folder_id = ?''',
        [fixtureNow.millisecondsSinceEpoch, serviceSourceKey, 'service-folder'],
      );
      expect(
        database
            .select(
              '''SELECT has_new_update FROM comic_check_state
               WHERE source_key = ? AND comic_id = ?''',
              [serviceSourceKey, 'service-retire-a'],
            )
            .single['has_new_update'],
        1,
      );
      expect(
        database.select(
          "SELECT value FROM metadata WHERE key = 'follow_up_006_migration'",
        ),
        isEmpty,
        reason: 'the legacy migration no longer exists',
      );
    } finally {
      database.dispose();
    }

    expect(followUpdateCoordinator.evaluateGate().satisfiedSourceKeys, {
      serviceSourceKey,
    });
    await pumpPage(tester);
    await tester.pumpAndSettle();
    expect(find.text('No recent updates found'.tl), findsOneWidget);
    expect(find.text('service-retire-a'), findsNothing);
    expect(fake.counters.detailCalls, 0);
    final beforeNotification = snapshotRetirementState(databasePath);
    cache.notifyListeners();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.text('No recent updates found'.tl), findsOneWidget);
    expect(find.text('service-retire-a'), findsNothing);
    expect(fake.counters.detailCalls, 0);
    expect(FollowUpdatesService.taskRunning, isFalse);
    expect(snapshotRetirementState(databasePath), beforeNotification);
    expect(
      await judgmentStateRepository.readFor(
        serviceSourceKey,
        'service-retire-a',
      ),
      isNull,
    );
  });
}
