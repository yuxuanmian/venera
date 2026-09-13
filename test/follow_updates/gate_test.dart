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
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/follow_updates_service.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/utils/translations.dart';

/// Contract: `specs/006-local-follow-up-loop/contracts/follow-up-integration.md`
/// F2 — the pre-condition gate's criteria and its presentation.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const scanSource = 'gate_scan_source';
  const secondScanSource = 'gate_second_scan_source';
  const plainSource = 'gate_plain_source';
  const folder = NetworkFavoriteFolderRef(
    sourceKey: scanSource,
    folderId: 'remote',
    title: 'Remote',
  );
  const secondFolder = NetworkFavoriteFolderRef(
    sourceKey: secondScanSource,
    folderId: 'remote',
    title: 'Remote',
  );

  late Directory tempDir;
  late Object? previousEnabledSources;
  late Object? previousFavorites;
  late Object? previousFollowUpdatesEnabled;

  ComicSource buildSource(String key, {required bool scanCapable}) =>
      ComicSource(
        'Gate $key',
        key,
        AccountConfig(null, null, null, () {}, null, null, null, null),
        null,
        null,
        FavoriteData(
          key: key,
          title: 'Gate $key',
          multiFolder: true,
          loadComic: (page, [folder]) async =>
              Res([_comic(key, 'one')], subData: 1),
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
        scan: scanCapable
            ? ScanCapabilities.supported(
                primary: ScanProducer.comic,
                comic: ScanCapability.comic(
                  (comicId, request) async => null,
                  evidenceSchema: '{"latestchapterid":"last_chapter.id"}',
                ),
              )
            : null,
      );

  void install(String key, {required bool scanCapable, bool loggedIn = true}) {
    final source = buildSource(key, scanCapable: scanCapable);
    if (loggedIn) source.data['account'] = <String, dynamic>{'fixture': true};
    final manager = ComicSourceManager();
    manager.remove(key);
    manager.add(source);
  }

  Future<void> markFolderComplete(String sourceKey) async {
    final db = sqlite3.open('${tempDir.path}${Platform.pathSeparator}cache.db');
    try {
      db.execute(
        '''UPDATE favorite_folders SET full_cache_at = ?
           WHERE source_key = ? AND folder_id = ?''',
        [DateTime.now().millisecondsSinceEpoch, sourceKey, 'remote'],
      );
    } finally {
      db.dispose();
    }
  }

  setUpAll(() async {
    await AppTranslation.init();
    File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}venera-006-cover.png',
    ).writeAsBytesSync(
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
    tempDir = await Directory.systemTemp.createTemp('venera-gate-');
    App.dataPath = tempDir.path;
    App.cachePath = tempDir.path;
    final cache = NetworkFavoriteCacheManager();
    await cache.init(
      databasePath: '${tempDir.path}${Platform.pathSeparator}cache.db',
      migrateLegacy: false,
    );
    appdata.settings['followUpdatesEnabled'] = true;
    appdata.settings['language'] = 'system';
  });

  tearDown(() async {
    await judgmentStateRepository.close();
    for (final key in [scanSource, secondScanSource, plainSource]) {
      ComicSourceManager().remove(key);
    }
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

  group('the criteria come from configuration (F2.1)', () {
    test('an empty cache still yields a non-empty criterion set', () async {
      install(scanSource, scanCapable: true);
      appdata.settings['enabledSources'] = <String>[scanSource];
      appdata.settings['favorites'] = <String>[scanSource];

      final gate = evaluateFollowUpdateGate(
        completeSourceKeys: completeFavoriteCacheSourceKeys(),
      );
      expect(
        gate.sourceKeys,
        isNotEmpty,
        reason:
            'the criterion set is configuration-derived; a cache-derived '
            'one would be empty here and the gate would wrongly pass',
      );
      expect(gate.isSatisfied, isFalse);
      expect(gate.reason, FollowUpdateGateReason.cacheIncomplete);
    });

    test('a source without scan capability is not a criterion', () async {
      install(scanSource, scanCapable: true);
      install(plainSource, scanCapable: false);
      appdata.settings['enabledSources'] = <String>[scanSource, plainSource];
      appdata.settings['favorites'] = <String>[scanSource, plainSource];

      final gate = evaluateFollowUpdateGate(
        completeSourceKeys: completeFavoriteCacheSourceKeys(),
      );
      expect(gate.sourceKeys, {scanSource});
      expect(
        gate.pendingSourceKeys,
        {scanSource},
        reason:
            'a source that can never produce an update must not be able to '
            'hold follow-up closed',
      );
    });

    test('a logged-out source is not a criterion', () async {
      install(scanSource, scanCapable: true, loggedIn: false);
      appdata.settings['enabledSources'] = <String>[scanSource];
      appdata.settings['favorites'] = <String>[scanSource];

      final gate = evaluateFollowUpdateGate(
        completeSourceKeys: completeFavoriteCacheSourceKeys(),
      );
      expect(gate.sourceKeys, isEmpty);
      expect(gate.reason, FollowUpdateGateReason.noSources);
    });

    test('completeness is per source, from the folder mark only', () async {
      install(scanSource, scanCapable: true);
      appdata.settings['enabledSources'] = <String>[scanSource];
      appdata.settings['favorites'] = <String>[scanSource];
      final data = ComicSource.find(scanSource)!.favoriteData!;
      final cache = NetworkFavoriteCacheManager();
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);

      // Cached rows exist but the completeness mark does not: still incomplete.
      expect(cache.countCachedComicsInFolders([folder]), greaterThan(0));
      expect(
        evaluateFollowUpdateGate(
          completeSourceKeys: completeFavoriteCacheSourceKeys(),
        ).isSatisfied,
        isFalse,
        reason: 'a non-empty cache is not a complete one',
      );

      await markFolderComplete(scanSource);
      expect(
        evaluateFollowUpdateGate(
          completeSourceKeys: completeFavoriteCacheSourceKeys(),
        ).isSatisfied,
        isTrue,
      );
    });

    test('one complete source is enough to show its results (F2.3)', () async {
      // The defect this replaces: requiring *every* criterion source to be
      // complete meant a source the user added but never cached held follow-up
      // closed forever.  The more sources a user has, the less likely any
      // result ever appears — exactly backwards.
      install(scanSource, scanCapable: true);
      install(secondScanSource, scanCapable: true);
      appdata.settings['enabledSources'] = <String>[
        scanSource,
        secondScanSource,
      ];
      appdata.settings['favorites'] = <String>[scanSource, secondScanSource];
      final cache = NetworkFavoriteCacheManager();
      final data = ComicSource.find(secondScanSource)!.favoriteData!;
      await cache.refreshFolders(data);
      await cache.refreshPage(data, secondFolder, 1);
      await markFolderComplete(secondScanSource);

      final gate = evaluateFollowUpdateGate(
        completeSourceKeys: completeFavoriteCacheSourceKeys(),
      );

      expect(gate.satisfiedSourceKeys, {secondScanSource});
      expect(
        gate.isSatisfied,
        isTrue,
        reason: 'the cached source can answer on its own',
      );
      expect(gate.pendingSourceKeys, {scanSource});
      expect(gate.hasPendingSources, isTrue);
      expect(
        gate.isCacheComplete,
        isFalse,
        reason: '"everything is ready" stays a different question',
      );
      expect(gate.reason, FollowUpdateGateReason.satisfied);
    });

    test('with no complete source there is nothing to show (F2.3)', () async {
      install(scanSource, scanCapable: true);
      install(secondScanSource, scanCapable: true);
      appdata.settings['enabledSources'] = <String>[
        scanSource,
        secondScanSource,
      ];
      appdata.settings['favorites'] = <String>[scanSource, secondScanSource];

      final gate = evaluateFollowUpdateGate(
        completeSourceKeys: completeFavoriteCacheSourceKeys(),
      );

      expect(gate.isSatisfied, isFalse);
      expect(gate.reason, FollowUpdateGateReason.cacheIncomplete);
      expect(gate.pendingSourceKeys, {scanSource, secondScanSource});
    });
  });

  group('the presentation withholds the list entirely (F2.3)', () {
    Future<void> pumpPage(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: const FollowUpdatesPage(),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('an incomplete cache shows no list, not a partial one', (
      tester,
    ) async {
      install(scanSource, scanCapable: true);
      appdata.settings['enabledSources'] = <String>[scanSource];
      appdata.settings['favorites'] = <String>[scanSource];
      final data = ComicSource.find(scanSource)!.favoriteData!;
      await NetworkFavoriteCacheManager().refreshFolders(data);

      await pumpPage(tester);

      expect(
        find.text('Favorites are not fully cached yet'.tl),
        findsOneWidget,
      );
      expect(find.text('Cache favorites completely'.tl), findsOneWidget);
      // No header, no entries, no empty-state placeholder.
      expect(find.text('Updates'.tl), findsNothing);
      expect(find.text('Comic one'.tl), findsNothing);
      expect(find.text('No updates found'.tl), findsNothing);
    });

    testWidgets('no criterion sources at all is a different message', (
      tester,
    ) async {
      // Nothing selected: F2.4 requires "there is nothing to follow" plus a
      // reason, NOT an ever-empty update list.
      appdata.settings['enabledSources'] = <String>[];
      appdata.settings['favorites'] = <String>[];

      await pumpPage(tester);

      expect(find.text('No source can be followed'.tl), findsOneWidget);
      expect(
        find.text('Favorites are not fully cached yet'.tl),
        findsNothing,
        reason:
            'an empty criterion set is not a satisfied one, and it is not '
            'the same situation as an incomplete cache',
      );
      expect(find.text('No updates found'.tl), findsNothing);
    });
  });
}

FavoriteItem _comic(String sourceKey, String id) => FavoriteItem(
  id: id,
  name: 'Comic $id',
  coverPath:
      'file:///${Directory.systemTemp.path.replaceAll(r'\', '/')}/venera-006-cover.png',
  author: 'Author',
  sourceKeyValue: sourceKey,
  tags: const ['tag'],
);
