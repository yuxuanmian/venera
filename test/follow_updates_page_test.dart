import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_source/scan.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_update_schedule.dart';
import 'package:venera/foundation/follow_updates_service.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/schedule/schedule_state.dart';
import 'package:venera/foundation/schedule/sqlite_schedule_repository.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sourceKey = 'gate_source';
  const syncHelp = 'Select the source in Favorites and sync its favorites.';
  const folder = NetworkFavoriteFolderRef(
    sourceKey: sourceKey,
    folderId: '',
    title: 'Remote',
  );

  late Directory tempDir;
  late List<String> fixtureComicIds;
  late Object? previousLanguage;
  late Object? previousEnabledSources;
  late Object? previousFavorites;
  late Object? previousFollowUpdatesEnabled;

  Future<void> markCacheComplete({
    String key = sourceKey,
    String folderId = '',
  }) async {
    final db = sqlite3.open(
      '${tempDir.path}${Platform.pathSeparator}network_favorite_cache.db',
    );
    try {
      db.execute(
        '''UPDATE favorite_folders SET full_cache_at = ?
           WHERE source_key = ? AND folder_id = ?''',
        [DateTime.now().millisecondsSinceEpoch, key, folderId],
      );
    } finally {
      db.dispose();
    }
  }

  Future<void> flagUpdate(String comicId, {String key = sourceKey}) async {
    await judgmentStateRepository.ensureOpen();
    await judgmentStateRepository.applyBatch([
      JudgmentState(
        sourceKey: key,
        comicId: comicId,
        lastDecision: JudgmentConclusion.changed,
        lastReason: JudgmentReason.later,
        decidedAtMs: 1,
        hasNewUpdate: true,
        algorithmVersion: judgmentAlgorithmVersion,
      ),
    ]);
  }

  ComicSource buildSource({
    String key = sourceKey,
    String title = 'Gate source',
    bool declaresUnread = false,
    required List<String> comicIds,
  }) => ComicSource(
    title,
    key,
    AccountConfig(null, null, null, () {}, null, null, null, null),
    null,
    null,
    FavoriteData(
      key: key,
      title: title,
      multiFolder: false,
      loadComic: (page, [folder]) async =>
          Res([for (final id in comicIds) _comic(id, key: key)], subData: 1),
      loadNext: null,
    ),
    const [],
    null,
    null,
    (id) async => Res(
      ComicDetails.fromJson({
        'title': 'Comic $id',
        'subtitle': 'Author',
        'cover': _comic(id, key: key).cover,
        'description': 'Details loaded',
        'tags': <String, List<String>>{},
        'chapters': {'chapter': 'Chapter 1'},
        'sourceKey': key,
        'comicId': id,
        'isFavorite': true,
        'isLiked': false,
      }),
    ),
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
    // Scan-capable, so the source belongs to the criterion set.  Without it the
    // page takes the different "nothing to follow" branch and this file would
    // stop testing the gate.
    scan: ScanCapabilities.supported(
      primary: ScanProducer.comic,
      comic: ScanCapability.comic(
        (comicId, request) async => null,
        evidenceSchema: declaresUnread
            ? '{"latestchapterid":"last_chapter.id","sourceUnread":"unread"}'
            : '{"latestchapterid":"last_chapter.id"}',
      ),
    ),
  );

  /// Installs a second tracked source whose cache **is** complete.
  ///
  /// This is what makes the per-source rule testable: with one source the old
  /// all-or-nothing gate and the new per-source rule agree, so only a second
  /// source with the opposite state can tell them apart.  Its comics are named
  /// `c-*` so a title in an assertion identifies its source unambiguously.
  Future<String> installCompleteSource({bool declaresUnread = false}) async {
    const completeKey = 'complete_source';
    const completeFolder = NetworkFavoriteFolderRef(
      sourceKey: completeKey,
      folderId: '',
      title: 'Remote',
    );
    final source = buildSource(
      key: completeKey,
      title: 'Complete source',
      declaresUnread: declaresUnread,
      comicIds: const ['c-one', 'c-two', 'c-three'],
    );
    source.data['account'] = <String, dynamic>{'fixture': true};
    ComicSourceManager().remove(completeKey);
    ComicSourceManager().add(source);
    addTearDown(() => ComicSourceManager().remove(completeKey));

    final data = source.favoriteData!;
    final cache = NetworkFavoriteCacheManager();
    await cache.refreshFolders(data);
    await cache.refreshPage(data, completeFolder, 1);
    await markCacheComplete(key: completeKey);

    // Tracked as well, or it is not part of the criterion set at all.
    appdata.settings['enabledSources'] = <String>[sourceKey, completeKey];
    appdata.settings['favorites'] = <String>[sourceKey, completeKey];
    return completeKey;
  }

  setUpAll(() async {
    await AppTranslation.init();
    // A real one-pixel PNG, so the list's cover loader resolves locally.
    File(_coverPath()).writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
  });

  setUp(() async {
    previousEnabledSources = appdata.settings['enabledSources'];
    previousFavorites = appdata.settings['favorites'];
    previousLanguage = appdata.settings['language'];
    previousFollowUpdatesEnabled = appdata.settings['followUpdatesEnabled'];
    tempDir = await Directory.systemTemp.createTemp('venera-follow-gate-');
    App.dataPath = tempDir.path;
    App.cachePath = tempDir.path;

    await HistoryManager().init();
    final cache = NetworkFavoriteCacheManager();
    await cache.init(
      databasePath:
          '${tempDir.path}${Platform.pathSeparator}network_favorite_cache.db',
      migrateLegacy: false,
    );
    fixtureComicIds = ['one', 'two', 'three', 'expired', 'manual'];
    final source = buildSource(comicIds: fixtureComicIds);
    source.data['account'] = <String, dynamic>{'fixture': true};
    ComicSourceManager().remove(sourceKey);
    ComicSourceManager().add(source);
    appdata.settings['enabledSources'] = <String>[sourceKey];
    appdata.settings['favorites'] = <String>[sourceKey];
    appdata.settings['followUpdatesEnabled'] = true;
    appdata.settings['language'] = 'system';

    // Cache the folder but NOT its completeness mark: the gate must stay shut,
    // which is exactly the "list would be incomplete" case F2 exists for.
    final data = source.favoriteData!;
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);
    expect(cache.countCachedComicsInFolders([folder]), fixtureComicIds.length);
    expect(cache.getFullCacheStatus(folder).isComplete, isFalse);
  });

  tearDown(() async {
    await judgmentStateRepository.close();
    await scheduleStateRepository.close();
    ComicSourceManager().remove(sourceKey);
    appdata.settings['enabledSources'] = previousEnabledSources;
    appdata.settings['favorites'] = previousFavorites;
    appdata.settings['language'] = previousLanguage;
    appdata.settings['followUpdatesEnabled'] = previousFollowUpdatesEnabled;
    HistoryManager().close();
    NetworkFavoriteCacheManager().close();
    try {
      await tempDir.delete(recursive: true);
    } on PathAccessException {
      // Windows may release a native SQLite handle just after dispose.
    } on PathNotFoundException {
      // Already gone.
    }
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: const FollowUpdatesPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Iterable<List<String>> sectionIds(WidgetTester tester) => tester
      .widgetList<SliverGridComics>(find.byType(SliverGridComics))
      .map((section) => section.comics.map((comic) => comic.id).toList());

  String dateLabel(WidgetTester tester, DateTime date) =>
      MaterialLocalizations.of(
        tester.element(find.byType(FollowUpdatesPage)),
      ).formatFullDate(date);

  Future<void> seedSchedule(List<ScheduleState> rows) async {
    await scheduleStateRepository.ensureOpen();
    await scheduleStateRepository.applyBatch(rows);
  }

  ScheduleState detected(
    String comicId,
    DateTime detectedAt, {
    String key = sourceKey,
  }) => ScheduleState(
    sourceKey: key,
    comicId: comicId,
    autoHotUntilMs: detectedAt
        .add(kFollowUpdateHotWindow)
        .millisecondsSinceEpoch,
    activityAtMs: DateTime(2020).millisecondsSinceEpoch,
  );

  Future<List<String>> seedPagedComics() async {
    final ids = List.generate(
      33,
      (index) => 'paged-${index.toString().padLeft(2, '0')}',
    );
    fixtureComicIds
      ..clear()
      ..addAll(ids);
    await NetworkFavoriteCacheManager().refreshPage(
      ComicSource.find(sourceKey)!.favoriteData!,
      folder,
      1,
    );
    await markCacheComplete();
    final latest = DateTime.now().subtract(const Duration(days: 1));
    final earlier = latest.subtract(const Duration(days: 1));
    await seedSchedule([
      for (final id in ids.take(31)) detected(id, latest),
      for (final id in ids.skip(31)) detected(id, earlier),
    ]);
    return ids;
  }

  testWidgets('the HOME card opens the recent updates page', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: const Scaffold(
          body: CustomScrollView(slivers: [FollowUpdatesWidget()]),
        ),
      ),
    );

    await tester.tap(find.text('Recent updates'.tl));
    await tester.pumpAndSettle();

    expect(find.byType(FollowUpdatesPage), findsOneWidget);
    expect(find.text('Recent updates'.tl), findsOneWidget);
  });

  testWidgets('an incomplete cache shows the gate until it is ready', (
    tester,
  ) async {
    final now = DateTime.now();
    await seedSchedule([detected('one', now)]);
    await pumpPage(tester);

    expect(find.text('Favorites are not fully cached yet'.tl), findsOneWidget);
    expect(find.text(syncHelp.tl), findsOneWidget);
    expect(find.text('Comic one'), findsNothing);
    expect(find.byType(TextField), findsNothing);

    await markCacheComplete();
    NetworkFavoriteCacheManager().notifyCacheChanged();
    await tester.pumpAndSettle();

    expect(find.text('Favorites are not fully cached yet'.tl), findsNothing);
    expect(find.text('Comic one'), findsOneWidget);
  });

  testWidgets('groups active automatic windows by local detection date', (
    tester,
  ) async {
    await markCacheComplete();
    final latest = DateTime.now().subtract(const Duration(days: 1));
    final earlier = latest.subtract(const Duration(days: 1));
    final expired = latest.subtract(kFollowUpdateHotWindow);
    await flagUpdate('expired');
    await seedSchedule([
      detected('two', latest),
      detected('one', latest),
      detected('three', earlier),
      detected('expired', expired),
      ScheduleState(
        sourceKey: sourceKey,
        comicId: 'manual',
        manualHotEnabled: true,
        manualHotUntilMs: latest
            .add(kFollowUpdateHotWindow)
            .millisecondsSinceEpoch,
      ),
    ]);
    appdata.settings['followUpdatesEnabled'] = false;
    await pumpPage(tester);

    final latestHeader = find.text(dateLabel(tester, latest));
    final earlierHeader = find.text(dateLabel(tester, earlier));
    expect(latestHeader, findsOneWidget);
    expect(earlierHeader, findsOneWidget);
    expect(
      tester.getTopLeft(latestHeader).dy,
      lessThan(tester.getTopLeft(earlierHeader).dy),
    );
    expect(sectionIds(tester), [
      ['one', 'two'],
      ['three'],
    ]);
  });

  testWidgets('a complete cache with no active windows shows the empty state', (
    tester,
  ) async {
    await markCacheComplete();
    await pumpPage(tester);

    expect(find.text('No recent updates found'.tl), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('search covers unloaded title, author, and tag matches', (
    tester,
  ) async {
    final ids = await seedPagedComics();
    await pumpPage(tester);
    expect(sectionIds(tester).single, ids.take(30));

    final search = find.byKey(const ValueKey('follow-up-search-recent'));
    for (final query in ['Omic paged-30', 'Late writer', 'Hidden genre']) {
      await tester.enterText(search, query);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(sectionIds(tester).single, ['paged-30']);
    }
    await tester.enterText(search, 'unmatched keyword');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('No matching updates found'.tl), findsOneWidget);

    await tester.tap(find.byTooltip('Clear'.tl));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(sectionIds(tester).single, ids.take(30));
  });

  testWidgets(
    'the next cursor extends a date section and starts the next one',
    (tester) async {
      final ids = await seedPagedComics();
      await pumpPage(tester);
      expect(sectionIds(tester).single, ids.take(30));

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -10000));
      await tester.pumpAndSettle();

      expect(sectionIds(tester), [ids.take(31), ids.skip(31)]);
      final last = tester
          .widgetList<SliverGridComics>(find.byType(SliverGridComics))
          .last;
      final first = tester
          .widgetList<SliverGridComics>(find.byType(SliverGridComics))
          .first;
      expect(first.key, isNot(last.key));
    },
  );

  testWidgets('a changed snapshot restarts pagination from the first page', (
    tester,
  ) async {
    final ids = await seedPagedComics();
    await pumpPage(tester);
    expect(sectionIds(tester).single, ids.take(30));

    await seedSchedule([
      detected('paged-00', DateTime.now().subtract(kFollowUpdateHotWindow)),
    ]);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -10000));
    await tester.pumpAndSettle();
    expect(sectionIds(tester).single, ids.skip(1).take(30));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -10000));
    await tester.pumpAndSettle();
    expect(sectionIds(tester), [ids.skip(1).take(30), ids.skip(31)]);
  });

  testWidgets('opening details preserves the flag and the recent entry', (
    tester,
  ) async {
    await markCacheComplete();
    await flagUpdate('one');
    await seedSchedule([detected('one', DateTime.now())]);
    await pumpPage(tester);

    await tester.tap(find.text('Comic one'));
    await tester.pumpAndSettle();

    final details = tester.widget<ComicPage>(find.byType(ComicPage));
    expect(details.id, 'one');
    final state = await judgmentStateRepository.readFor(sourceKey, 'one');
    expect(state?.hasNewUpdate, isTrue);

    App.rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Comic one'), findsOneWidget);
  });

  testWidgets('errors reading the schedule are reported and can be retried', (
    tester,
  ) async {
    await markCacheComplete();
    await seedSchedule([detected('one', DateTime.now())]);
    final db = sqlite3.open(scheduleStateRepository.databasePath);

    db.execute('ALTER TABLE schedule_state RENAME TO unavailable_schedule');

    await pumpPage(tester);
    expect(find.text('Update state could not be read'.tl), findsOneWidget);
    expect(find.text('No recent updates found'.tl), findsNothing);

    db.execute('ALTER TABLE unavailable_schedule RENAME TO schedule_state');
    await tester.tap(find.text('Retry'.tl));
    await tester.pumpAndSettle();
    expect(find.text('Update state could not be read'.tl), findsNothing);
    expect(find.text('Comic one'), findsOneWidget);
    db.dispose();
  });

  testWidgets(
    'eligible cached sources remain visible while another is pending',
    (tester) async {
      final completeKey = await installCompleteSource();
      final now = DateTime.now();
      await seedSchedule([
        detected('one', now),
        detected('c-one', now, key: completeKey),
      ]);

      await pumpPage(tester);
      expect(find.text('Comic c-one'), findsOneWidget);
      expect(find.text('Comic one'), findsNothing);
      expect(
        find.text('@c sources still pending'.tlParams({'c': 1})),
        findsOneWidget,
      );
      expect(find.text(syncHelp.tl), findsOneWidget);
    },
  );

  testWidgets('settings and source removal update the open page immediately', (
    tester,
  ) async {
    final completeKey = await installCompleteSource();
    await markCacheComplete();
    final now = DateTime.now();
    await seedSchedule([
      detected('one', now),
      detected('c-one', now, key: completeKey),
    ]);
    await pumpPage(tester);
    expect(sectionIds(tester).single, ['c-one', 'one']);

    appdata.settings['favorites'] = <String>[sourceKey];
    await tester.pump();
    expect(find.text('Comic c-one'), findsNothing);
    expect(find.text('Comic one'), findsOneWidget);

    appdata.settings['favorites'] = <String>[sourceKey, completeKey];
    await tester.pumpAndSettle();
    expect(find.text('Comic c-one'), findsOneWidget);

    appdata.settings['enabledSources'] = <String>[completeKey];
    await tester.pump();
    expect(find.text('Comic one'), findsNothing);
    expect(find.text('Comic c-one'), findsOneWidget);

    ComicSourceManager().remove(completeKey);
    await tester.pump();
    expect(find.text('Comic c-one'), findsNothing);
    expect(find.text('No source can be followed'.tl), findsOneWidget);
  });

  testWidgets('an account cache reset only hides the affected source', (
    tester,
  ) async {
    final completeKey = await installCompleteSource(declaresUnread: true);
    await markCacheComplete();
    final now = DateTime.now();
    await seedSchedule([
      detected('one', now),
      detected('c-one', now, key: completeKey),
    ]);
    final previous = NetworkFavoriteCacheManager.accountSwitchClearedSourceKey;
    addTearDown(() {
      NetworkFavoriteCacheManager.accountSwitchClearedSourceKey = previous;
    });
    await pumpPage(tester);
    expect(sectionIds(tester).single, ['c-one', 'one']);

    NetworkFavoriteCacheManager().invalidateFavoriteSessionForSource(
      completeKey,
    );
    await tester.pump();

    expect(find.text('Comic one'), findsOneWidget);
    expect(find.text('Comic c-one'), findsNothing);
    expect(find.text(syncHelp.tl), findsOneWidget);
  });

  group('the progress wording (F5.2/F5.4)', () {
    test('a round that has not finished discovering does not say 0 / 0', () {
      // The reported defect: a full bar reading "0 / 0 tasks" for the whole
      // round.  Before enumeration there is no denominator — only an unknown
      // one — so the label must say what is actually happening.
      final label = followUpdateProgressLabel(
        const FollowUpdateProgress(
          discovered: 0,
          finished: 0,
          phase: ScanProgressPhase.discovering,
        ),
      );

      expect(label, 'Finding what to check'.tl);
      expect(
        label,
        isNot('@done/@total tasks'.tlParams({'done': 0, 'total': 0})),
      );
    });

    test(
      'counts appear once there is a denominator, and for an empty round',
      () {
        expect(
          followUpdateProgressLabel(
            const FollowUpdateProgress(
              discovered: 4,
              finished: 1,
              phase: ScanProgressPhase.running,
            ),
          ),
          '@done/@total tasks'.tlParams({'done': 1, 'total': 4}),
        );
        expect(
          followUpdateProgressLabel(
            const FollowUpdateProgress(
              discovered: 0,
              finished: 0,
              phase: ScanProgressPhase.finished,
            ),
          ),
          '@done/@total tasks'.tlParams({'done': 0, 'total': 0}),
          reason: 'F5.2: nothing to do is complete, and 0 / 0 is honest there',
        );
      },
    );
  });

  testWidgets('the gate notice is translated, not hardcoded English (F2.4)', (
    tester,
  ) async {
    appdata.settings['language'] = 'zh-CN';
    await pumpPage(tester);

    // The Chinese is asserted **literally** on purpose.  A test written as
    // `find.text('Favorites are not fully cached yet'.tl)` compares the
    // fallback key with itself and passes even when the widget never calls
    // `.tl` — which is exactly how this defect survived: the two notice strings
    // were plain English literals, so the whole notice stayed English in every
    // locale while the key sat unused in the translation asset.
    expect(find.text('收藏尚未完整缓存'), findsOneWidget);
    expect(
      find.text('Favorites are not fully cached yet'),
      findsNothing,
      reason: 'the raw key must never reach the screen',
    );
  });
}

/// A comic whose cover is a **local** file.
///
/// Not an `https://` URL: the list renders covers, and a remote URL leaves a
/// pending Dio timer that fails the widget test with "a Timer is still pending"
/// even when every assertion passed.
FavoriteItem _comic(String id, {String key = 'gate_source'}) => FavoriteItem(
  id: id,
  name: 'Comic $id',
  coverPath: 'file:///${_coverPath().replaceAll(r'\', '/')}',
  author: id == 'paged-30' ? 'Late writer' : 'Author',
  sourceKeyValue: key,
  tags: id == 'paged-30' ? const ['Hidden genre'] : const ['tag'],
);

String _coverPath() =>
    '${Directory.systemTemp.path}${Platform.pathSeparator}venera-006-cover.png';
