import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/res.dart';

Comic _comic(String id, String marker, String updateTime, {bool? isNew}) =>
    Comic(
      'Comic $id',
      'cover-$id',
      id,
      null,
      const [],
      '',
      'list-test',
      null,
      null,
      favoriteUpdate: FavoriteUpdateHint(
        marker: marker,
        updateTime: updateTime,
        isNew: isNew,
        metadata: const {'fullIsNew': false},
      ),
    );

FavoriteData _data({
  Future<Res<FavoriteUpdateSnapshot>> Function([String?])? updateLoader,
  Future<Res<List<Comic>>> Function(int, [String?])? pageLoader,
  Future<Res<List<Comic>>> Function(String?, [String?])? nextLoader,
  String markerScheme = 'list-v1',
}) => FavoriteData(
  key: 'list-test',
  title: 'List test',
  multiFolder: false,
  loadComic: pageLoader,
  loadNext: nextLoader,
  updateCheck: FavoriteUpdateCheckData(
    markerScheme: markerScheme,
    scanInterval: const Duration(hours: 12),
    load: updateLoader ?? ([_]) async => const Res.error('not used'),
  ),
);

ComicSource _listSource(FavoriteData data) => ComicSource(
  'List test',
  data.key,
  null,
  null,
  null,
  data,
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
);

ComicSource _detailSource() => ComicSource(
  'Detail test',
  'detail-test',
  null,
  null,
  null,
  null,
  const [],
  null,
  null,
  (id) async => Res(
    ComicDetails.fromJson({
      'title': 'Comic $id',
      'subtitle': 'Author',
      'cover': '',
      'tags': <String, List<String>>{},
      'chapters': <String, String>{'1': 'Chapter 1'},
      'sourceKey': 'detail-test',
      'comicId': id,
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
);

Comic _snapshotComic(
  String id,
  String marker, {
  String sourceKey = 'list-test',
  bool? isNew,
  String? updateTime = '2026-08-01',
  bool? fullIsNew = false,
}) => Comic(
  'Comic $id',
  'cover-$id',
  id,
  null,
  const [],
  '',
  sourceKey,
  null,
  null,
  favoriteUpdate: FavoriteUpdateHint(
    marker: marker,
    updateTime: updateTime,
    isNew: isNew,
    metadata: {'fullIsNew': fullIsNew},
  ),
);

FavoriteUpdateSnapshot _snapshot(String marker, {String id = 'c1'}) =>
    FavoriteUpdateSnapshot(
      comics: [_snapshotComic(id, marker)],
      pageSize: 15,
      total: 1,
    );

FavoriteUpdateSnapshot _snapshotWithComic(Comic comic) =>
    FavoriteUpdateSnapshot(comics: [comic], pageSize: 15, total: 1);

void main() {
  late Directory directory;
  late NetworkFavoriteCacheManager manager;
  late NetworkFavoriteFolderRef folder;

  setUp(() async {
    ComicSourceManager().remove('list-test');
    ComicSourceManager().remove('detail-test');
    directory = await Directory.systemTemp.createTemp('venera-list-update-');
    manager = NetworkFavoriteCacheManager();
    await manager.init(
      databasePath: '${directory.path}${Platform.pathSeparator}cache.db',
      migrateLegacy: false,
    );
    folder = const NetworkFavoriteFolderRef(
      sourceKey: 'list-test',
      folderId: '',
      title: 'List test',
    );
    addTearDown(() {
      ComicSourceManager().remove('list-test');
      ComicSourceManager().remove('detail-test');
    });
  });

  tearDown(() async {
    manager.close();
    await directory.delete(recursive: true);
  });

  test(
    'applies a complete snapshot atomically and preserves sticky update state',
    () {
      final data = _data();
      final first = manager.applyCompleteFavoriteUpdateSnapshot(
        data,
        folder,
        const FavoriteUpdateSnapshot(
          comics: [
            Comic(
              'Comic c1',
              'cover-c1',
              'c1',
              null,
              [],
              '',
              'list-test',
              null,
              null,
              favoriteUpdate: FavoriteUpdateHint(
                marker: 'm1',
                updateTime: '2026-08-20',
                isNew: false,
                metadata: {'fullIsNew': false},
              ),
            ),
            Comic(
              'Comic c2',
              'cover-c2',
              'c2',
              null,
              [],
              '',
              'list-test',
              null,
              null,
              favoriteUpdate: FavoriteUpdateHint(
                marker: 'm2',
                updateTime: '2026-08-21',
                isNew: false,
                metadata: {'fullIsNew': false},
              ),
            ),
          ],
          pageSize: 15,
          total: 2,
        ),
        completedAt: DateTime(2026, 8, 24),
      );
      expect(first.updatedComicCount, 0);
      expect(manager.countCachedComics(folder), 2);
      expect(manager.getFullCacheStatus(folder).completedAt, isNotNull);
      expect(
        manager.getFavoriteUpdateScanState(folder)!.markerScheme,
        'list-v1',
      );
      expect(
        manager.getComicUpdateInfo('list-test', 'c1', '')!.updateMarker,
        encodeFollowUpdateMarker('list-v1', 'm1'),
      );
      expect(
        manager.getCachedPage(folder, 1)!.comics.first.favoriteUpdate,
        isNull,
      );

      final changed = manager.applyCompleteFavoriteUpdateSnapshot(
        data,
        folder,
        FavoriteUpdateSnapshot(
          comics: [
            _comic('c1', 'm1-new', '2026-08-22'),
            _comic('c2', 'm2', '2026-08-21'),
          ],
          pageSize: 15,
          total: 2,
        ),
        completedAt: DateTime(2026, 8, 25),
      );
      expect(changed.updatedComicCount, 1);
      expect(
        manager.getComicUpdateInfo('list-test', 'c1', '')!.hasNewUpdate,
        isTrue,
      );
      expect(
        manager
            .getComicUpdateInfo('list-test', 'c1', '')!
            .sourceUpdateMetadata?['isNew'],
        isNull,
      );

      manager.markReadInAllFolders('list-test', 'c1');
      final repeated = manager.applyCompleteFavoriteUpdateSnapshot(
        data,
        folder,
        FavoriteUpdateSnapshot(
          comics: [_comic('c1', 'm1-new', '2026-08-22', isNew: true)],
          pageSize: 15,
          total: 1,
        ),
        completedAt: DateTime(2026, 8, 26),
      );
      expect(repeated.updatedComicCount, 0);
      expect(
        manager.getComicUpdateInfo('list-test', 'c1', '')!.hasNewUpdate,
        isFalse,
      );
    },
  );

  test('list snapshots may omit activity time without fabricating one', () {
    final data = _data(markerScheme: 'chapter-v1');
    final result = manager.applyCompleteFavoriteUpdateSnapshot(
      data,
      folder,
      FavoriteUpdateSnapshot(
        comics: [
          _snapshotComic(
            'c1',
            'normal:chapter-1|full:',
            isNew: true,
            updateTime: null,
            fullIsNew: true,
          ),
        ],
        pageSize: 15,
        total: 1,
      ),
      completedAt: DateTime(2026, 8, 24),
    );

    expect(result.updatedComicCount, 1);
    final info = manager.getComicUpdateInfo('list-test', 'c1', '');
    expect(info, isNotNull);
    expect(info!.updateTime, isNull);
    expect(info.sourceActivityAt, isNull);
    expect(
      info.updateMarker,
      encodeFollowUpdateMarker('chapter-v1', 'normal:chapter-1|full:'),
    );
    expect(info.sourceUpdateMetadata, {'fullIsNew': true, 'isNew': true});
    expect(
      manager.getFavoriteUpdateScanState(folder)!.markerScheme,
      'chapter-v1',
    );
  });

  test(
    'same marker preserves prior time while a no-time marker change clears it',
    () {
      final data = _data(markerScheme: 'chapter-v1');
      final completedAt = DateTime(2026, 8, 24);
      manager.applyCompleteFavoriteUpdateSnapshot(
        data,
        folder,
        _snapshotWithComic(
          _snapshotComic(
            'c1',
            'normal:chapter-1|full:',
            updateTime: '2026-08-20',
          ),
        ),
        completedAt: completedAt,
      );

      manager.applyCompleteFavoriteUpdateSnapshot(
        data,
        folder,
        _snapshotWithComic(
          _snapshotComic('c1', 'normal:chapter-1|full:', updateTime: null),
        ),
        completedAt: completedAt.add(const Duration(days: 1)),
      );
      final same = manager.getComicUpdateInfo('list-test', 'c1', '')!;
      expect(same.updateTime, '2026-08-20');
      expect(same.sourceActivityAt, isNotNull);
      expect(same.hasNewUpdate, isFalse);

      final changed = manager.applyCompleteFavoriteUpdateSnapshot(
        data,
        folder,
        _snapshotWithComic(
          _snapshotComic('c1', 'normal:chapter-2|full:', updateTime: null),
        ),
        completedAt: completedAt.add(const Duration(days: 2)),
      );
      expect(changed.updatedComicCount, 1);
      final changedInfo = manager.getComicUpdateInfo('list-test', 'c1', '')!;
      expect(changedInfo.updateTime, isNull);
      expect(changedInfo.sourceActivityAt, isNull);
      expect(changedInfo.hasNewUpdate, isTrue);
    },
  );

  test('scheme migration to a no-time marker clears legacy activity time', () {
    final oldData = _data(markerScheme: 'time-v1');
    final newData = _data(markerScheme: 'chapter-v1');
    manager.applyCompleteFavoriteUpdateSnapshot(
      oldData,
      folder,
      _snapshotWithComic(
        _snapshotComic('c1', 'legacy-time', updateTime: '2026-08-20'),
      ),
      completedAt: DateTime(2026, 8, 24),
    );
    final migrated = manager.applyCompleteFavoriteUpdateSnapshot(
      newData,
      folder,
      _snapshotWithComic(
        _snapshotComic(
          'c1',
          'normal:chapter-3|full:',
          updateTime: null,
          isNew: false,
        ),
      ),
      completedAt: DateTime(2026, 8, 25),
    );

    expect(migrated.updatedComicCount, 0);
    final info = manager.getComicUpdateInfo('list-test', 'c1', '')!;
    expect(info.updateTime, isNull);
    expect(info.sourceActivityAt, isNull);
    expect(info.hasNewUpdate, isFalse);
    expect(
      info.updateMarker,
      encodeFollowUpdateMarker('chapter-v1', 'normal:chapter-3|full:'),
    );
  });

  test('list scan failures use the prescribed capped backoff', () {
    final at = DateTime(2026, 8, 24);
    manager.recordFavoriteUpdateScanFailure(folder, failedAt: at);
    expect(
      manager.getFavoriteUpdateScanState(folder)!.retryAfter,
      at.add(const Duration(hours: 1)),
    );
    manager.recordFavoriteUpdateScanFailure(folder, failedAt: at);
    expect(
      manager.getFavoriteUpdateScanState(folder)!.retryAfter,
      at.add(const Duration(hours: 6)),
    );
  });

  test('only list-strategy session invalidation advances the epoch', () {
    final listData = _data();
    ComicSourceManager().add(_listSource(listData));
    manager.recordFavoriteUpdateScanAttempt(
      folder,
      attemptedAt: DateTime(2026, 8, 24),
    );
    final listEpoch = manager.captureFavoriteSessionEpoch('list-test');
    manager.invalidateFavoriteSessionForSource('list-test');
    expect(manager.captureFavoriteSessionEpoch('list-test'), listEpoch + 1);
    expect(manager.getFavoriteUpdateScanState(folder), isNull);

    final detailSource = _detailSource();
    ComicSourceManager().add(detailSource);
    const detailFolder = NetworkFavoriteFolderRef(
      sourceKey: 'detail-test',
      folderId: 'remote',
    );
    manager.recordFavoriteUpdateScanAttempt(
      detailFolder,
      attemptedAt: DateTime(2026, 8, 24),
    );
    final detailState = manager.getFavoriteUpdateScanState(detailFolder);
    final detailEpoch = manager.captureFavoriteSessionEpoch('detail-test');
    manager.invalidateFavoriteSessionForSource('detail-test');
    expect(manager.captureFavoriteSessionEpoch('detail-test'), detailEpoch);
    expect(
      manager.getFavoriteUpdateScanState(detailFolder)!.lastAttemptAt,
      detailState!.lastAttemptAt,
    );
  });

  test(
    'pending work uses the requested mode for list and detail sources',
    () async {
      final listData = _data();
      ComicSourceManager().add(_listSource(listData));
      final completedAt = DateTime(2026, 8, 1);
      final dueAt = DateTime(2026, 8, 3);
      manager.applyCompleteFavoriteUpdateSnapshot(
        listData,
        folder,
        _snapshot('m1'),
        completedAt: completedAt,
      );

      expect(
        hasPendingFollowUpdateWork(
          mode: FollowUpdateMode.regular,
          folders: [folder],
          now: dueAt,
        ),
        isTrue,
      );
      expect(
        hasPendingFollowUpdateWork(
          mode: FollowUpdateMode.missing,
          folders: [folder],
          now: dueAt,
        ),
        isFalse,
      );

      var skippedMissingCalls = 0;
      final stableData = _data(
        updateLoader: ([_]) async {
          skippedMissingCalls++;
          return Res(_snapshot('must-not-load'));
        },
      );
      ComicSourceManager().remove('list-test');
      ComicSourceManager().add(_listSource(stableData));
      manager.applyCompleteFavoriteUpdateSnapshot(
        stableData,
        folder,
        _snapshot('m1'),
        completedAt: completedAt,
      );
      await scanFollowUpdates(
        [folder],
        FollowUpdateMode.missing,
        cache: manager,
        clock: () => dueAt,
        delay: (_) async {},
      ).toList();
      expect(skippedMissingCalls, 0);
      expect(
        manager.getFavoriteUpdateScanState(folder)!.lastSuccessAt,
        completedAt,
      );

      manager.clearAllBaselines(now: dueAt);
      expect(
        hasPendingFollowUpdateWork(
          mode: FollowUpdateMode.regular,
          folders: [folder],
          now: dueAt,
        ),
        isTrue,
      );
      expect(
        hasPendingFollowUpdateWork(
          mode: FollowUpdateMode.missing,
          folders: [folder],
          now: dueAt,
        ),
        isTrue,
      );

      var missingCalls = 0;
      final missingData = _data(
        updateLoader: ([_]) async {
          missingCalls++;
          return Res(_snapshot('missing-complete'));
        },
      );
      ComicSourceManager().remove('list-test');
      ComicSourceManager().add(_listSource(missingData));
      await scanFollowUpdates(
        [folder],
        FollowUpdateMode.missing,
        cache: manager,
        clock: () => completedAt,
        delay: (_) async {},
      ).toList();
      expect(missingCalls, 1);
      expect(
        hasPendingFollowUpdateWork(
          mode: FollowUpdateMode.missing,
          folders: [folder],
          now: dueAt,
        ),
        isFalse,
      );
      expect(
        hasPendingFollowUpdateWork(
          mode: FollowUpdateMode.regular,
          folders: [folder],
          now: dueAt,
        ),
        isTrue,
      );

      manager.applyCompleteFavoriteUpdateSnapshot(
        missingData,
        folder,
        _snapshot('m1'),
        completedAt: completedAt,
      );
      ComicSourceManager().remove('list-test');
      ComicSourceManager().add(_listSource(_data(markerScheme: 'list-v2')));
      expect(
        hasPendingFollowUpdateWork(
          mode: FollowUpdateMode.regular,
          folders: [folder],
          now: dueAt,
        ),
        isTrue,
      );
      expect(
        hasPendingFollowUpdateWork(
          mode: FollowUpdateMode.missing,
          folders: [folder],
          now: dueAt,
        ),
        isTrue,
      );

      final detailSource = _detailSource();
      ComicSourceManager().add(detailSource);
      const detailFolder = NetworkFavoriteFolderRef(
        sourceKey: 'detail-test',
        folderId: 'remote',
        title: 'Detail test',
      );
      final detailData = FavoriteData(
        key: 'detail-test',
        title: 'Detail test',
        multiFolder: true,
        loadComic: (page, [folder]) async => Res([
          Comic(
            'Comic c1',
            'cover-c1',
            'c1',
            null,
            const [],
            '',
            'detail-test',
            null,
            null,
          ),
        ], subData: 1),
        loadNext: null,
      );
      await manager.refreshFolders(detailData);
      await manager.refreshPage(detailData, detailFolder, 1);
      manager.recordComicCheckEverywhere(
        'detail-test',
        'c1',
        completedAt: completedAt,
        updateMarker: 'detail-v1|m1',
      );
      expect(
        hasPendingFollowUpdateWork(
          mode: FollowUpdateMode.regular,
          folders: [detailFolder],
          now: dueAt,
        ),
        isTrue,
      );
      expect(
        hasPendingFollowUpdateWork(
          mode: FollowUpdateMode.missing,
          folders: [detailFolder],
          now: dueAt,
        ),
        isFalse,
      );
    },
  );

  test(
    'a list scan cannot commit a response from an invalidated session',
    () async {
      final initialData = _data();
      ComicSourceManager().add(_listSource(initialData));
      manager.applyCompleteFavoriteUpdateSnapshot(
        initialData,
        folder,
        _snapshot('old-marker'),
        completedAt: DateTime(2026, 8, 1),
      );

      final started = Completer<void>();
      final response = Completer<Res<FavoriteUpdateSnapshot>>();
      final deferredData = _data(
        updateLoader: ([_]) {
          if (!started.isCompleted) started.complete();
          return response.future;
        },
      );
      ComicSourceManager().remove('list-test');
      ComicSourceManager().add(_listSource(deferredData));

      final scan = scanFollowUpdates(
        [folder],
        FollowUpdateMode.force,
        cache: manager,
        clock: () => DateTime(2026, 8, 2),
        delay: (_) async {},
      ).toList();
      await started.future.timeout(const Duration(seconds: 5));
      final before = manager.captureFavoriteSessionEpoch('list-test');
      manager.invalidateFavoriteSessionForSource('list-test');
      expect(manager.captureFavoriteSessionEpoch('list-test'), before + 1);
      response.complete(Res(_snapshot('new-marker')));
      await scan.timeout(const Duration(seconds: 5));

      expect(manager.getFavoriteUpdateScanState(folder), isNull);
      expect(manager.isFullCacheRunning(folder), isFalse);
      expect(manager.getCachedPage(folder, 1)!.comics.single.id, 'c1');
      final staleInfo = manager.getComicUpdateInfo('list-test', 'c1', '');
      expect(staleInfo!.updateMarker, isNull);
      expect(staleInfo.hasNewUpdate, isFalse);
      expect(staleInfo.sourceUpdateMetadata, isNull);

      var newCalls = 0;
      final freshData = _data(
        updateLoader: ([_]) async {
          newCalls++;
          return Res(_snapshot('fresh-marker'));
        },
      );
      ComicSourceManager().remove('list-test');
      ComicSourceManager().add(_listSource(freshData));
      await scanFollowUpdates(
        [folder],
        FollowUpdateMode.force,
        cache: manager,
        clock: () => DateTime(2026, 8, 3),
        delay: (_) async {},
      ).toList();
      expect(newCalls, 1);
      expect(
        manager.getFavoriteUpdateScanState(folder)!.lastSuccessAt,
        isNotNull,
      );
      expect(
        manager.getComicUpdateInfo('list-test', 'c1', '')!.updateMarker,
        encodeFollowUpdateMarker('list-v1', 'fresh-marker'),
      );
    },
  );

  test(
    'clearAllCache cancels an in-flight list scan without recreating cache',
    () async {
      final initialData = _data();
      ComicSourceManager().add(_listSource(initialData));
      manager.applyCompleteFavoriteUpdateSnapshot(
        initialData,
        folder,
        _snapshot('old-marker'),
        completedAt: DateTime(2026, 8, 1),
      );

      final started = Completer<void>();
      final response = Completer<Res<FavoriteUpdateSnapshot>>();
      final deferredData = _data(
        updateLoader: ([_]) {
          if (!started.isCompleted) started.complete();
          return response.future;
        },
      );
      ComicSourceManager().remove('list-test');
      ComicSourceManager().add(_listSource(deferredData));

      final scan = scanFollowUpdates(
        [folder],
        FollowUpdateMode.force,
        cache: manager,
        clock: () => DateTime(2026, 8, 2),
        delay: (_) async {},
      ).toList();
      await started.future.timeout(const Duration(seconds: 5));
      expect(manager.isFullCacheRunning(folder), isTrue);

      final before = manager.captureFavoriteSessionEpoch('list-test');
      manager.clearAllCache();
      expect(manager.captureFavoriteSessionEpoch('list-test'), before + 1);
      expect(manager.getCachedFolders('list-test'), isEmpty);
      expect(manager.getCachedPage(folder, 1), isNull);
      expect(manager.countCachedComics(folder), 0);
      expect(manager.getFavoriteUpdateScanState(folder), isNull);

      response.complete(Res(_snapshot('ignored-marker')));
      final events = await scan.timeout(const Duration(seconds: 5));

      expect(events, hasLength(2));
      expect(events.every((event) => event.total == 1), isTrue);
      expect(events.every((event) => event.current == 0), isTrue);
      expect(events.every((event) => event.errors == 0), isTrue);
      expect(manager.getCachedFolders('list-test'), isEmpty);
      expect(manager.getCachedPage(folder, 1), isNull);
      expect(manager.countCachedComics(folder), 0);
      expect(manager.getFavoriteUpdateScanState(folder), isNull);
      expect(manager.isFullCacheRunning(folder), isFalse);
    },
  );

  test('Cache All treats clearAllCache response as canceled', () async {
    final started = Completer<void>();
    final response = Completer<Res<FavoriteUpdateSnapshot>>();
    final data = _data(
      updateLoader: ([_]) {
        if (!started.isCompleted) started.complete();
        return response.future;
      },
    );
    ComicSourceManager().add(_listSource(data));

    final eventsFuture = manager
        .cacheAllPages(data, folder, isCanceled: () => false)
        .toList();
    await started.future.timeout(const Duration(seconds: 5));
    manager.clearAllCache();
    response.complete(Res(_snapshot('ignored-marker')));
    final events = await eventsFuture.timeout(const Duration(seconds: 5));

    expect(events, hasLength(1));
    expect(events.single.isCanceled, isTrue);
    expect(events.single.errorMessage, isNull);
    expect(manager.getFavoriteUpdateScanState(folder), isNull);
    expect(manager.getCachedFolders('list-test'), isEmpty);
    expect(manager.getCachedPage(folder, 1), isNull);
    expect(manager.countCachedComics(folder), 0);
    expect(manager.isFullCacheRunning(folder), isFalse);
  });

  test('page and cursor refreshes reject stale list responses', () async {
    final initialData = _data(
      pageLoader: (page, [folder]) async =>
          Res([_snapshotComic('c1', 'old-page')], subData: 1),
    );
    ComicSourceManager().add(_listSource(initialData));
    await manager.refreshFolders(initialData);
    final initial = await manager.refreshPage(initialData, folder, 1);
    expect(initial.success, isTrue);

    final pageStarted = Completer<void>();
    final pageResponse = Completer<Res<List<Comic>>>();
    final deferredPageData = _data(
      pageLoader: (page, [folder]) {
        if (!pageStarted.isCompleted) pageStarted.complete();
        return pageResponse.future;
      },
    );
    ComicSourceManager().remove('list-test');
    ComicSourceManager().add(_listSource(deferredPageData));
    final pageRefresh = manager.refreshPage(deferredPageData, folder, 1);
    await pageStarted.future.timeout(const Duration(seconds: 5));
    manager.invalidateFavoriteSessionForSource('list-test');
    pageResponse.complete(
      Res([_snapshotComic('c1', 'stale-page')], subData: 1),
    );
    final pageResult = await pageRefresh.timeout(const Duration(seconds: 5));
    expect(pageResult.errorMessage, 'Favorite session changed');
    expect(manager.getCachedPage(folder, 1)!.comics.single.id, 'c1');

    final cursorStarted = Completer<void>();
    final cursorResponse = Completer<Res<List<Comic>>>();
    final deferredCursorData = _data(
      nextLoader: (token, [folder]) {
        if (!cursorStarted.isCompleted) cursorStarted.complete();
        return cursorResponse.future;
      },
    );
    ComicSourceManager().remove('list-test');
    ComicSourceManager().add(_listSource(deferredCursorData));
    final cursorRefresh = manager.refreshNextPage(
      deferredCursorData,
      folder,
      null,
    );
    await cursorStarted.future.timeout(const Duration(seconds: 5));
    manager.invalidateFavoriteSessionForSource('list-test');
    cursorResponse.complete(
      Res([_snapshotComic('c2', 'stale-cursor')], subData: null),
    );
    final cursorResult = await cursorRefresh.timeout(
      const Duration(seconds: 5),
    );
    expect(cursorResult.errorMessage, 'Favorite session changed');
    expect(manager.getCachedNextPage(folder, null), isNull);

    final legacyData = FavoriteData(
      key: 'legacy-test',
      title: 'Legacy test',
      multiFolder: false,
      loadComic: (page, [folder]) async => Res([
        Comic(
          'Legacy comic',
          'cover-legacy',
          'legacy-c1',
          null,
          const [],
          '',
          'legacy-test',
          null,
          null,
        ),
      ], subData: 1),
      loadNext: null,
    );
    const legacyFolder = NetworkFavoriteFolderRef(
      sourceKey: 'legacy-test',
      folderId: '',
    );
    final legacyResult = await manager.refreshPage(legacyData, legacyFolder, 1);
    expect(legacyResult.success, isTrue);
  });

  test(
    'list Recheck returns a session-change error without committing',
    () async {
      final initialData = _data(
        pageLoader: (page, [folder]) async =>
            Res([_snapshotComic('c1', 'old-recheck')], subData: 1),
      );
      ComicSourceManager().add(_listSource(initialData));
      await manager.refreshFolders(initialData);
      await manager.refreshPage(initialData, folder, 1);

      final started = Completer<void>();
      final response = Completer<Res<FavoriteUpdateSnapshot>>();
      final deferredData = _data(
        updateLoader: ([_]) {
          if (!started.isCompleted) started.complete();
          return response.future;
        },
      );
      ComicSourceManager().remove('list-test');
      ComicSourceManager().add(_listSource(deferredData));
      final recheck = recheckFavoriteComicDetailed(
        'list-test',
        'c1',
        cache: manager,
      );
      await started.future.timeout(const Duration(seconds: 5));
      manager.invalidateFavoriteSessionForSource('list-test');
      response.complete(Res(_snapshot('stale-recheck')));
      final result = await recheck.timeout(const Duration(seconds: 5));

      expect(result.succeeded, isFalse);
      expect(result.errorMessage, 'Favorite session changed');
      expect(manager.getFavoriteUpdateScanState(folder), isNull);
      expect(manager.getCachedPage(folder, 1)!.comics.single.id, 'c1');
      expect(manager.isFullCacheRunning(folder), isFalse);
    },
  );
}
