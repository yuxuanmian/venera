import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/res.dart';

import 'fixtures.dart';

void main() {
  late RetirementFixture fixture;

  setUp(() async {
    fixture = await createRetirementFixture();
  });

  tearDown(() async {
    await fixture.dispose();
  });

  test('ordinary numbered pagination ignores update-check hints', () async {
    final source = RetirementFakeSource(sourceKey: retirementSourceA);
    final folder = const NetworkFavoriteFolderRef(
      sourceKey: retirementSourceA,
      folderId: retirementFolderOne,
    );
    final scanBefore = snapshotRetirementState(fixture.databasePath);
    final ordinaryBefore = snapshotRetirementCacheState(fixture.databasePath);

    final result = await fixture.cache.refreshPage(
      source.numberedComicData('retire-a', withUpdateCheck: true),
      folder,
      1,
    );

    expect(result.success, isTrue);
    expect(source.counters.numberedPageCalls, 1);
    expect(source.counters.updateCheckCalls, 0);
    expect(fixture.cache.getCachedPage(folder, 1)!.comics, hasLength(1));
    expect(
      fixture.cache.getCachedPage(folder, 1)!.comics.single.favoriteUpdate,
      isNull,
    );
    expect(
      snapshotRetirementCacheState(fixture.databasePath),
      isNot(ordinaryBefore),
    );
    expect(snapshotRetirementState(fixture.databasePath), scanBefore);
  });

  test(
    'ordinary cursor pagination remains available with update-check input',
    () async {
      final source = RetirementFakeSource(sourceKey: retirementSourceA);
      final folder = const NetworkFavoriteFolderRef(
        sourceKey: retirementSourceA,
        folderId: retirementFolderTwo,
      );
      final scanBefore = snapshotRetirementState(fixture.databasePath);
      final ordinaryBefore = snapshotRetirementCacheState(fixture.databasePath);

      final result = await fixture.cache.refreshNextPage(
        source.cursorData(withUpdateCheck: true),
        folder,
        null,
      );

      expect(result.success, isTrue);
      expect(source.counters.cursorPageCalls, 1);
      expect(source.counters.updateCheckCalls, 0);
      expect(fixture.cache.getCachedNextPage(folder, null), isNotNull);
      expect(
        snapshotRetirementCacheState(fixture.databasePath),
        isNot(ordinaryBefore),
      );
      expect(snapshotRetirementState(fixture.databasePath), scanBefore);
    },
  );

  test(
    'session epoch rejects a stale list response after cache clear',
    () async {
      final source = RetirementFakeSource(sourceKey: retirementSourceA);
      const folder = NetworkFavoriteFolderRef(
        sourceKey: retirementSourceA,
        folderId: retirementFolderOne,
      );
      final started = Completer<void>();
      final release = Completer<void>();
      final data = source.numberedComicData(
        'stale-after-clear',
        withUpdateCheck: true,
        loader: (page, [_]) async {
          if (!started.isCompleted) started.complete();
          await release.future;
          return Res([source.comic('stale-after-clear', withHint: true)]);
        },
      );

      final pending = fixture.cache.refreshPage(data, folder, 1);
      await started.future;
      fixture.cache.clearAllCache();
      final ordinaryAfterClear = snapshotRetirementCacheState(
        fixture.databasePath,
      );
      final scanAfterClear = snapshotRetirementState(fixture.databasePath);

      release.complete();
      final result = await pending;

      expect(result.errorMessage, 'Favorite session changed');
      expect(
        snapshotRetirementCacheState(fixture.databasePath),
        ordinaryAfterClear,
      );
      expect(snapshotRetirementState(fixture.databasePath), scanAfterClear);
      expect(fixture.cache.getCachedPage(folder, 1), isNull);
    },
  );

  test('source session invalidation rejects an in-flight response', () async {
    final source = RetirementFakeSource(sourceKey: retirementSourceA);
    const folder = NetworkFavoriteFolderRef(
      sourceKey: retirementSourceA,
      folderId: retirementFolderOne,
    );
    final started = Completer<void>();
    final release = Completer<void>();
    final data = source.numberedComicData(
      'stale-after-session-change',
      withUpdateCheck: true,
      loader: (page, [_]) async {
        if (!started.isCompleted) started.complete();
        await release.future;
        return Res([source.comic('stale-after-session-change')]);
      },
    );
    final sources = ComicSourceManager();
    sources.remove(retirementSourceA);
    sources.add(
      // Session invalidation is gated on the source declaring a source-side
      // unread signal (Contract F8), so the fixture must declare one, or the
      // invalidation below is a deliberate no-op and this test would be
      // asserting about a source the product no longer invalidates.
      source.buildComicSource(favoriteData: data, declaresSourceUnread: true),
    );
    addTearDown(() => sources.remove(retirementSourceA));

    final pending = fixture.cache.refreshPage(data, folder, 1);
    await started.future;
    fixture.cache.invalidateFavoriteSessionForSource(retirementSourceA);
    final ordinaryAfterInvalidation = snapshotRetirementCacheState(
      fixture.databasePath,
    );
    final scanAfterInvalidation = snapshotRetirementState(fixture.databasePath);

    release.complete();
    final result = await pending;

    expect(result.errorMessage, 'Favorite session changed');
    expect(
      snapshotRetirementCacheState(fixture.databasePath),
      ordinaryAfterInvalidation,
    );
    expect(
      snapshotRetirementState(fixture.databasePath),
      scanAfterInvalidation,
    );
  });
}
