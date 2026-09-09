import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/translations.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDirectory;
  late RetirementFixture fixture;

  setUpAll(() async {
    await AppTranslation.init();
    appDirectory = await Directory.systemTemp.createTemp(
      'venera-retirement-actions-app-',
    );
    App.dataPath = appDirectory.path;
    App.cachePath = appDirectory.path;
    await HistoryManager().init();
    await LocalManager().init();
  });

  tearDownAll(() async {
    ComicSourceManager().remove(retirementSourceA);
    HistoryManager().close();
    LocalManager().dispose();
    try {
      await appDirectory.delete(recursive: true);
    } on PathAccessException {
      // Windows may release a native SQLite handle just after dispose.
    }
  });

  setUp(() async {
    fixture = await createRetirementFixture();
  });

  tearDown(() async {
    ComicSourceManager().remove(retirementSourceA);
    await fixture.dispose();
  });

  void registerSource(RetirementFakeSource source, {FavoriteData? data}) {
    final sources = ComicSourceManager();
    sources.remove(source.sourceKey);
    sources.add(source.buildComicSource(favoriteData: data));
  }

  Future<void> pumpPage(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: child,
        builder: (context, child) => WindowFrame(child!),
      ),
    );
    await tester.pump();
  }

  String rowKey(String table, Map<String, Object?> row) {
    final columns = switch (table) {
      'metadata' => ['key'],
      'favorite_folders' => ['source_key', 'folder_id'],
      'favorite_pages' => [
        'source_key',
        'folder_id',
        'page_index',
        'request_token',
      ],
      'favorite_items' => ['source_key', 'folder_id', 'page_index', 'comic_id'],
      'favorite_membership' => ['source_key', 'folder_id', 'comic_id'],
      'comic_check_state' => ['source_key', 'comic_id'],
      'favorite_update_scan_state' => ['source_key', 'folder_id'],
      'scan_queue' => ['run_id', 'source_key', 'comic_id'],
      _ => const <String>[],
    };
    return jsonEncode([for (final column in columns) row[column]]);
  }

  Set<String> changedFields(
    Map<String, List<Map<String, Object?>>> before,
    Map<String, List<Map<String, Object?>>> after,
  ) {
    final changes = <String>{};
    for (final table in {...before.keys, ...after.keys}) {
      final beforeRows = {
        for (final row in before[table] ?? <Map<String, Object?>>[])
          rowKey(table, row): row,
      };
      final afterRows = {
        for (final row in after[table] ?? <Map<String, Object?>>[])
          rowKey(table, row): row,
      };
      for (final key in {...beforeRows.keys, ...afterRows.keys}) {
        final beforeRow = beforeRows[key];
        final afterRow = afterRows[key];
        if (beforeRow == null || afterRow == null) {
          changes.add('$table:$key:<row>');
          continue;
        }
        for (final column in {...beforeRow.keys, ...afterRow.keys}) {
          if (beforeRow[column] != afterRow[column]) {
            changes.add('$table:$key:$column');
          }
        }
      }
    }
    return changes;
  }

  void seedRetireDState() {
    final database = sqlite3.open(fixture.databasePath);
    try {
      final state = jsonEncode({
        'updatedAt': fixtureLegacyUpdate.toIso8601String(),
        'latestChapterId': 'chapter-d-10',
        'chapterCount': 10,
      });
      final yesterday = fixtureYesterday.millisecondsSinceEpoch;
      final nextWeek = fixtureNextWeek.millisecondsSinceEpoch;
      database.execute(
        '''
        INSERT OR REPLACE INTO comic_check_state
          (source_key, comic_id, last_update_time, update_marker, update_state,
           last_check_time, has_new_update, retry_after, check_failures,
           check_not_found_count, check_suspect_gone, baseline_at,
           source_activity_at, next_check_at, auto_hot_until, manual_hot_until,
           manual_hot_enabled, old_schedule_jitter_applied, source_update_metadata)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
        [
          retirementSourceA,
          'retire-d',
          fixtureLegacyUpdate.toIso8601String(),
          'legacy-test|chapter-d-10',
          state,
          yesterday,
          1,
          nextWeek,
          3,
          4,
          1,
          yesterday,
          yesterday,
          nextWeek,
          nextWeek,
          nextWeek,
          1,
          1,
          jsonEncode({'source': 'retirement-d'}),
        ],
      );
    } finally {
      database.dispose();
    }
  }

  test('mark-read changes only the target comic update flag', () {
    const folder = NetworkFavoriteFolderRef(
      sourceKey: retirementSourceA,
      folderId: retirementFolderOne,
    );
    final beforeScan = snapshotRetirementState(fixture.databasePath);
    final beforeCache = snapshotRetirementCacheState(fixture.databasePath);
    final before = fixture.cache
        .getComicsWithUpdatesInfo(folder)
        .firstWhere((item) => item.id == 'retire-a');

    fixture.cache.markReadInAllFolders(retirementSourceA, 'retire-a');
    final afterScan = snapshotRetirementState(fixture.databasePath);
    final after = fixture.cache
        .getComicsWithUpdatesInfo(folder)
        .firstWhere((item) => item.id == 'retire-a');

    expect(before.hasNewUpdate, isTrue);
    expect(after.hasNewUpdate, isFalse);
    expect(after.updateMarker, before.updateMarker);
    expect(after.updateState?.latestChapterId, 'chapter-10');
    expect(after.lastCheckTime, before.lastCheckTime);
    expect(after.retryAfter, before.retryAfter);
    expect(after.checkFailures, before.checkFailures);
    expect(after.checkNotFoundCount, before.checkNotFoundCount);
    expect(after.isSuspectGone, before.isSuspectGone);
    expect(after.baselineAt, before.baselineAt);
    expect(after.sourceActivityAt, before.sourceActivityAt);
    expect(after.nextCheckAt, before.nextCheckAt);
    expect(after.autoHotUntil, before.autoHotUntil);
    expect(after.manualHotUntil, before.manualHotUntil);
    expect(after.manualHotEnabled, before.manualHotEnabled);
    expect(after.oldScheduleJitterApplied, before.oldScheduleJitterApplied);
    expect(after.sourceUpdateMetadata, before.sourceUpdateMetadata);
    final changed = changedFields(beforeScan, afterScan);
    expect(changed, {
      'comic_check_state:${jsonEncode([retirementSourceA, 'retire-a'])}:has_new_update',
    });
    expect(snapshotRetirementCacheState(fixture.databasePath), beforeCache);
  });

  test(
    'explicit clear is scoped across folders and only clears its four fields',
    () {
      seedRetireDState();
      const folderOne = NetworkFavoriteFolderRef(
        sourceKey: retirementSourceA,
        folderId: retirementFolderOne,
      );
      const folderTwo = NetworkFavoriteFolderRef(
        sourceKey: retirementSourceA,
        folderId: retirementFolderTwo,
      );
      expect(
        fixture.cache
            .getComicsWithUpdatesInfo(folderOne)
            .firstWhere((item) => item.id == 'retire-d')
            .isSuspectGone,
        isTrue,
      );
      expect(
        fixture.cache
            .getComicsWithUpdatesInfo(folderTwo)
            .firstWhere((item) => item.id == 'retire-d')
            .isSuspectGone,
        isTrue,
      );
      final beforeScan = snapshotRetirementState(fixture.databasePath);
      final beforeCache = snapshotRetirementCacheState(fixture.databasePath);

      fixture.cache.clearComicSuspectGoneEverywhere(
        retirementSourceA,
        'retire-d',
      );

      for (final folder in [folderOne, folderTwo]) {
        final item = fixture.cache
            .getComicsWithUpdatesInfo(folder)
            .firstWhere((item) => item.id == 'retire-d');
        expect(item.isSuspectGone, isFalse);
        expect(item.checkFailures, 0);
        expect(item.checkNotFoundCount, 0);
        expect(item.retryAfter, isNull);
        expect(item.updateMarker, 'legacy-test|chapter-d-10');
        expect(item.updateState?.latestChapterId, 'chapter-d-10');
        expect(item.lastCheckTime, isNotNull);
        expect(item.baselineAt, isNotNull);
        expect(item.sourceActivityAt, isNotNull);
        expect(item.nextCheckAt, isNotNull);
        expect(item.manualHotEnabled, isTrue);
      }

      final changed = changedFields(
        beforeScan,
        snapshotRetirementState(fixture.databasePath),
      );
      final dKey = jsonEncode([retirementSourceA, 'retire-d']);
      expect(changed, {
        'comic_check_state:$dKey:retry_after',
        'comic_check_state:$dKey:check_failures',
        'comic_check_state:$dKey:check_not_found_count',
        'comic_check_state:$dKey:check_suspect_gone',
      });
      expect(snapshotRetirementCacheState(fixture.databasePath), beforeCache);
    },
  );

  testWidgets(
    'the real reader start chain marks read without touching evidence',
    (tester) async {
      final source = RetirementFakeSource(
        sourceKey: retirementSourceA,
        readerPagesPending: true,
      );
      registerSource(source);
      const folder = NetworkFavoriteFolderRef(
        sourceKey: retirementSourceA,
        folderId: retirementFolderOne,
      );
      final beforeScan = snapshotRetirementState(fixture.databasePath);
      final beforeCache = snapshotRetirementCacheState(fixture.databasePath);

      await pumpPage(
        tester,
        const ReaderWithLoading(id: 'retire-a', sourceKey: retirementSourceA),
      );
      await tester.pump(const Duration(milliseconds: 450));

      expect(find.byType(Reader), findsOneWidget);
      expect(source.counters.detailCalls, 1);
      expect(source.counters.readerPageCalls, 1);
      final afterScan = snapshotRetirementState(fixture.databasePath);
      final changed = changedFields(beforeScan, afterScan);
      final readKey = jsonEncode([retirementSourceA, 'retire-a']);
      expect(changed, {'comic_check_state:$readKey:has_new_update'});
      expect(
        afterScan['comic_check_state']!.firstWhere(
          (row) => row['comic_id'] == 'retire-a',
        )['has_new_update'],
        0,
      );
      expect(snapshotRetirementCacheState(fixture.databasePath), beforeCache);
      expect(
        fixture.cache.getComicsWithUpdatesInfo(folder),
        contains(
          isA<FavoriteItem>().having((item) => item.id, 'id', 'retire-a'),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: const SizedBox.shrink(),
          builder: (context, child) => WindowFrame(child!),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('the real detail clear handler changes only clear fields', (
    tester,
  ) async {
    final source = RetirementFakeSource(
      sourceKey: retirementSourceA,
      detailError: 'removed by source (404)',
    );
    registerSource(source);
    final beforeScan = snapshotRetirementState(fixture.databasePath);
    final beforeCache = snapshotRetirementCacheState(fixture.databasePath);

    await pumpPage(
      tester,
      const ComicPage(id: 'retire-b', sourceKey: retirementSourceA),
    );
    await tester.pumpAndSettle();
    expect(find.text('Clear Suspected Removed'.tl), findsOneWidget);

    await tester.tap(find.text('Clear Suspected Removed'.tl));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    final changed = changedFields(
      beforeScan,
      snapshotRetirementState(fixture.databasePath),
    );
    final bKey = jsonEncode([retirementSourceA, 'retire-b']);
    expect(changed, {
      'comic_check_state:$bKey:retry_after',
      'comic_check_state:$bKey:check_failures',
      'comic_check_state:$bKey:check_not_found_count',
      'comic_check_state:$bKey:check_suspect_gone',
    });
    expect(snapshotRetirementCacheState(fixture.databasePath), beforeCache);
    expect(source.counters.detailCalls, greaterThanOrEqualTo(4));
  });

  testWidgets('the real detail hot action preserves every non-hot field', (
    tester,
  ) async {
    final previousEnabled = appdata.settings['followUpdatesEnabled'];
    appdata.settings['followUpdatesEnabled'] = true;
    addTearDown(
      () => appdata.settings['followUpdatesEnabled'] = previousEnabled,
    );

    final source = RetirementFakeSource(sourceKey: retirementSourceA);
    final data = FavoriteData(
      key: retirementSourceA,
      title: 'Retirement fake',
      multiFolder: false,
      loadComic: null,
      loadNext: null,
    );
    registerSource(source, data: data);
    final beforeScan = snapshotRetirementState(fixture.databasePath);
    final beforeCache = snapshotRetirementCacheState(fixture.databasePath);

    await pumpPage(
      tester,
      const ComicPage(id: 'retire-a', sourceKey: retirementSourceA),
    );
    await tester.pumpAndSettle();
    final hotButton = find.byKey(
      const ValueKey('favorite-hot-window-hot-segment'),
    );
    expect(hotButton, findsOneWidget);

    await tester.tap(hotButton);
    await tester.pump();
    final afterEnable = snapshotRetirementState(fixture.databasePath);
    final enableChanged = changedFields(beforeScan, afterEnable);
    final aKey = jsonEncode([retirementSourceA, 'retire-a']);
    final allowedHot = {
      'manual_hot_enabled',
      'manual_hot_until',
      'next_check_at',
      'old_schedule_jitter_applied',
    };
    expect(enableChanged, isNotEmpty);
    expect(
      enableChanged.every(
        (field) =>
            field.startsWith('comic_check_state:$aKey:') &&
            allowedHot.contains(field.split(':').last),
      ),
      isTrue,
    );
    expect(
      afterEnable['comic_check_state']!.firstWhere(
        (row) => row['comic_id'] == 'retire-a',
      )['manual_hot_enabled'],
      1,
    );
    expect(snapshotRetirementCacheState(fixture.databasePath), beforeCache);

    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('favorite-hot-window-hot-segment')),
    );
    await tester.pump();
    final disableChanged = changedFields(
      afterEnable,
      snapshotRetirementState(fixture.databasePath),
    );
    expect(disableChanged, isNotEmpty);
    expect(
      disableChanged.every(
        (field) =>
            field.startsWith('comic_check_state:$aKey:') &&
            allowedHot.contains(field.split(':').last),
      ),
      isTrue,
    );
    expect(
      fixture.cache
          .getComicUpdateInfo(
            retirementSourceA,
            'retire-a',
            retirementFolderOne,
          )
          ?.manualHotEnabled,
      isFalse,
    );
  });
}
