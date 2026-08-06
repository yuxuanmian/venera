import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/res.dart';

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

void main() {
  late Directory tempDir;
  late NetworkFavoriteCacheManager cache;
  const folder = NetworkFavoriteFolderRef(
    sourceKey: 'test-source',
    folderId: 'remote',
    title: 'Remote',
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('venera-follow-scan-');
    cache = NetworkFavoriteCacheManager.forTesting();
    await cache.init(
      databasePath: '${tempDir.path}${Platform.pathSeparator}cache.db',
      migrateLegacy: false,
    );
    // Zero the 400-confirmation and transient retry delays for fast tests.
    kNotFoundConfirmationDelays = const [
      Duration.zero,
      Duration.zero,
      Duration.zero,
    ];
    kTransientRetryDelay = Duration.zero;
    appdata.settings['followUpdateThreads'] = 5;
    appdata.settings['followUpdateBatchDelay'] = 0.0;
  });

  tearDown(() {
    kNotFoundConfirmationDelays = const [
      Duration(seconds: 3),
      Duration(seconds: 10),
      Duration(seconds: 30),
    ];
    kTransientRetryDelay = const Duration(seconds: 2);
    ComicSourceManager().remove('test-source');
    cache.close();
    tempDir.deleteSync(recursive: true);
  });

  Future<void> cacheComics(List<String> ids) async {
    final data = _numericData(
      (page, [folder]) async => Res(
        [for (final id in ids) _comic(id)],
        subData: 1,
      ),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);
  }

  group('classifyNotFoundError', () {
    test('status codes and wording', () {
      expect(
        classifyNotFoundError('Invalid Status Code: 404. Not found.'),
        NotFoundSignal.strong,
      );
      expect(
        classifyNotFoundError('Invalid Status Code: 410. Gone.'),
        NotFoundSignal.strong,
      );
      expect(
        classifyNotFoundError('Invalid Status Code: 400. The Request is invalid.'),
        NotFoundSignal.weak,
      );
      expect(
        classifyNotFoundError('Invalid Status Code: 401. The Request is unauthorized.'),
        NotFoundSignal.none,
      );
      expect(
        classifyNotFoundError('Invalid Status Code: 403. No permission.'),
        NotFoundSignal.none,
      );
      expect(
        classifyNotFoundError('Invalid Status Code: 429. Too many requests.'),
        NotFoundSignal.none,
      );
      expect(
        classifyNotFoundError('Invalid Status Code: 500. server-side error'),
        NotFoundSignal.none,
      );
      expect(classifyNotFoundError('该漫画已下架'), NotFoundSignal.strong);
      expect(classifyNotFoundError('内容不存在'), NotFoundSignal.strong);
      expect(classifyNotFoundError('需要验证码'), NotFoundSignal.none);
      expect(classifyNotFoundError('访问过于频繁'), NotFoundSignal.none);
      // Bare substrings without the status-code context no longer match.
      expect(classifyNotFoundError('id=404xxx'), NotFoundSignal.none);
      expect(classifyNotFoundError('Connection Timeout'), NotFoundSignal.none);
      expect(isNotFoundError('Invalid Status Code: 400. x'), isTrue);
      expect(isNotFoundError('Connection Timeout'), isFalse);
    });
  });

  group('400 confirmation session', () {
    test('three consecutive 400s confirm a delist and mark suspect', () async {
      await cacheComics(['one']);
      var calls = 0;
      final source = _detailSource((id) async {
        calls++;
        throw Exception('Invalid Status Code: 400. The Request is invalid.');
      });
      ComicSourceManager().add(source);

      final item = cache.getComicsWithUpdatesInfo(folder).single;
      final result = await updateComic(item, folder, cache: cache);

      expect(calls, 4); // initial + 3 confirmation retries
      expect(result.errorMessage, isNotNull);
      final fresh = cache.getComicsWithUpdatesInfo(folder).single;
      expect(fresh.isSuspectGone, isTrue);
    });

    test('a success during confirmation clears the pending state', () async {
      await cacheComics(['one']);
      var calls = 0;
      final source = _detailSource((id) async {
        calls++;
        if (calls < 4) {
          throw Exception('Invalid Status Code: 400. The Request is invalid.');
        }
        return _details(id);
      });
      ComicSourceManager().add(source);

      final item = cache.getComicsWithUpdatesInfo(folder).single;
      final result = await updateComic(item, folder, cache: cache);

      expect(calls, 4);
      expect(result.errorMessage, isNull);
      final fresh = cache.getComicsWithUpdatesInfo(folder).single;
      expect(fresh.isSuspectGone, isFalse);
      expect(fresh.lastCheckTime, isNotNull);
    });

    test('a non-400 response during confirmation is transient, not delist', () async {
      await cacheComics(['one']);
      var calls = 0;
      final source = _detailSource((id) async {
        calls++;
        if (calls <= 2) {
          throw Exception('Invalid Status Code: 400. The Request is invalid.');
        }
        throw Exception('Invalid Status Code: 429. Too many requests.');
      });
      ComicSourceManager().add(source);

      final item = cache.getComicsWithUpdatesInfo(folder).single;
      final result = await updateComic(item, folder, cache: cache);

      expect(result.errorMessage, isNotNull);
      final fresh = cache.getComicsWithUpdatesInfo(folder).single;
      // The transient response prevents any delist marking; the comic went
      // to the retry cooldown instead.
      expect(fresh.isSuspectGone, isFalse);
      expect(fresh.retryAfter, isNotNull);
    });
  });

  group('comic-level check state', () {
    test('page refresh keeps the suspect mark (Q1)', () async {
      await cacheComics(['one']);
      cache.markComicSuspectGoneEverywhere('test-source', 'one');
      expect(cache.isComicSuspectGone('test-source', 'one'), isTrue);

      // Re-caching the same page rebuilds the snapshot rows; the comic-level
      // state must survive.
      await cache.refreshPage(
        _numericData(
          (page, [folder]) async => Res(<Comic>[_comic('one')], subData: 1),
        ),
        folder,
        1,
      );
      expect(cache.isComicSuspectGone('test-source', 'one'), isTrue);
      expect(
        cache.getComicsWithUpdatesInfo(folder).single.isSuspectGone,
        isTrue,
      );
    });

    test('maxPage shrink and relocation keep the suspect mark (Q2/Q3)', () async {
      // Two pages of comics; 'one' lives on page 2 and is suspected gone.
      final data = _numericData(
        (page, [folder]) async => Res(
          [for (final id in ['three', 'four', 'five']) _comic(id)],
          subData: 2,
        ),
      );
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);
      await cache.refreshPage(
        _numericData(
          (page, [folder]) async => Res(<Comic>[_comic('one')], subData: 2),
        ),
        folder,
        2,
      );
      cache.markComicSuspectGoneEverywhere('test-source', 'one');

      // Remote deletes comics, maxPage shrinks to 1 and 'one' moves onto the
      // first page. Refreshing page 1 must not lose the mark.
      await cache.refreshPage(
        _numericData(
          (page, [folder]) async => Res(
            [for (final id in ['one', 'three', 'four', 'five']) _comic(id)],
            subData: 1,
          ),
        ),
        folder,
        1,
      );
      expect(cache.isComicSuspectGone('test-source', 'one'), isTrue);
      expect(
        cache.getComicsWithUpdatesInfo(folder).firstWhere((c) => c.id == 'one').isSuspectGone,
        isTrue,
      );
    });

    test('old row state migrates into the comic-level table once', () async {
      // Seed a legacy-style DB: state lives in favorite_items rows.
      final db = sqlite3.open(
        '${tempDir.path}${Platform.pathSeparator}cache.db',
      );
      db.execute(
        '''INSERT INTO favorite_items
           (source_key, folder_id, page_index, comic_id, display_order,
            comic_json, favorite_time, last_check_time, check_suspect_gone)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          'test-source',
          'remote',
          0,
          'legacy-one',
          0,
          jsonEncode(_comic('legacy-one').toCacheJson()),
          '2026-8-1 00:00:00',
          DateTime.now().millisecondsSinceEpoch,
          1,
        ],
      );
      db.dispose();
      // Reopen (fresh init) to run the migration.
      cache.close();
      cache = NetworkFavoriteCacheManager.forTesting();
      await cache.init(
        databasePath: '${tempDir.path}${Platform.pathSeparator}cache.db',
        migrateLegacy: false,
      );

      expect(cache.isComicSuspectGone('test-source', 'legacy-one'), isTrue);

      // Second init must not re-apply stale row snapshots: clear the state,
      // keep the legacy row, reopen, and the mark must stay cleared.
      cache.clearComicSuspectGoneEverywhere('test-source', 'legacy-one');
      cache.close();
      cache = NetworkFavoriteCacheManager.forTesting();
      await cache.init(
        databasePath: '${tempDir.path}${Platform.pathSeparator}cache.db',
        migrateLegacy: false,
      );
      expect(cache.isComicSuspectGone('test-source', 'legacy-one'), isFalse);
    });

    test('removed comics drop from listings but their state is reusable', () async {
      await cacheComics(['one']);
      cache.markComicSuspectGoneEverywhere('test-source', 'one');

      // The comic disappears from the remote list; refreshing shrinks maxPage
      // and removes the row (favorite_pages keep the item out of view).
      await cache.refreshPage(
        _numericData(
          (page, [folder]) async => const Res(<Comic>[], subData: 0),
        ),
        folder,
        1,
      );
      expect(cache.getComicsWithUpdatesInfo(folder), isEmpty);

      // The comic comes back later; the old mark resurfaces with it.
      await cache.refreshPage(
        _numericData(
          (page, [folder]) async => Res(<Comic>[_comic('one')], subData: 1),
        ),
        folder,
        1,
      );
      expect(cache.isComicSuspectGone('test-source', 'one'), isTrue);
    });
  });

  group('scan pipeline', () {
    test('comics in several folders are deduplicated to one request', () async {
      const folderB = NetworkFavoriteFolderRef(
        sourceKey: 'test-source',
        folderId: 'remote-b',
        title: 'Remote B',
      );
      final data = _numericData(
        (page, [folder]) async =>
            Res(<Comic>[_comic('one'), _comic('two')], subData: 1),
      );
      await cache.refreshFolders(data);
      await cache.refreshPage(data, folder, 1);
      await cache.refreshPage(data, folderB, 1);

      var calls = <String>[];
      final source = _detailSource((id) async {
        calls.add(id);
        return _details(id);
      });
      ComicSourceManager().add(source);

      await scanFollowUpdates(
        [folder, folderB],
        FollowUpdateMode.force,
        ignoreRetryAfter: true,
        cache: cache,
      ).toList();

      expect(calls.where((id) => id == 'one').length, 1);
      expect(calls.where((id) => id == 'two').length, 1);
    });

    test('an interrupted scan is resumed by the next scan without re-requesting done items', () async {
      await cacheComics(['one', 'two', 'three', 'four']);
      final gate = Completer<void>();
      var calls = <String>[];
      final source = _detailSource((id) async {
        calls.add(id);
        if (id == 'one' && calls.where((c) => c == 'one').length == 1) {
          await gate.future; // simulate a crash while 'one' is in flight
        }
        return _details(id);
      });
      ComicSourceManager().add(source);

      // First scan: 'one' blocks forever, the rest complete.
      final firstScan = scanFollowUpdates(
        [folder],
        FollowUpdateMode.missing,
        cache: cache,
      ).toList();
      await _waitUntil(() => calls.toSet().containsAll(['two', 'three', 'four']));

      // Abandon the first scan (no cancel) and start a new one: it must
      // resume the interrupted run and only request the pending comic.
      final secondScan = scanFollowUpdates(
        [folder],
        FollowUpdateMode.regular,
        cache: cache,
      ).toList();
      await _waitUntil(() => calls.where((c) => c == 'one').length >= 2);
      gate.complete();
      await secondScan;
      await firstScan;

      expect(calls.where((c) => c == 'two').length, 1);
      expect(calls.where((c) => c == 'three').length, 1);
      expect(calls.where((c) => c == 'four').length, 1);
      expect(
        cache.getComicsWithUpdatesInfo(folder).every((c) => c.lastCheckTime != null),
        isTrue,
      );
      expect(cache.getCurrentScanRun()!.status, 'finished');
    });

    test('a run of transient errors still terminates with a finished run', () async {
      await cacheComics(['one', 'two']);
      final source = _detailSource((id) async {
        throw Exception('Connection Timeout');
      });
      ComicSourceManager().add(source);

      final progress = await scanFollowUpdates(
        [folder],
        FollowUpdateMode.missing,
        cache: cache,
      ).toList();

      expect(progress.last.total, 2);
      expect(progress.last.current, 2);
      expect(progress.last.errors, 2);
      expect(
        cache
            .getComicsWithUpdatesInfo(folder)
            .every((c) => c.retryAfter != null),
        isTrue,
      );
      expect(cache.getCurrentScanRun()!.status, 'finished');
    });

    test('mid-run risk control rolls back marks and stops marking', () async {
      await cacheComics([
        'one',
        'two',
        'three',
        'four',
        'five',
        'six',
        'seven',
        'eight',
      ]);
      final source = _detailSource((id) async {
        if (id == 'one' || id == 'two') return _details(id);
        throw Exception('Invalid Status Code: 400. The Request is invalid.');
      });
      ComicSourceManager().add(source);

      await scanFollowUpdates(
        [folder],
        FollowUpdateMode.force,
        ignoreRetryAfter: true,
        cache: cache,
      ).toList();

      final all = cache.getComicsWithUpdatesInfo(folder);
      // Three confirmed 400s in one run trip the bulk-delist detector: every
      // mark made by this run is rolled back and later comics fall back to
      // the transient retry path instead of being marked.
      expect(all.every((c) => !c.isSuspectGone), isTrue);
      expect(
        all.every(
          (c) =>
              c.lastCheckTime != null ||
              c.retryAfter != null,
        ),
        isTrue,
      );
    });

    test('a source with no successful check never accumulates delist hits', () async {
      await cacheComics(['one']);
      final source = _detailSource((id) async {
        throw Exception('Invalid Status Code: 404. Not found.');
      });
      ComicSourceManager().add(source);

      await scanFollowUpdates(
        [folder],
        FollowUpdateMode.force,
        ignoreRetryAfter: true,
        cache: cache,
      ).toList();

      final fresh = cache.getComicsWithUpdatesInfo(folder).single;
      expect(fresh.checkNotFoundCount, 0);
      expect(fresh.isSuspectGone, isFalse);
      expect(fresh.retryAfter, isNotNull);
    });
  });
}

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
