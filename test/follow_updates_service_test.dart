import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/follow_updates_page.dart';

FavoriteItem _comic(String id) => FavoriteItem(
  id: id,
  name: 'Comic $id',
  coverPath: 'https://example.invalid/$id.jpg',
  author: 'Author',
  sourceKeyValue: 'test-source',
  tags: const ['tag'],
);

FavoriteData _numericData(
  Future<Res<List<Comic>>> Function(int page, [String? folder]) loader,
) => FavoriteData(
  key: 'test-source',
  title: 'Test source',
  multiFolder: true,
  loadComic: loader,
  loadNext: null,
  loadFolders: ([String? _]) async =>
      const Res(<String, String>{'remote': 'Remote'}),
);

ComicSource _detailSource(
  Future<Res<ComicDetails>> Function(String id) loader,
) {
  return ComicSource(
    'Test source',
    'test-source',
    null,
    null,
    null,
    null,
    const [],
    null,
    null,
    loader,
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
}

Future<Res<ComicDetails>> _details(String id) async => Res(
  ComicDetails.fromJson({
    'title': 'Comic $id',
    'subtitle': 'Author',
    'cover': '',
    'tags': <String, List<String>>{},
    'chapters': <String, String>{'1': 'Chapter 1'},
    'sourceKey': 'test-source',
    'comicId': id,
  }),
);

/// Polls [condition] until it is true or [timeout] elapses.
Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for condition');
    }
    await Future.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  late Directory tempDir;
  late NetworkFavoriteCacheManager cache;
  const folder = NetworkFavoriteFolderRef(
    sourceKey: 'test-source',
    folderId: 'remote',
    title: 'Remote',
  );

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('venera-follow-service-');
    cache = NetworkFavoriteCacheManager();
    await cache.init(
      databasePath: '${tempDir.path}${Platform.pathSeparator}cache.db',
      migrateLegacy: false,
    );
    appdata.settings['followUpdatesEnabled'] = true;
    appdata.settings['favorites'] = ['test-source'];
    appdata.settings['followUpdateThreads'] = 5;
    appdata.settings['followUpdateBatchDelay'] = 0.0;
    // Registered once; the service listener + periodic check are global.
    FollowUpdatesService.initChecker();
  });

  tearDownAll(() async {
    ComicSourceManager().remove('test-source');
    cache.close();
    await tempDir.delete(recursive: true);
  });

  test(
    'new comics cached after the previous scan finishes are auto-scanned',
    () async {
      final source = _detailSource(_details);
      source.data['account'] = <String, dynamic>{};
      ComicSourceManager().add(source);
      addTearDown(() => ComicSourceManager().remove('test-source'));

      final data = _numericData(
        (page, [folder]) async => Res(<Comic>[
          _comic('one'),
          _comic('two'),
          _comic('three'),
        ], subData: 1),
      );
      await cache.refreshFolders(data);
      await cache.cacheAllPages(data, folder, isCanceled: () => false).drain();

      // The auto scan establishes the baseline for the first batch.
      await _waitUntil(() => cache.countUncheckedComics(folder) == 0);

      // A later "full update" adds new comics after the queue has finished.
      final fuller = _numericData(
        (page, [folder]) async => Res(<Comic>[
          _comic('one'),
          _comic('two'),
          _comic('three'),
          _comic('four'),
          _comic('five'),
        ], subData: 1),
      );
      await cache
          .cacheAllPages(fuller, folder, isCanceled: () => false)
          .drain();

      await _waitUntil(() => cache.countUncheckedComics(folder) == 0);
      expect(cache.getComicsWithUpdatesInfo(folder).length, 5);
      expect(
        cache
            .getComicsWithUpdatesInfo(folder)
            .every((c) => c.lastCheckTime != null),
        isTrue,
      );
    },
  );

  test(
    'new comics cached while a scan is running are scanned after it ends',
    () async {
      const folderB = NetworkFavoriteFolderRef(
        sourceKey: 'test-source',
        folderId: 'remote-b',
        title: 'Remote B',
      );

      final gate = Completer<void>();
      var detailCalls = <String>[];
      final source = _detailSource((id) async {
        detailCalls.add(id);
        if (id == 'one') {
          await gate.future;
        }
        return _details(id);
      });
      source.data['account'] = <String, dynamic>{};
      ComicSourceManager().add(source);
      addTearDown(() => ComicSourceManager().remove('test-source'));

      final data = _numericData(
        (page, [folder]) async => Res(<Comic>[
          _comic('one'),
          _comic('two'),
          _comic('three'),
          _comic('four'),
          _comic('five'),
          _comic('six'),
        ], subData: 1),
      );
      await cache.cacheAllPages(data, folderB, isCanceled: () => false).drain();

      // Start a manual check quickly (before the 2s auto-scan debounce), with
      // comic 'one' blocked so the queue stays alive while we mutate the cache.
      // Clear any stale run left by the previous test's auto-scan so this
      // manual check starts a fresh queue instead of resuming it.
      // 'one'..'five' were just checked by the previous test (comic-level
      // state, 24h window), so only the fresh 'six' joins 'one' in the queue.
      cache.clearScanRun();
      final runFuture = FollowUpdatesService.runCheckNow();
      await _waitUntil(() => detailCalls.contains('six'));

      // While the queue is consuming, a full-cache style refresh adds comics.
      final fuller = _numericData(
        (page, [folder]) async => Res(<Comic>[
          _comic('one'),
          _comic('two'),
          _comic('three'),
          _comic('four'),
          _comic('five'),
          _comic('six'),
          _comic('seven'),
          _comic('eight'),
        ], subData: 1),
      );
      await cache
          .cacheAllPages(fuller, folderB, isCanceled: () => false)
          .drain();

      // Release the queue and wait for the manual check to finish, then the
      // auto-scan triggered by the cache change must fill the new gaps.
      gate.complete();
      await runFuture;

      await _waitUntil(() => cache.countUncheckedComics(folderB) == 0);
      expect(detailCalls, containsAll(<String>['seven', 'eight']));
      expect(
        cache
            .getComicsWithUpdatesInfo(folderB)
            .every((c) => c.lastCheckTime != null),
        isTrue,
      );
    },
  );
  test(
    'single-folder source comics are eligible for follow-up once cached',
    () async {
      const singleFolder = NetworkFavoriteFolderRef(
        sourceKey: 'test-source',
        folderId: '',
        title: 'Test source',
      );
      final source = _detailSource(_details);
      source.data['account'] = <String, dynamic>{};
      ComicSourceManager().add(source);
      addTearDown(() => ComicSourceManager().remove('test-source'));

      final data = _numericData(
        (page, [folder]) async => Res(<Comic>[
          _comic('one'),
          _comic('two'),
          _comic('three'),
        ], subData: 1),
      );
      // Single-folder sources (e.g. PicAcg) cache pages directly without a
      // prior refreshFolders; the folder must still join the baseline.
      await cache.refreshPage(data, singleFolder, 1);

      final eligible = getFollowUpdateFolders();
      expect(
        eligible.any((f) => f.sourceKey == 'test-source' && f.folderId == ''),
        isTrue,
      );
      await _waitUntil(() => cache.countUncheckedComics(singleFolder) == 0);
    },
  );

  test('a manual check publishes live progress to baselineStatus', () async {
    final gate = Completer<void>();
    final source = _detailSource((id) async {
      if (id == 'progress-one') await gate.future;
      return _details(id);
    });
    source.data['account'] = <String, dynamic>{};
    ComicSourceManager().add(source);
    addTearDown(() => ComicSourceManager().remove('test-source'));

    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[
        _comic('progress-one'),
        _comic('progress-two'),
      ], subData: 1),
    );
    await cache.cacheAllPages(data, folder, isCanceled: () => false).drain();
    cache.clearScanRun();

    final runFuture = FollowUpdatesService.runCheckNow();
    // While 'progress-one' is blocked, the status must be live and carry the
    // queue size (regular mode includes every never-checked comic; the ids
    // are unique so the 24h comic-level window from earlier tests skips
    // nothing).
    await _waitUntil(
      () =>
          FollowUpdatesService.baselineStatus.value?.isRunning == true &&
          (FollowUpdatesService.baselineStatus.value?.total ?? 0) >= 1,
    );

    gate.complete();
    await runFuture;
    // Every comic attempted -> status settles to null (no incomplete gap).
    await _waitUntil(() => FollowUpdatesService.baselineStatus.value == null);
  });

  test('random refresh publishes live progress to baselineStatus', () async {
    final gate = Completer<void>();
    final source = _detailSource((id) async {
      await gate.future;
      return _details(id);
    });
    source.data['account'] = <String, dynamic>{};
    ComicSourceManager().add(source);
    addTearDown(() => ComicSourceManager().remove('test-source'));

    final data = _numericData(
      (page, [folder]) async => Res(<Comic>[
        for (var i = 1; i <= 8; i++) _comic('random-$i'),
      ], subData: 1),
    );
    await cache.cacheAllPages(data, folder, isCanceled: () => false).drain();
    cache.clearScanRun();

    final runFuture = FollowUpdatesService.refreshRandomComics();
    // While every detail call is blocked, the status must be live with a
    // queue of 5-8 (the random pick, capped by the 8 cached comics).
    // The pick is 5 + random(6), capped by the cached comic count, so the
    // published total is anywhere in [5, 10] (earlier tests leave cached
    // comics behind, so the cap is not the 8 cached here).
    await _waitUntil(() {
      final s = FollowUpdatesService.baselineStatus.value;
      return s?.isRunning == true &&
          (s?.total ?? 0) >= 5 &&
          (s?.total ?? 0) <= 10;
    });

    gate.complete();
    await runFuture;
    // The random subset is a completed run: status settles to null.
    await _waitUntil(() => FollowUpdatesService.baselineStatus.value == null);
  });
}
