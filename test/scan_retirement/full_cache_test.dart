import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/follow_update_availability.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/translations.dart';

import 'fixtures.dart';

void main() {
  late RetirementFixture fixture;

  setUpAll(() async {
    await AppTranslation.init();
  });

  setUp(() async {
    fixture = await createRetirementFixture();
  });

  tearDown(() async {
    await fixture.dispose();
  });

  test('loadComic wins when a source exposes both ordinary loaders', () async {
    final source = RetirementFakeSource(sourceKey: retirementSourceA);
    final numbered = source.numberedData(withUpdateCheck: true);
    var cursorCalls = 0;
    final data = FavoriteData(
      key: retirementSourceA,
      title: 'Both loaders',
      multiFolder: false,
      loadComic: numbered.loadComic,
      loadNext: (token, [_]) async {
        cursorCalls++;
        return const Res(<Comic>[], subData: null);
      },
      updateCheck: numbered.updateCheck,
    );
    const folder = NetworkFavoriteFolderRef(
      sourceKey: retirementSourceA,
      folderId: retirementFolderOne,
    );
    final scanBefore = snapshotRetirementState(fixture.databasePath);
    final ordinaryBefore = snapshotRetirementCacheState(fixture.databasePath);

    final frames = await fixture.cache
        .cacheAllPages(data, folder, isCanceled: () => false)
        .toList();

    expect(frames.last.isComplete, isTrue);
    expect(source.counters.numberedPageCalls, greaterThan(0));
    expect(cursorCalls, 0);
    expect(source.counters.updateCheckCalls, 0);
    expect(
      snapshotRetirementCacheState(fixture.databasePath),
      isNot(ordinaryBefore),
    );
    expect(snapshotRetirementState(fixture.databasePath), scanBefore);
  });

  test('cursor-only ordinary full cache remains usable', () async {
    final source = RetirementFakeSource();
    const folder = NetworkFavoriteFolderRef(
      sourceKey: RetirementFakeSource.key,
      folderId: retirementFolderTwo,
    );

    final frames = await fixture.cache
        .cacheAllPages(
          source.cursorData(withUpdateCheck: true),
          folder,
          isCanceled: () => false,
        )
        .toList();

    expect(frames.last.isComplete, isTrue);
    expect(source.counters.cursorPageCalls, 1);
    expect(source.counters.updateCheckCalls, 0);
  });

  test('only updateCheck is rejected before lock or cache mutation', () async {
    final source = RetirementFakeSource(sourceKey: retirementSourceA);
    const folder = NetworkFavoriteFolderRef(
      sourceKey: retirementSourceA,
      folderId: retirementFolderOne,
    );
    final before = snapshotRetirementState(fixture.databasePath);
    final ordinaryBefore = snapshotRetirementCacheState(fixture.databasePath);

    final frames = await fixture.cache
        .cacheAllPages(
          source.updateCheckOnlyData(),
          folder,
          isCanceled: () => false,
        )
        .toList();

    expect(frames, hasLength(1));
    expect(frames.single.errorMessage, followUpdateScannerUnavailableMessage);
    expect(frames.single.isComplete, isFalse);
    expect(snapshotRetirementState(fixture.databasePath), before);
    expect(snapshotRetirementCacheState(fixture.databasePath), ordinaryBefore);
    expect(fixture.cache.tryAcquireFullCacheLock(folder), isTrue);
    fixture.cache.releaseFullCacheLock(folder);
  });

  testWidgets('only-updateCheck source exposes no actionable cache-all UI', (
    tester,
  ) async {
    final source = RetirementFakeSource(sourceKey: retirementSourceA);
    final data = source.updateCheckOnlyData();
    final manager = ComicSourceManager();
    manager.remove(retirementSourceA);
    final comicSource = source.buildComicSource(favoriteData: data);
    comicSource.data['account'] = {'fixture': true};
    manager.add(comicSource);
    addTearDown(() => manager.remove(retirementSourceA));

    final beforeScan = snapshotRetirementState(fixture.databasePath);
    final beforeCache = snapshotRetirementCacheState(fixture.databasePath);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: NetworkFavoritePage(data: data),
        builder: (context, child) => OverlayWidget(child!),
      ),
    );
    await tester.pumpAndSettle();

    final cacheAll = find.byTooltip('Cache all favorites'.tl);
    // The page has no ordinary pagination callback, so it must not expose
    // a cache-all action that could accidentally route to updateCheck.
    expect(cacheAll, findsNothing);

    expect(source.counters.updateCheckCalls, 0);
    expect(source.counters.optimizedCalls, 0);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(snapshotRetirementState(fixture.databasePath), beforeScan);
    expect(snapshotRetirementCacheState(fixture.databasePath), beforeCache);
  });

  test(
    'cancellation keeps completed numbered pages and releases the lock',
    () async {
      final source = RetirementFakeSource(sourceKey: retirementSourceA);
      const folder = NetworkFavoriteFolderRef(
        sourceKey: retirementSourceA,
        folderId: 'cancel-folder',
      );
      var canceled = false;
      final data = FavoriteData(
        key: retirementSourceA,
        title: 'Cancellation test',
        multiFolder: false,
        loadComic: (page, [_]) async {
          if (page == 1) {
            canceled = true;
            return Res([source.comic('cancel-page-1')], subData: 3);
          }
          return Res([source.comic('cancel-page-$page')], subData: 3);
        },
        loadNext: null,
      );

      final frames = await fixture.cache
          .cacheAllPages(data, folder, isCanceled: () => canceled)
          .toList();

      expect(frames.last.isCanceled, isTrue);
      expect(frames.last.isComplete, isFalse);
      expect(
        fixture.cache.getCachedPage(folder, 1)!.comics.single.id,
        'cancel-page-1',
      );
      expect(fixture.cache.getCachedPage(folder, 2), isNull);
      expect(fixture.cache.getFullCacheStatus(folder).isComplete, isFalse);
      expect(fixture.cache.tryAcquireFullCacheLock(folder), isTrue);
      fixture.cache.releaseFullCacheLock(folder);
    },
  );

  test(
    'numbered full-cache failure keeps earlier pages and releases the lock',
    () async {
      final source = RetirementFakeSource(sourceKey: retirementSourceA);
      const folder = NetworkFavoriteFolderRef(
        sourceKey: retirementSourceA,
        folderId: 'failure-folder',
      );
      final data = FavoriteData(
        key: retirementSourceA,
        title: 'Failure test',
        multiFolder: false,
        loadComic: (page, [_]) async {
          if (page == 2) return const Res.error('page 2 failed');
          return Res([source.comic('failure-page-$page')], subData: 2);
        },
        loadNext: null,
      );

      final frames = await fixture.cache
          .cacheAllPages(data, folder, isCanceled: () => false)
          .toList();

      expect(frames.last.errorMessage, 'page 2 failed');
      expect(frames.last.isComplete, isFalse);
      expect(
        fixture.cache.getCachedPage(folder, 1)!.comics.single.id,
        'failure-page-1',
      );
      expect(fixture.cache.getCachedPage(folder, 2), isNull);
      expect(fixture.cache.getFullCacheStatus(folder).isComplete, isFalse);
      expect(fixture.cache.tryAcquireFullCacheLock(folder), isTrue);
      fixture.cache.releaseFullCacheLock(folder);
    },
  );

  test('repeated full-cache requests share one folder lock', () async {
    final source = RetirementFakeSource(sourceKey: retirementSourceA);
    const folder = NetworkFavoriteFolderRef(
      sourceKey: retirementSourceA,
      folderId: 'lock-folder',
    );
    final started = Completer<void>();
    final release = Completer<void>();
    final data = FavoriteData(
      key: retirementSourceA,
      title: 'Lock test',
      multiFolder: false,
      loadComic: (page, [_]) async {
        if (!started.isCompleted) started.complete();
        await release.future;
        return Res([source.comic('lock-page-$page')], subData: 1);
      },
      loadNext: null,
    );

    final firstFramesFuture = fixture.cache
        .cacheAllPages(data, folder, isCanceled: () => false)
        .toList();
    await started.future;

    final secondFrames = await fixture.cache
        .cacheAllPages(data, folder, isCanceled: () => false)
        .toList();
    expect(secondFrames, hasLength(1));
    expect(
      secondFrames.single.errorMessage,
      'A full cache operation is already running',
    );

    release.complete();
    final firstFrames = await firstFramesFuture;
    expect(firstFrames.last.isComplete, isTrue);
    expect(fixture.cache.tryAcquireFullCacheLock(folder), isTrue);
    fixture.cache.releaseFullCacheLock(folder);
  });

  test('unknown numbered totals stop at the configured safety cap', () async {
    final source = RetirementFakeSource(sourceKey: retirementSourceA);
    const folder = NetworkFavoriteFolderRef(
      sourceKey: retirementSourceA,
      folderId: 'unknown-total-folder',
    );
    final previousCap = NetworkFavoriteCacheManager.fullCacheUnknownTotalCap;
    NetworkFavoriteCacheManager.fullCacheUnknownTotalCap = 2;
    try {
      final data = FavoriteData(
        key: retirementSourceA,
        title: 'Unknown total test',
        multiFolder: false,
        loadComic: (page, [_]) async =>
            Res([source.comic('unknown-page-$page')]),
        loadNext: null,
      );

      final frames = await fixture.cache
          .cacheAllPages(data, folder, isCanceled: () => false)
          .toList();

      expect(frames.last.errorMessage, contains('stopped after 2 pages'));
      expect(frames.last.isComplete, isFalse);
      expect(fixture.cache.getCachedPage(folder, 1), isNotNull);
      expect(fixture.cache.getCachedPage(folder, 2), isNotNull);
      expect(fixture.cache.getFullCacheStatus(folder).isComplete, isFalse);
      expect(fixture.cache.tryAcquireFullCacheLock(folder), isTrue);
      fixture.cache.releaseFullCacheLock(folder);
    } finally {
      NetworkFavoriteCacheManager.fullCacheUnknownTotalCap = previousCap;
    }
  });

  test(
    'cursor full-cache rejects a repeated cursor without completing',
    () async {
      final source = RetirementFakeSource(sourceKey: retirementSourceA);
      const folder = NetworkFavoriteFolderRef(
        sourceKey: retirementSourceA,
        folderId: 'repeated-cursor-folder',
      );
      final data = FavoriteData(
        key: retirementSourceA,
        title: 'Repeated cursor test',
        multiFolder: false,
        loadComic: null,
        loadNext: (token, [_]) async {
          if (token == null) {
            return Res([source.comic('cursor-root')], subData: 'cursor-1');
          }
          return Res([source.comic('cursor-$token')], subData: 'cursor-1');
        },
      );

      final frames = await fixture.cache
          .cacheAllPages(data, folder, isCanceled: () => false)
          .toList();

      expect(
        frames.last.errorMessage,
        'Favorite source returned a repeated page cursor',
      );
      expect(frames.last.isComplete, isFalse);
      expect(fixture.cache.getCachedNextPage(folder, null), isNotNull);
      expect(fixture.cache.getCachedNextPage(folder, 'cursor-1'), isNotNull);
      expect(fixture.cache.getFullCacheStatus(folder).isComplete, isFalse);
      expect(fixture.cache.tryAcquireFullCacheLock(folder), isTrue);
      fixture.cache.releaseFullCacheLock(folder);
    },
  );
}
