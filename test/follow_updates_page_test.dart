import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_source/scan.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates_service.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/utils/translations.dart';

/// Contracts: `specs/006-local-follow-up-loop/contracts/follow-up-integration.md`
/// F2 (the gate), F3.1/F3.3 (the single renderable list) and F3.4 (empty vs
/// unreadable).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sourceKey = 'gate_source';
  const folder = NetworkFavoriteFolderRef(
    sourceKey: sourceKey,
    folderId: 'remote',
    title: 'Remote',
  );

  late Directory tempDir;
  late Object? previousEnabledSources;
  late Object? previousFavorites;
  late Object? previousFollowUpdatesEnabled;

  Future<void> markCacheComplete({
    String key = sourceKey,
    String folderId = 'remote',
  }) async {
    final db = sqlite3.open('${tempDir.path}${Platform.pathSeparator}cache.db');
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

  /// Writes one judgment row carrying the visible flag.
  ///
  /// The page has no other source for the update flag, so this is what "the
  /// comic has an update" means in this build.
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

  /// Makes the judgment store genuinely unreadable for the next read.
  ///
  /// Drops the table through a **second connection to the same file**: the real
  /// repository stays installed, stays open, and simply finds no table — which
  /// is what a damaged or foreign database looks like from the page's side.
  /// Nothing is stubbed, so this cannot pass against a fake that behaves better
  /// than the real store.
  void breakJudgmentStore() {
    final db = sqlite3.open(
      '${tempDir.path}${Platform.pathSeparator}tracking_state.db',
    );
    try {
      db.execute('DROP TABLE judgment_state');
    } finally {
      db.dispose();
    }
  }

  ComicSource buildSource({
    String key = sourceKey,
    String title = 'Gate source',
    List<String> comicIds = const ['one', 'two', 'three'],
  }) => ComicSource(
    title,
    key,
    AccountConfig(null, null, null, () {}, null, null, null, null),
    null,
    null,
    FavoriteData(
      key: key,
      title: title,
      multiFolder: true,
      loadComic: (page, [folder]) async =>
          Res([for (final id in comicIds) _comic(id, key: key)], subData: 1),
      loadNext: null,
      loadFolders: ([String? _]) async =>
          const Res(<String, String>{'remote': 'Remote'}),
    ),
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
    // Scan-capable, so the source belongs to the criterion set.  Without it the
    // page takes the different "nothing to follow" branch and this file would
    // stop testing the gate.
    scan: ScanCapabilities.supported(
      primary: ScanProducer.comic,
      comic: ScanCapability.comic(
        (comicId, request) async => null,
        evidenceSchema: '{"latestchapterid":"last_chapter.id"}',
      ),
    ),
  );

  /// Installs a second tracked source whose cache **is** complete.
  ///
  /// This is what makes the per-source rule testable: with one source the old
  /// all-or-nothing gate and the new per-source rule agree, so only a second
  /// source with the opposite state can tell them apart.  Its comics are named
  /// `c-*` so a title in an assertion identifies its source unambiguously.
  Future<String> installCompleteSource() async {
    const completeKey = 'complete_source';
    const completeFolder = NetworkFavoriteFolderRef(
      sourceKey: completeKey,
      folderId: 'remote',
      title: 'Remote',
    );
    final source = buildSource(
      key: completeKey,
      title: 'Complete source',
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
    previousFollowUpdatesEnabled = appdata.settings['followUpdatesEnabled'];
    tempDir = await Directory.systemTemp.createTemp('venera-follow-gate-');
    App.dataPath = tempDir.path;
    App.cachePath = tempDir.path;

    final cache = NetworkFavoriteCacheManager();
    await cache.init(
      databasePath: '${tempDir.path}${Platform.pathSeparator}cache.db',
      migrateLegacy: false,
    );
    final source = buildSource();
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
    expect(cache.countCachedComicsInFolders([folder]), 3);
    expect(cache.getFullCacheStatus(folder).isComplete, isFalse);
  });

  tearDown(() async {
    await judgmentStateRepository.close();
    ComicSourceManager().remove(sourceKey);
    appdata.settings['enabledSources'] = previousEnabledSources;
    appdata.settings['favorites'] = previousFavorites;
    appdata.settings['followUpdatesEnabled'] = previousFollowUpdatesEnabled;
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
    // The page's dialogs use App.rootContext, so the app's root navigator key
    // must be attached to the test MaterialApp.
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: const FollowUpdatesPage(),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('an incomplete cache shows the gate and no list at all', (
    tester,
  ) async {
    await flagUpdate('one');
    await pumpPage(tester);

    expect(find.text('Favorites are not fully cached yet'.tl), findsOneWidget);
    expect(
      find.text('Cache favorites completely'.tl),
      findsOneWidget,
      reason: 'the gate must offer the entry point that resolves it',
    );
    // No list in any form: not the entries, not the empty state, not the
    // historical notice (Contract F2.3).
    expect(find.text('Comic one'.tl), findsNothing);
    expect(find.text('No updates found'.tl), findsNothing);
    expect(find.text('Updates'.tl), findsNothing);
  });

  testWidgets('a complete cache opens the gate and the flagged comic renders', (
    tester,
  ) async {
    await markCacheComplete();
    await flagUpdate('one');
    await pumpPage(tester);

    expect(find.text('Favorites are not fully cached yet'.tl), findsNothing);
    expect(find.text('Updates'.tl), findsOneWidget);
    expect(
      find.text('Comic one'.tl),
      findsOneWidget,
      reason: 'F3.3: every listed entry renders its title and cover',
    );
    expect(
      find.text('Comic two'.tl),
      findsNothing,
      reason: 'a comic without the visible flag is not listed',
    );
  });

  testWidgets('a complete cache with nothing flagged shows the empty state', (
    tester,
  ) async {
    await markCacheComplete();
    await pumpPage(tester);

    expect(find.text('Updates'.tl), findsOneWidget);
    expect(
      find.text('No updates found'.tl),
      findsOneWidget,
      reason: 'F3.4: an empty result is an explicit state, not a blank area',
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('the progress entry never starts a round (F1.2)', (tester) async {
    await markCacheComplete();
    await pumpPage(tester);

    await tester.tap(find.byTooltip('Update check progress'.tl));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));

    // The entry reports; it does not trigger.  Nothing about the page's content
    // changes as a result of tapping it.
    expect(find.text('Updates'.tl), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('the entry badge counts the same flagged comics the list shows '
      '(F3.2)', (tester) async {
    // FR-020: the badge and the list must agree.  They are asserted against the
    // same seeded store rather than against each other, so this fails if either
    // side starts reading somewhere else.
    await markCacheComplete();
    await flagUpdate('one');
    await flagUpdate('two');

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: const Scaffold(
          body: CustomScrollView(slivers: [FollowUpdatesWidget()]),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text('@c updates'.tlParams({'c': 2})),
      findsOneWidget,
      reason: 'the badge counts the flagged comics',
    );

    // The list agrees: the same two titles are present, and neither the badge
    // nor the list invented a third.
    await pumpPage(tester);
    expect(find.text('Comic one'.tl), findsOneWidget);
    expect(find.text('Comic two'.tl), findsOneWidget);
    expect(find.text('@c updates'.tlParams({'c': 3})), findsNothing);
  });

  testWidgets('the badge shows nothing when no comic is flagged (F3.2)', (
    tester,
  ) async {
    await markCacheComplete();

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: const Scaffold(
          body: CustomScrollView(slivers: [FollowUpdatesWidget()]),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('@c updates'.tlParams({'c': 0})), findsNothing);
    expect(find.text('Follow Updates'.tl), findsOneWidget);
  });

  testWidgets('an unreadable store is reported, never shown as empty (F3.4)', (
    tester,
  ) async {
    await markCacheComplete();
    // Seed a flag before breaking the store: a stale count is exactly what the
    // failure path must not keep showing.
    await flagUpdate('one');
    breakJudgmentStore();

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: const Scaffold(
          body: CustomScrollView(slivers: [FollowUpdatesWidget()]),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text('@c updates'.tlParams({'c': 1})),
      findsNothing,
      reason: 'F3.2: a failed read leaves no stale count behind',
    );
    expect(find.text('@c updates'.tlParams({'c': 0})), findsNothing);

    await pumpPage(tester);

    expect(find.text('Update state could not be read'.tl), findsOneWidget);
    expect(
      find.text('No updates found'.tl),
      findsNothing,
      reason: 'F3.4: unreadable is a reported state, not an empty list',
    );
    expect(find.text('Comic one'.tl), findsNothing);
    expect(
      find.text('Retry'.tl),
      findsOneWidget,
      reason: 'the notice must offer the way out of the failure',
    );
  });

  testWidgets('a disabled feature shows neither a count nor entries (F3.2)', (
    tester,
  ) async {
    await markCacheComplete();
    await flagUpdate('one');
    appdata.settings['followUpdatesEnabled'] = false;

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: const Scaffold(
          body: CustomScrollView(slivers: [FollowUpdatesWidget()]),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('@c updates'.tlParams({'c': 1})), findsNothing);
    expect(find.text('Follow updates disabled'.tl), findsOneWidget);

    await pumpPage(tester);

    expect(find.text('Follow updates disabled'.tl), findsOneWidget);
    expect(
      find.text('Comic one'.tl),
      findsNothing,
      reason: 'F3.2: the list must agree with the badge that shows nothing',
    );
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
    expect(find.text('追更结果需要每个追更源的收藏缓存都已完整。'), findsOneWidget);
    expect(
      find.text(
        'Follow-up results need a complete favorite cache for every tracked source.',
      ),
      findsNothing,
    );
  });

  group('the favorites page urges caching the source it is about (F2.7)', () {
    String prompt() =>
        'This source is not followed yet: its favorites are not fully cached'
            .tl;

    Future<void> pumpSource(
      WidgetTester tester, {
      String key = sourceKey,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: Scaffold(
            body: NetworkFavoritePage(
              data: ComicSource.find(key)!.favoriteData!,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('an incompletely cached source is urged to cache', (
      tester,
    ) async {
      // setUp cached the folder but deliberately left out the completeness
      // mark, so this criterion source is pending.
      await pumpSource(tester);

      expect(find.text(prompt()), findsOneWidget);
    });

    testWidgets('the prompt goes away when this source finishes caching', (
      tester,
    ) async {
      await pumpSource(tester);
      expect(find.text(prompt()), findsOneWidget);

      // The completion mark is written by a separate connection (as a finished
      // full cache does through the settings/cache path), so the notification
      // is what the prompt must react to: it is the listener, not a rebuild,
      // that makes it disappear without leaving the page.
      await markCacheComplete();
      NetworkFavoriteCacheManager().notifyCacheChanged();
      await tester.pump();

      expect(find.text(prompt()), findsNothing);
    });

    testWidgets('only the source that still needs caching is urged', (
      tester,
    ) async {
      // The crux of the change: an un-cached source must not make the *other*
      // sources look unfinished, and the prompt must name the source it is on.
      final completeKey = await installCompleteSource();

      await pumpSource(tester);
      expect(
        find.text(prompt()),
        findsOneWidget,
        reason: 'this source is the pending one',
      );

      await pumpSource(tester, key: completeKey);
      expect(
        find.text(prompt()),
        findsNothing,
        reason: 'a fully cached source is followed; nothing to urge',
      );
    });

    testWidgets('a disabled feature shows no prompt at all', (tester) async {
      appdata.settings['followUpdatesEnabled'] = false;
      await pumpSource(tester);

      expect(find.text(prompt()), findsNothing);
    });
  });

  group('a complete source is not held closed by an incomplete one (F2.3)', () {
    String pendingLine(int count) =>
        '@c sources are not fully cached yet, so they are not followed'
            .tlParams({'c': count});

    testWidgets('the cached source lists updates, the other one does not', (
      tester,
    ) async {
      // The second source is complete; the fixture source stays incomplete
      // (setUp cached its folder without the completeness mark).  Both have a
      // flagged comic, and both comics are in their own cache, so "hidden" can
      // only be the per-source rule — not a missing presentation row.
      final completeKey = await installCompleteSource();
      await flagUpdate('one');
      await flagUpdate('c-one', key: completeKey);

      await pumpPage(tester);

      expect(
        find.text('Comic c-one'.tl),
        findsOneWidget,
        reason: 'the fully cached source answers immediately',
      );
      expect(
        find.text('Comic one'.tl),
        findsNothing,
        reason:
            'a partial cache must not render a partial answer as the whole one',
      );
      expect(
        find.text(pendingLine(1)),
        findsOneWidget,
        reason: 'the list says which source is still missing',
      );
      expect(
        find.text('Favorites are not fully cached yet'.tl),
        findsNothing,
        reason: 'results exist, so this is no longer the nothing-to-show case',
      );
    });

    testWidgets('the entry badge counts what the list shows (F3.2)', (
      tester,
    ) async {
      final completeKey = await installCompleteSource();
      await flagUpdate('one');
      await flagUpdate('c-one', key: completeKey);

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: const Scaffold(
            body: CustomScrollView(slivers: [FollowUpdatesWidget()]),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.text('@c updates'.tlParams({'c': 1})),
        findsOneWidget,
        reason: 'the hidden source must not be counted',
      );
      expect(find.text('@c updates'.tlParams({'c': 2})), findsNothing);
    });
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
  author: 'Author',
  sourceKeyValue: key,
  tags: const ['tag'],
);

String _coverPath() =>
    '${Directory.systemTemp.path}${Platform.pathSeparator}venera-006-cover.png';
