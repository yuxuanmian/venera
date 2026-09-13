import 'dart:io';

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
import 'package:venera/foundation/schedule/schedule_state.dart';
import 'package:venera/foundation/schedule/sqlite_schedule_repository.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';

import '../tracking/fakes.dart';

/// Contract: `specs/006-local-follow-up-loop/contracts/follow-up-integration.md`
/// F8 and `contracts/schedule-v1.md` S7 — what an account switch clears and
/// what it must leave alone.
void main() {
  const unreadSource = 'switch_unread_source';
  const plainSource = 'switch_plain_source';
  const remote = 'remote';

  late Directory tempDir;
  late NetworkFavoriteCacheManager cache;
  late Object? previousEnabledSources;
  late Object? previousFavorites;

  ComicSource buildSource(
    String key, {
    required bool declaresUnread,
    bool scanCapable = true,
    bool declaresRetiredChannel = false,
  }) {
    final source = ComicSource(
      'Switch $key',
      key,
      AccountConfig(null, null, null, () {}, null, null, null, null),
      null,
      null,
      FavoriteData(
        key: key,
        title: 'Switch $key',
        multiFolder: true,
        loadComic: (page, [folder]) async => Res([_comic(key, 'one')]),
        loadNext: null,
        loadFolders: ([String? _]) async =>
            const Res(<String, String>{remote: 'Remote'}),
        // The parser never populates this in production, so a fixture that
        // declares it can only be built by hand — which is what makes it a
        // useful negative case.
        updateCheck: declaresRetiredChannel
            ? FavoriteUpdateCheckData(
                scanInterval: const Duration(minutes: 60),
                load: ([String? _]) async => throw UnimplementedError(),
              )
            : null,
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
                // The declaration is what `sourceDeclaresUnreadSignal` reads.
                evidenceSchema: declaresUnread
                    ? '{"latestchapterid":"last_chapter.id","sourceunread":"is_new"}'
                    : '{"latestchapterid":"last_chapter.id"}',
              ),
            )
          : null,
    );
    source.data['account'] = <String, dynamic>{'fixture': true};
    return source;
  }

  void install(ComicSource source) {
    final manager = ComicSourceManager();
    manager.remove(source.key);
    manager.add(source);
  }

  NetworkFavoriteFolderRef folderOf(String sourceKey) =>
      NetworkFavoriteFolderRef(sourceKey: sourceKey, folderId: remote);

  /// A coordinator wired to **this test's** cache instance.
  ///
  /// Without the injection its gate would read a different manager and report
  /// "nothing complete" no matter what the fixture seeded.
  FollowUpdateCoordinator buildCoordinator() => FollowUpdateCoordinator(
    judgmentService: JudgmentService(
      repository: InMemoryJudgmentRepository(),
      scanRepository: InMemoryScanItemStore(),
      clock: () => DateTime.utc(2026, 9, 10, 12),
    ),
    favoriteCache: cache,
    clock: () => DateTime.utc(2026, 9, 10, 12),
  );

  Future<void> markComplete(String sourceKey) async {
    final db = sqlite3.open('${tempDir.path}${Platform.pathSeparator}cache.db');
    try {
      db.execute(
        '''UPDATE favorite_folders SET full_cache_at = ?, full_cache_pages = 3,
                  full_cache_comics = 9
           WHERE source_key = ? AND folder_id = ?''',
        [DateTime.now().millisecondsSinceEpoch, sourceKey, remote],
      );
    } finally {
      db.dispose();
    }
  }

  setUp(() async {
    previousEnabledSources = appdata.settings['enabledSources'];
    previousFavorites = appdata.settings['favorites'];
    tempDir = await Directory.systemTemp.createTemp('venera-switch-');
    App.dataPath = tempDir.path;
    App.cachePath = tempDir.path;
    cache = NetworkFavoriteCacheManager.forTesting();
    await cache.init(
      databasePath: '${tempDir.path}${Platform.pathSeparator}cache.db',
      migrateLegacy: false,
    );
  });

  tearDown(() async {
    await judgmentStateRepository.close();
    await scheduleStateRepository.close();
    for (final key in [unreadSource, plainSource]) {
      ComicSourceManager().remove(key);
    }
    appdata.settings['enabledSources'] = previousEnabledSources;
    appdata.settings['favorites'] = previousFavorites;
    cache.close();
    try {
      await tempDir.delete(recursive: true);
    } on PathAccessException {
      // Windows may release a native SQLite handle just after dispose.
    } on PathNotFoundException {
      // Already gone.
    }
  });

  group('the cleanup criterion is the source declaration (F8)', () {
    test('a source declaring a source-side unread signal is cleaned', () {
      install(buildSource(unreadSource, declaresUnread: true));
      expect(sourceDeclaresUnreadSignal(unreadSource), isTrue);
    });

    test('a source declaring only content evidence is not', () {
      install(buildSource(plainSource, declaresUnread: false));
      expect(sourceDeclaresUnreadSignal(plainSource), isFalse);
    });

    test('an unknown source is not', () {
      expect(sourceDeclaresUnreadSignal('never-installed'), isFalse);
    });

    test(
      'the retired channel alone is NOT a criterion',
      () {
        // Contract F8: the criterion MUST NOT depend on whether the retired
        // observation channel exists.  It is also wrong on its own terms — a
        // source that declares only `updateCheck` has no account-level signal,
        // so its update flag comes from the comparison and is account
        // **independent**.  Cleaning it on an account switch would discard a
        // legitimate update.
        final source = buildSource(
          plainSource,
          declaresUnread: false,
          declaresRetiredChannel: true,
        );
        expect(
          source.favoriteData?.updateCheck,
          isNotNull,
          reason: 'the fixture must declare the retired channel',
        );
        install(source);

        expect(sourceDeclaresUnreadSignal(plainSource), isFalse);
      },
    );

    test(
      'the criterion does not depend on the retired observation channel',
      () async {
        // The retired channel is `favoriteData.updateCheck`.  A source that
        // declares the account-level signal through `fieldSource` and declares no
        // `updateCheck` at all MUST still be cleaned: otherwise removing that
        // channel silently drops account-switch cleanup for exactly the sources
        // that need it, because the signal it guards is account-level.
        final source = buildSource(unreadSource, declaresUnread: true);
        expect(
          source.favoriteData?.updateCheck,
          isNull,
          reason: 'the fixture must not declare the retired channel',
        );
        install(source);
        expect(sourceDeclaresUnreadSignal(unreadSource), isTrue);

        // And the cleanup actually happens: seed a complete cache, switch, and
        // observe that the marker is gone.
        await cache.refreshFolders(source.favoriteData!);
        await cache.refreshPage(
          source.favoriteData!,
          folderOf(unreadSource),
          1,
        );
        await markComplete(unreadSource);
        expect(
          cache.getFullCacheStatus(folderOf(unreadSource)).isComplete,
          isTrue,
        );

        cache.invalidateFavoriteSessionForSource(unreadSource);

        expect(
          cache.getFullCacheStatus(folderOf(unreadSource)).isComplete,
          isFalse,
          reason: 'a source declaring the signal must still be cleaned',
        );
      },
    );
  });

  group('what an account switch clears (F8)', () {
    setUp(() async {
      final source = buildSource(unreadSource, declaresUnread: true);
      install(source);
      await cache.refreshFolders(source.favoriteData!);
      await cache.refreshPage(source.favoriteData!, folderOf(unreadSource), 1);
      await markComplete(unreadSource);
      expect(
        cache.countCachedComicsInFolders([folderOf(unreadSource)]),
        greaterThan(0),
      );
    });

    test('the cached entries and the completeness mark are cleared', () {
      cache.invalidateFavoriteSessionForSource(unreadSource);

      expect(
        cache.countCachedComicsInFolders([folderOf(unreadSource)]),
        0,
        reason: 'the favorite entries belong to the previous account',
      );
      expect(
        cache.getFullCacheStatus(folderOf(unreadSource)).isComplete,
        isFalse,
        reason:
            'the completeness mark must go with them, or the gate would '
            'keep showing results joined to a cache that no longer exists',
      );
    });

    test('the gate returns to unsatisfied after the switch', () {
      // `sourceEnabled` reads `enabledSources`; `favorites` is the follow-up
      // selection.  The criterion set needs both.
      appdata.settings['enabledSources'] = <String>[unreadSource];
      appdata.settings['favorites'] = <String>[unreadSource];
      expect(
        cache.getFullCacheStatus(folderOf(unreadSource)).isComplete,
        isTrue,
        reason: 'the fixture must start from a complete cache',
      );

      // Through the coordinator, so the gate, the criterion set and the
      // completeness answer all come from the same (injected) store.
      final coordinator = buildCoordinator();
      expect(
        coordinator.evaluateGate().isSatisfied,
        isTrue,
        reason: 'the fixture starts from a complete cache',
      );

      cache.invalidateFavoriteSessionForSource(unreadSource);

      final gate = coordinator.evaluateGate();
      expect(
        gate.isSatisfied,
        isFalse,
        reason: 'F8: after a switch the user must re-cache to see follow-up',
      );
      expect(gate.reason, FollowUpdateGateReason.cacheIncomplete);
      expect(gate.pendingSourceKeys, {
        unreadSource,
      }, reason: 'the source is still a criterion — it was not deselected');
    });

    test('the folder row survives so the source is still recognisable', () {
      cache.invalidateFavoriteSessionForSource(unreadSource);

      // The folder must remain discoverable, or the gate would report "nothing
      // to follow" instead of "the cache is incomplete" and the re-cache entry
      // point would have nothing to fill.
      expect(
        cache.getAllCachedFolders().map((folder) => folder.folderId),
        contains(remote),
      );
    });

    test('observations, judgment state and schedule are untouched', () async {
      await judgmentStateRepository.ensureOpen();
      await judgmentStateRepository.applyBatch([
        JudgmentState(
          sourceKey: unreadSource,
          comicId: 'one',
          lastDecision: JudgmentConclusion.changed,
          lastReason: JudgmentReason.later,
          decidedAtMs: 1,
          hasNewUpdate: true,
          algorithmVersion: judgmentAlgorithmVersion,
        ),
      ]);
      await scheduleStateRepository.ensureOpen();
      await scheduleStateRepository.applyBatch([
        ScheduleState(
          sourceKey: unreadSource,
          comicId: 'one',
          // Deliberately in the future: this is the value S7 says survives.
          nextAtMs: DateTime.utc(2027, 1, 1).millisecondsSinceEpoch,
          activityAtMs: 1,
          autoHotUntilMs: DateTime.utc(2027, 2, 1).millisecondsSinceEpoch,
          manualHotEnabled: true,
          manualHotUntilMs: DateTime.utc(2027, 3, 1).millisecondsSinceEpoch,
        ),
      ]);

      cache.invalidateFavoriteSessionForSource(unreadSource);

      final judgment = await judgmentStateRepository.readFor(
        unreadSource,
        'one',
      );
      expect(
        judgment,
        isNotNull,
        reason: 'judgment state is not account-scoped and must survive',
      );
      expect(
        judgment!.factJson,
        isNull,
        reason: 'the fixture wrote no fact; only the flag was set',
      );

      final schedule = (await scheduleStateRepository
          .readAll())['$unreadSource\u0000one']!;
      expect(
        schedule.nextAtMs,
        DateTime.utc(2027, 1, 1).millisecondsSinceEpoch,
        reason:
            'S7: next_at answers "when to look again", which the cache '
            'being empty does not change',
      );
      expect(
        schedule.autoHotUntilMs,
        DateTime.utc(2027, 2, 1).millisecondsSinceEpoch,
        reason:
            'S7: the automatic window is a content fact, not an account one',
      );
      expect(
        schedule.manualHotEnabled,
        isTrue,
        reason: 'S7: an unexpired user preference must be preserved',
      );
      expect(
        schedule.manualHotUntilMs,
        DateTime.utc(2027, 3, 1).millisecondsSinceEpoch,
      );
    });

    test('the flag is cleared for the previous account only', () async {
      // A source that declares no unread signal would not be cleaned at all;
      // confirm the guard, not just the write.
      install(buildSource(plainSource, declaresUnread: false));
      final plain = ComicSource.find(plainSource)!;
      await cache.refreshFolders(plain.favoriteData!);
      await cache.refreshPage(plain.favoriteData!, folderOf(plainSource), 1);
      final before = cache.countCachedComicsInFolders([folderOf(plainSource)]);

      cache.invalidateFavoriteSessionForSource(plainSource);

      expect(
        cache.countCachedComicsInFolders([folderOf(plainSource)]),
        before,
        reason:
            'the guard returns early for a source that declares no '
            'account-level signal',
      );
    });

    test('the switch is recorded so the page can explain itself (FR-034)', () {
      NetworkFavoriteCacheManager.accountSwitchClearedSourceKey = null;
      addTearDown(
        () => NetworkFavoriteCacheManager.accountSwitchClearedSourceKey = null,
      );

      cache.invalidateFavoriteSessionForSource(unreadSource);

      expect(
        NetworkFavoriteCacheManager.accountSwitchClearedSourceKey,
        unreadSource,
        reason:
            'without this the page shows "not cached yet" and the user has '
            'no way to know an account change caused it',
      );
    });

    test('an unread-signal-less source records nothing', () {
      NetworkFavoriteCacheManager.accountSwitchClearedSourceKey = null;
      addTearDown(
        () => NetworkFavoriteCacheManager.accountSwitchClearedSourceKey = null,
      );
      install(buildSource(plainSource, declaresUnread: false));

      cache.invalidateFavoriteSessionForSource(plainSource);

      expect(
        NetworkFavoriteCacheManager.accountSwitchClearedSourceKey,
        isNull,
        reason: 'nothing was cleared, so there is nothing to explain',
      );
    });
  });
}

FavoriteItem _comic(String sourceKey, String id) => FavoriteItem(
  id: id,
  name: 'Comic $id',
  coverPath: '',
  author: 'Author',
  sourceKeyValue: sourceKey,
  tags: const ['tag'],
);
