import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';
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

  testWidgets(
    'the real reader start chain clears the judgment flag, not the legacy column',
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

      // The update flag lives in judgment state now, so that is where the
      // reader's mark-read has to land (Contract F4).
      await judgmentStateRepository.ensureOpen();
      await judgmentStateRepository.applyBatch([
        JudgmentState(
          sourceKey: retirementSourceA,
          comicId: 'retire-a',
          lastDecision: JudgmentConclusion.changed,
          lastReason: JudgmentReason.later,
          decidedAtMs: 1,
          hasNewUpdate: true,
          algorithmVersion: judgmentAlgorithmVersion,
        ),
      ]);

      await pumpPage(
        tester,
        const ReaderWithLoading(id: 'retire-a', sourceKey: retirementSourceA),
      );
      await tester.pump(const Duration(milliseconds: 450));

      expect(find.byType(Reader), findsOneWidget);
      expect(source.counters.detailCalls, 1);
      expect(source.counters.readerPageCalls, 1);
      expect(
        (await judgmentStateRepository.readFor(
          retirementSourceA,
          'retire-a',
        ))!.hasNewUpdate,
        isFalse,
        reason: 'opening the reader is what marks a comic read',
      );

      // The legacy marker store is no longer written: its flag is raised by
      // nothing in this build, so clearing it would be clearing a fossil.
      expect(
        changedFields(
          beforeScan,
          snapshotRetirementState(fixture.databasePath),
        ),
        isEmpty,
      );
      expect(snapshotRetirementCacheState(fixture.databasePath), beforeCache);
      expect(
        fixture.cache.getComicsWithUpdatesInfo(folder),
        contains(
          isA<FavoriteItem>().having((item) => item.id, 'id', 'retire-a'),
        ),
      );

      await judgmentStateRepository.clear();

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

  testWidgets('the removed suspected-removed handler is gone, not hidden', (
    tester,
  ) async {
    // FR-023: this test used to drive the "Clear Suspected Removed" button and
    // assert it cleared four `comic_check_state` columns.  Both the button and
    // the verdict behind it were retired, so the assertion that remains is that
    // neither the control nor the fields it wrote come back.
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

    expect(find.text('Clear Suspected Removed'.tl), findsNothing);
    // Opening the page writes nothing: the retired handler was the only writer
    // of those four fields, so a clean snapshot proves it did not run.
    expect(snapshotRetirementState(fixture.databasePath), beforeScan);
    expect(snapshotRetirementCacheState(fixture.databasePath), beforeCache);
  });

  testWidgets('the detail hot segment is read-only and writes nothing', (
    tester,
  ) async {
    // 007 FR-001 / FR-011.  This test used to tap the segment twice and assert
    // that `manual_hot_enabled` went to 1 and back to 0 — i.e. it asserted the
    // retired write path from the user's side.  The manual hot window is gone,
    // so the assertion inverts: the segment may be absent (no check record:
    // this fixture has no schedule store attached) or a read-only status, and in
    // **neither** shape can a tap or a long-press write anything at all.
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
    // Deterministic here: this fixture has no schedule store attached, so the
    // comic has no check record and the indicator is not rendered at all
    // (Contract W2 / FR-008).  The shape of the segment **when a record
    // exists** is asserted in follow_update_hot_window_widget_test.dart and
    // follow_updates/details_indicator_test.dart.
    expect(
      hotButton,
      findsNothing,
      reason: 'no check record ⇒ no indicator, and therefore no control',
    );

    // Whatever is on the page, the retired write path cannot be reached: the
    // legacy store's `manual_hot_*` / `next_check_at` columns are untouched.
    expect(snapshotRetirementState(fixture.databasePath), beforeScan);
    expect(snapshotRetirementCacheState(fixture.databasePath), beforeCache);

    // And the action wording is not rendered anywhere on the page.
    expect(find.text('Enable 14-day hot window'.tl), findsNothing);
    expect(find.text('Disable 14-day hot window'.tl), findsNothing);
  });
}
