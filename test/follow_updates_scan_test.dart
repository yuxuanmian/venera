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

FavoriteItem _comic(String id, {String sourceKey = 'test-source'}) =>
    FavoriteItem(
      id: id,
      name: 'Comic $id',
      coverPath: 'https://example.invalid/$id.jpg',
      author: 'Author',
      sourceKeyValue: sourceKey,
      tags: const ['tag'],
    );

FavoriteData _numericData(
  Future<Res<List<Comic>>> Function(int page, [String? folder]) loader, {
  String sourceKey = 'test-source',
}) => FavoriteData(
  key: sourceKey,
  title: 'Test source',
  multiFolder: true,
  loadComic: loader,
  loadNext: null,
  loadFolders: ([String? _]) async =>
      const Res(<String, String>{'remote': 'Remote'}),
);

ComicSource _detailSource(
  Future<Res<ComicDetails>> Function(String id) loader, {
  String sourceKey = 'test-source',
}) {
  return ComicSource(
    'Test source',
    sourceKey,
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

/// A source with a list (folders) endpoint, so the re-probe logic has
/// something to probe.
ComicSource _detailSourceWithFavorite(
  Future<Res<ComicDetails>> Function(String id) loader, {
  required Future<Res<Map<String, String>>> Function([String?]) loadFolders,
  String sourceKey = 'test-source',
}) {
  return ComicSource(
    'Test source',
    sourceKey,
    null,
    null,
    null,
    FavoriteData(
      key: sourceKey,
      title: 'Test source',
      multiFolder: true,
      loadComic: null,
      loadNext: null,
      loadFolders: loadFolders,
    ),
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

class _TestScanToken implements ScanCancellationToken {
  bool canceled = false;

  @override
  bool get isCanceled => canceled;

  @override
  bool get isCurrent => true;

  @override
  bool get canCommit => !isCanceled;
}

Future<List<Object>> _collectScanErrors(Stream<UpdateProgress> stream) async {
  final errors = <Object>[];
  final done = Completer<void>();
  late StreamSubscription<UpdateProgress> subscription;
  subscription = stream.listen(
    (_) {},
    onError: (Object error, StackTrace _) => errors.add(error),
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );
  await done.future.timeout(const Duration(seconds: 5));
  await subscription.cancel();
  return errors;
}

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
    // Zero the transient retry delay for fast tests.
    kTransientRetryDelay = Duration.zero;
    appdata.settings['followUpdateThreads'] = 8;
    appdata.settings['followUpdateBatchDelay'] = 0.0;
    // Cross-run delist/probe state must not leak between tests.
    serviceErrorCounts.clear();
    probeWindowRequests.clear();
    probeWindowHits.clear();
  });

  tearDown(() {
    kTransientRetryDelay = const Duration(seconds: 2);
    kProbeWindowSize = 20;
    ComicSourceManager().remove('test-source');
    cache.close();
    tempDir.deleteSync(recursive: true);
  });

  Future<void> cacheComics(List<String> ids) async {
    final data = _numericData(
      (page, [folder]) async =>
          Res([for (final id in ids) _comic(id)], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);
  }

  group('scan run lifecycle', () {
    test('forwards a run lookup failure and still closes the stream', () async {
      final brokenDir = await Directory.systemTemp.createTemp(
        'venera-follow-scan-broken-',
      );
      addTearDown(() => brokenDir.delete(recursive: true));
      final brokenCache = NetworkFavoriteCacheManager.forTesting();
      await brokenCache.init(
        databasePath: '${brokenDir.path}${Platform.pathSeparator}cache.db',
        migrateLegacy: false,
      );
      // Force getCurrentScanRun to fail before a ScanRunInfo can be assigned.
      brokenCache.close();

      final errors = await _collectScanErrors(
        scanFollowUpdates([folder], FollowUpdateMode.force, cache: brokenCache),
      );

      expect(errors, hasLength(1));
      expect(
        errors.single.toString(),
        isNot(contains('LateInitializationError')),
      );
    });

    test(
      'forwards createScanRun failures without writing a terminal run',
      () async {
        await cacheComics(['one']);
        final database = sqlite3.open(
          '${tempDir.path}${Platform.pathSeparator}cache.db',
        );
        try {
          database.execute('''
          CREATE TRIGGER fail_create_scan_run
          BEFORE INSERT ON scan_queue
          BEGIN
            SELECT RAISE(ABORT, 'injected createScanRun failure');
          END;
        ''');
        } finally {
          database.dispose();
        }

        final errors = await _collectScanErrors(
          scanFollowUpdates(
            [folder],
            FollowUpdateMode.force,
            ignoreRetryAfter: true,
            cache: cache,
          ),
        );

        expect(errors, hasLength(1));
        expect(
          errors.single.toString(),
          contains('injected createScanRun failure'),
        );
        expect(
          errors.single.toString(),
          isNot(contains('LateInitializationError')),
        );
        expect(cache.getCurrentScanRun(), isNull);
      },
    );
  });

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
        classifyNotFoundError(
          'Invalid Status Code: 400. The Request is invalid.',
        ),
        NotFoundSignal.weak,
      );
      expect(
        classifyNotFoundError(
          'Invalid Status Code: 401. The Request is unauthorized.',
        ),
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

  group('400 confirmation accumulation', () {
    test(
      'three accumulated 400 hits confirm a delist and mark suspect',
      () async {
        await cacheComics(['one']);
        var calls = 0;
        final source = _detailSource((id) async {
          calls++;
          throw Exception('Invalid Status Code: 400. The Request is invalid.');
        });
        ComicSourceManager().add(source);

        // Three rounds, each reading the fresh row like a separate scan run;
        // the worker never blocks on an inline confirmation session.
        for (var round = 0; round < 3; round++) {
          final item = cache.getComicsWithUpdatesInfo(folder).single;
          final result = await updateComic(item, folder, cache: cache);
          expect(result.errorMessage, isNotNull);
          final fresh = cache.getComicsWithUpdatesInfo(folder).single;
          if (round == 0) {
            expect(fresh.checkNotFoundCount, 1);
            expect(fresh.isSuspectGone, isFalse);
          } else if (round == 1) {
            expect(fresh.checkNotFoundCount, 2);
            expect(fresh.isSuspectGone, isFalse);
          } else {
            expect(fresh.isSuspectGone, isTrue);
            // The suspect mark resets the accumulated count.
            expect(fresh.checkNotFoundCount, 0);
          }
        }
        // One request per round; no inline confirmation retries anymore.
        expect(calls, 3);
      },
    );

    test('a success during accumulation clears the pending state', () async {
      await cacheComics(['one']);
      var calls = 0;
      final source = _detailSource((id) async {
        calls++;
        if (calls <= 2) {
          throw Exception('Invalid Status Code: 400. The Request is invalid.');
        }
        return _details(id);
      });
      ComicSourceManager().add(source);

      for (var round = 0; round < 2; round++) {
        final item = cache.getComicsWithUpdatesInfo(folder).single;
        final result = await updateComic(item, folder, cache: cache);
        expect(result.errorMessage, isNotNull);
      }
      var fresh = cache.getComicsWithUpdatesInfo(folder).single;
      expect(fresh.checkNotFoundCount, 2);
      expect(fresh.isSuspectGone, isFalse);

      final item = cache.getComicsWithUpdatesInfo(folder).single;
      final result = await updateComic(item, folder, cache: cache);
      expect(result.errorMessage, isNull);
      fresh = cache.getComicsWithUpdatesInfo(folder).single;
      // The successful check clears every delist/retry marker.
      expect(fresh.isSuspectGone, isFalse);
      expect(fresh.lastCheckTime, isNotNull);
      expect(fresh.checkNotFoundCount, 0);
    });

    test(
      'a non-400 response is transient, not delist, and keeps the count',
      () async {
        await cacheComics(['one']);
        var calls = 0;
        final source = _detailSource((id) async {
          calls++;
          if (calls <= 1) {
            throw Exception(
              'Invalid Status Code: 400. The Request is invalid.',
            );
          }
          throw Exception('Invalid Status Code: 429. Too many requests.');
        });
        ComicSourceManager().add(source);

        // Round 1: one bare 400 records a single hit.
        var item = cache.getComicsWithUpdatesInfo(folder).single;
        var result = await updateComic(item, folder, cache: cache);
        expect(result.errorMessage, isNotNull);
        var fresh = cache.getComicsWithUpdatesInfo(folder).single;
        expect(fresh.checkNotFoundCount, 1);
        expect(fresh.isSuspectGone, isFalse);

        // Round 2: risk control; transient retries, no delist mark, and the
        // accumulated 400 hit survives (only a success or mark resets it).
        item = cache.getComicsWithUpdatesInfo(folder).single;
        result = await updateComic(item, folder, cache: cache);
        expect(result.errorMessage, isNotNull);
        fresh = cache.getComicsWithUpdatesInfo(folder).single;
        expect(fresh.isSuspectGone, isFalse);
        expect(fresh.retryAfter, isNotNull);
        expect(fresh.checkNotFoundCount, 1);
      },
    );

    test(
      '400 hits accumulate across runs and confirm on the third hit',
      () async {
        // A single worker: the healthy comic sorts before the failing one, so
        // the source is healthy when the 400 hits, keeping the per-run counting
        // deterministic (main check records one hit, the retry phase re-check a
        // second).
        appdata.settings['followUpdateThreads'] = 1;
        addTearDown(() => appdata.settings['followUpdateThreads'] = 8);
        await cacheComics(['a-ok', 'b-bad']);
        final source = _detailSource((id) async {
          if (id == 'b-bad') {
            throw Exception(
              'Invalid Status Code: 400. The Request is invalid.',
            );
          }
          return _details(id);
        });
        ComicSourceManager().add(source);

        // Run 1: two hits recorded, not yet confirmed.
        await scanFollowUpdates(
          [folder],
          FollowUpdateMode.force,
          ignoreRetryAfter: true,
          cache: cache,
        ).toList();
        var bad = cache
            .getComicsWithUpdatesInfo(folder)
            .firstWhere((c) => c.id == 'b-bad');
        expect(bad.checkNotFoundCount, 2);
        expect(bad.isSuspectGone, isFalse);

        // Run 2: the third accumulated hit confirms the delist across runs.
        await scanFollowUpdates(
          [folder],
          FollowUpdateMode.force,
          ignoreRetryAfter: true,
          cache: cache,
        ).toList();
        bad = cache
            .getComicsWithUpdatesInfo(folder)
            .firstWhere((c) => c.id == 'b-bad');
        expect(bad.isSuspectGone, isTrue);
      },
    );
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

    test(
      'maxPage shrink and relocation keep the suspect mark (Q2/Q3)',
      () async {
        // Two pages of comics; 'one' lives on page 2 and is suspected gone.
        final data = _numericData(
          (page, [folder]) async => Res([
            for (final id in ['three', 'four', 'five']) _comic(id),
          ], subData: 2),
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
            (page, [folder]) async => Res([
              for (final id in ['one', 'three', 'four', 'five']) _comic(id),
            ], subData: 1),
          ),
          folder,
          1,
        );
        expect(cache.isComicSuspectGone('test-source', 'one'), isTrue);
        expect(
          cache
              .getComicsWithUpdatesInfo(folder)
              .firstWhere((c) => c.id == 'one')
              .isSuspectGone,
          isTrue,
        );
      },
    );

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

    test(
      'removed comics drop from listings but their state is reusable',
      () async {
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
      },
    );
  });

  group('scan pipeline', () {
    test('uses the new default concurrency and source interval values', () {
      expect(appdata.settings['followUpdateThreads'], 8);
      expect(
        calculateFollowUpdateSourceInterval(5),
        const Duration(milliseconds: 625),
      );
      expect(
        calculateFollowUpdateSourceInterval(5, slowMode: true),
        const Duration(milliseconds: 1250),
      );
      expect(calculateFollowUpdateSourceInterval(-1), Duration.zero);
      expect(calculateFollowUpdateSourceInterval(double.nan), Duration.zero);
    });

    test(
      'limiter enforces actual start spacing and applies queued slow mode',
      () async {
        await cacheComics([for (var i = 0; i < 20; i++) 'comic-$i']);
        appdata.settings['followUpdateBatchDelay'] = 0.008;
        var fakeNow = DateTime(2026, 8, 22);
        final starts = <DateTime>[];
        final firstCalls = <String>{};
        final source = _detailSource((id) async {
          if (firstCalls.add(id)) starts.add(fakeNow);
          throw Exception('Invalid Status Code: 500. server-side error');
        });
        ComicSourceManager().add(source);

        Future<void> advance(Duration duration) {
          fakeNow = fakeNow.add(duration);
          return Future<void>.value();
        }

        await scanFollowUpdates(
          [folder],
          FollowUpdateMode.force,
          ignoreRetryAfter: true,
          cache: cache,
          clock: () => fakeNow,
          delay: advance,
        ).toList();

        expect(starts, hasLength(20));
        for (var i = 1; i < starts.length; i++) {
          expect(
            starts[i].difference(starts[i - 1]),
            greaterThanOrEqualTo(const Duration(milliseconds: 1)),
          );
        }
        // The tenth completed action trips sourceSlowMode. Later requests
        // that were still queued must use the new 2ms gate interval.
        expect([
          for (var i = 11; i < starts.length; i++)
            starts[i].difference(starts[i - 1]),
        ], contains(greaterThanOrEqualTo(const Duration(milliseconds: 2))));
      },
    );

    test(
      'canceled FIFO permit transfer releases without entering start gate',
      () async {
        var fakeNow = DateTime(2026, 8, 22);
        final delayStarted = Completer<void>();
        final delayRelease = Completer<void>();
        var holdFirstDelay = true;
        Future<void> delay(Duration duration) async {
          if (holdFirstDelay) {
            holdFirstDelay = false;
            delayStarted.complete();
            await delayRelease.future;
          }
          fakeNow = fakeNow.add(duration);
        }

        final limiter = FollowUpdateRequestLimiter(
          maxConcurrentPerSource: 2,
          clock: () => fakeNow,
          delay: delay,
        );
        final firstToken = _TestScanToken();
        final canceledToken = _TestScanToken();
        final fourthToken = _TestScanToken();
        final firstActionGate = Completer<void>();
        final firstStarted = Completer<void>();
        final secondStarted = Completer<void>();
        var canceledActionStarted = false;

        final first = limiter.run<void>(
          'test-source',
          interval: () => const Duration(seconds: 1),
          token: firstToken,
          action: () async {
            firstStarted.complete();
            await firstActionGate.future;
          },
          onCompleted: (_) => canceledToken.canceled = true,
        );
        await firstStarted.future;

        final second = limiter.run<void>(
          'test-source',
          interval: () => const Duration(seconds: 1),
          token: firstToken,
          action: () async {
            secondStarted.complete();
          },
        );
        await delayStarted.future;

        final canceled = limiter.run<void>(
          'test-source',
          interval: () => const Duration(seconds: 1),
          token: canceledToken,
          action: () async {
            canceledActionStarted = true;
          },
        );
        final fourth = limiter.run<void>(
          'test-source',
          interval: () => const Duration(seconds: 1),
          token: fourthToken,
          action: () async {},
        );

        firstActionGate.complete();
        await canceled.timeout(const Duration(seconds: 1));
        expect(canceledActionStarted, isFalse);

        // The second action was deliberately holding the start gate. The
        // canceled request must release its transferred permit immediately,
        // so it cannot extend this wait or block the next FIFO waiter.
        delayRelease.complete();
        await Future.wait([first, second, fourth]);
        expect(secondStarted.isCompleted, isTrue);
      },
    );

    test(
      'probe, detail, and not-found retry share the source concurrency limit',
      () async {
        await cacheComics([
          'a-not-found',
          'b-one',
          'c-two',
          'd-three',
          'e-four',
        ]);
        final detailGate = Completer<void>();
        final probeStarted = Completer<void>();
        var active = 0;
        var maxActive = 0;
        var notFoundDetailCalls = 0;

        void enter() {
          active++;
          maxActive = active > maxActive ? active : maxActive;
        }

        final source = _detailSourceWithFavorite(
          (id) async {
            enter();
            try {
              if (id == 'a-not-found') {
                notFoundDetailCalls++;
                throw Exception('Invalid Status Code: 404. Not found.');
              }
              await detailGate.future;
              return _details(id);
            } finally {
              active--;
            }
          },
          loadFolders: ([String? _]) async {
            enter();
            if (!probeStarted.isCompleted) probeStarted.complete();
            try {
              return const Res(<String, String>{'remote': 'Remote'});
            } finally {
              active--;
            }
          },
        );
        ComicSourceManager().add(source);

        final scan = scanFollowUpdates(
          [folder],
          FollowUpdateMode.force,
          ignoreRetryAfter: true,
          cache: cache,
        ).toList();
        await probeStarted.future.timeout(const Duration(seconds: 5));
        expect(active, lessThanOrEqualTo(5));
        expect(maxActive, 5);
        detailGate.complete();

        await scan;
        expect(notFoundDetailCalls, greaterThanOrEqualTo(2));
        expect(maxActive, lessThanOrEqualTo(5));
      },
    );

    test(
      'allows five same-source actions but never a sixth in flight',
      () async {
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
        final gate = Completer<void>();
        final fiveStarted = Completer<void>();
        var active = 0;
        var maxActive = 0;
        var calls = 0;
        final source = _detailSource((id) async {
          calls++;
          active++;
          maxActive = active > maxActive ? active : maxActive;
          if (active == 5 && !fiveStarted.isCompleted) {
            fiveStarted.complete();
          }
          try {
            await gate.future;
            return _details(id);
          } finally {
            active--;
          }
        });
        ComicSourceManager().add(source);

        final scan = scanFollowUpdates(
          [folder],
          FollowUpdateMode.force,
          ignoreRetryAfter: true,
          cache: cache,
        ).toList();
        await fiveStarted.future.timeout(const Duration(seconds: 5));
        expect(active, 5);
        expect(maxActive, 5);
        gate.complete();

        await scan;
        expect(calls, 8);
        expect(maxActive, 5);
        expect(cache.getCurrentScanRun()!.status, 'finished');
      },
    );

    test('keeps total detail actions at the configured global limit', () async {
      final gate = Completer<void>();
      final eightStarted = Completer<void>();
      final folders = <NetworkFavoriteFolderRef>[];
      var active = 0;
      var maxActive = 0;

      for (var i = 0; i < 10; i++) {
        final sourceKey = 'global-source-$i';
        final sourceFolder = NetworkFavoriteFolderRef(
          sourceKey: sourceKey,
          folderId: 'remote',
        );
        final data = _numericData(
          (page, [folder]) async => Res(<Comic>[
            _comic('comic-$i', sourceKey: sourceKey),
          ], subData: 1),
          sourceKey: sourceKey,
        );
        await cache.refreshFolders(data);
        await cache.refreshPage(data, sourceFolder, 1);
        folders.add(sourceFolder);

        final source = _detailSource((id) async {
          active++;
          maxActive = active > maxActive ? active : maxActive;
          if (active == 8 && !eightStarted.isCompleted) {
            eightStarted.complete();
          }
          try {
            await gate.future;
            return _details(id);
          } finally {
            active--;
          }
        }, sourceKey: sourceKey);
        ComicSourceManager().add(source);
        addTearDown(() => ComicSourceManager().remove(sourceKey));
      }

      final scan = scanFollowUpdates(
        folders,
        FollowUpdateMode.force,
        ignoreRetryAfter: true,
        cache: cache,
      ).toList();
      await eightStarted.future.timeout(const Duration(seconds: 5));
      expect(active, 8);
      expect(maxActive, 8);
      gate.complete();

      await scan;
      expect(maxActive, 8);
      expect(cache.getCurrentScanRun()!.status, 'finished');
    });

    test(
      'round-robin lets another source start behind a blocked source',
      () async {
        final sourceAFolder = const NetworkFavoriteFolderRef(
          sourceKey: 'source-a',
          folderId: 'remote',
        );
        final sourceBFolder = const NetworkFavoriteFolderRef(
          sourceKey: 'source-b',
          folderId: 'remote',
        );
        final sourceAData = _numericData(
          (page, [folder]) async => Res([
            for (var i = 0; i < 8; i++) _comic('a-$i', sourceKey: 'source-a'),
          ], subData: 1),
          sourceKey: 'source-a',
        );
        final sourceBData = _numericData(
          (page, [folder]) async =>
              Res(<Comic>[_comic('b-1', sourceKey: 'source-b')], subData: 1),
          sourceKey: 'source-b',
        );
        await cache.refreshFolders(sourceAData);
        await cache.refreshPage(sourceAData, sourceAFolder, 1);
        await cache.refreshFolders(sourceBData);
        await cache.refreshPage(sourceBData, sourceBFolder, 1);

        final sourceAGate = Completer<void>();
        final bStarted = Completer<void>();
        var activeA = 0;
        var maxActiveA = 0;
        final sourceA = _detailSource((id) async {
          activeA++;
          maxActiveA = activeA > maxActiveA ? activeA : maxActiveA;
          try {
            await sourceAGate.future;
            return _details(id);
          } finally {
            activeA--;
          }
        }, sourceKey: 'source-a');
        final sourceB = _detailSource((id) async {
          if (!bStarted.isCompleted) bStarted.complete();
          return _details(id);
        }, sourceKey: 'source-b');
        ComicSourceManager().add(sourceA);
        ComicSourceManager().add(sourceB);
        addTearDown(() {
          ComicSourceManager().remove('source-a');
          ComicSourceManager().remove('source-b');
        });

        final scan = scanFollowUpdates(
          [sourceAFolder, sourceBFolder],
          FollowUpdateMode.force,
          ignoreRetryAfter: true,
          cache: cache,
        ).toList();
        await bStarted.future.timeout(const Duration(seconds: 5));
        expect(maxActiveA, lessThanOrEqualTo(5));
        sourceAGate.complete();

        await scan;
        expect(maxActiveA, lessThanOrEqualTo(5));
        expect(cache.getCurrentScanRun()!.status, 'finished');
      },
    );

    test(
      'canceling queued same-source work releases permits and closes scan',
      () async {
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
        final token = _TestScanToken();
        final gate = Completer<void>();
        final fiveStarted = Completer<void>();
        var calls = 0;
        var active = 0;
        final source = _detailSource((id) async {
          calls++;
          active++;
          if (active == 5 && !fiveStarted.isCompleted) {
            fiveStarted.complete();
          }
          try {
            await gate.future;
            return _details(id);
          } finally {
            active--;
          }
        });
        ComicSourceManager().add(source);

        final scan = scanFollowUpdates(
          [folder],
          FollowUpdateMode.force,
          ignoreRetryAfter: true,
          cancellationToken: token,
          cache: cache,
        ).toList();
        await fiveStarted.future.timeout(const Duration(seconds: 5));
        token.canceled = true;
        gate.complete();

        await scan.timeout(const Duration(seconds: 5));
        expect(calls, 5);
        expect(cache.getCurrentScanRun()!.status, 'canceled');
      },
    );

    test('source action failures do not poison later work', () async {
      await cacheComics(['bad', 'good']);
      var badCalls = 0;
      final source = _detailSource((id) async {
        if (id == 'bad') {
          badCalls++;
          throw Exception('Invalid Status Code: 500. server-side error');
        }
        return _details(id);
      });
      ComicSourceManager().add(source);

      await scanFollowUpdates(
        [folder],
        FollowUpdateMode.force,
        ignoreRetryAfter: true,
        cache: cache,
      ).toList();

      expect(badCalls, 3);
      expect(
        cache
            .getComicsWithUpdatesInfo(folder)
            .firstWhere((comic) => comic.id == 'good')
            .lastCheckTime,
        isNotNull,
      );
      expect(cache.getCurrentScanRun()!.status, 'finished');
    });

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

    test(
      'an interrupted scan is resumed by the next scan without re-requesting done items',
      () async {
        final gate = Completer<void>();
        final calls = <String>[];
        final sourceKeys = [
          'test-source-one',
          'test-source-two',
          'test-source-three',
          'test-source-four',
        ];
        final folders = <NetworkFavoriteFolderRef>[];
        for (final entry in [
          ('one', sourceKeys[0]),
          ('two', sourceKeys[1]),
          ('three', sourceKeys[2]),
          ('four', sourceKeys[3]),
        ]) {
          final id = entry.$1;
          final sourceKey = entry.$2;
          final sourceFolder = NetworkFavoriteFolderRef(
            sourceKey: sourceKey,
            folderId: 'remote',
          );
          final data = _numericData(
            (page, [folder]) async =>
                Res(<Comic>[_comic(id, sourceKey: sourceKey)], subData: 1),
            sourceKey: sourceKey,
          );
          await cache.refreshFolders(data);
          await cache.refreshPage(data, sourceFolder, 1);
          folders.add(sourceFolder);
          final source = _detailSource((requestedId) async {
            calls.add(requestedId);
            if (requestedId == 'one' &&
                calls.where((c) => c == 'one').length == 1) {
              await gate.future; // simulate a crash while 'one' is in flight
            }
            return _details(requestedId);
          }, sourceKey: sourceKey);
          ComicSourceManager().add(source);
          addTearDown(() => ComicSourceManager().remove(sourceKey));
        }

        // First scan: 'one' blocks, while the other sources complete in
        // parallel. Per-source bounded concurrency must not make a slow source
        // block unrelated sources.
        final firstScan = scanFollowUpdates(
          folders,
          FollowUpdateMode.missing,
          cache: cache,
        ).toList();
        await _waitUntil(
          () => calls.toSet().containsAll(['two', 'three', 'four']),
        );

        // Abandon the first scan (no cancel) and start a new one: it must
        // resume the interrupted run and only request the pending comic.
        final secondScan = scanFollowUpdates(
          folders,
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
          folders.every(
            (f) =>
                cache.getComicsWithUpdatesInfo(f).single.lastCheckTime != null,
          ),
          isTrue,
        );
        expect(cache.getCurrentScanRun()!.status, 'finished');
      },
    );

    test(
      'a run of transient errors still terminates with a finished run',
      () async {
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
        // Failed-but-cooled comics were attempted, so they must not surface as
        // an unchecked gap: the baseline UI would otherwise show "incomplete"
        // forever even though every comic was tried.
        expect(cache.countUncheckedComics(folder), 0);
        expect(cache.getCurrentScanRun()!.status, 'finished');
      },
    );

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
        all.every((c) => c.lastCheckTime != null || c.retryAfter != null),
        isTrue,
      );
    });

    test(
      'includeSuspect forces suspected comics back into the queue',
      () async {
        await cacheComics(['one', 'two']);
        cache.markComicSuspectGoneEverywhere('test-source', 'one');
        var calls = <String>[];
        final source = _detailSource((id) async {
          calls.add(id);
          return _details(id);
        });
        ComicSourceManager().add(source);

        // Normal scans skip suspects (only the never-checked 'two' is queued).
        await scanFollowUpdates(
          [folder],
          FollowUpdateMode.force,
          ignoreRetryAfter: true,
          cache: cache,
        ).toList();
        expect(calls, ['two']);

        // The debug force-scan ignores the suspect skip; a successful check
        // clears the mark again.
        await scanFollowUpdates(
          [folder],
          FollowUpdateMode.force,
          ignoreRetryAfter: true,
          includeSuspect: true,
          cache: cache,
        ).toList();
        expect(calls, containsAll(<String>['one', 'two']));
        expect(cache.isComicSuspectGone('test-source', 'one'), isFalse);
      },
    );

    test(
      'a source with no successful check never accumulates delist hits',
      () async {
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
      },
    );

    test(
      'a successful probe lets a single strong 404 enter suspect flow',
      () async {
        await cacheComics(['one']);
        var detailCalls = 0;
        var probeCalls = 0;
        final source = _detailSourceWithFavorite(
          (id) async {
            detailCalls++;
            throw Exception('Invalid Status Code: 404. Not found.');
          },
          loadFolders: ([String? _]) async {
            probeCalls++;
            return const Res(<String, String>{'remote': 'Remote'});
          },
        );
        ComicSourceManager().add(source);

        await scanFollowUpdates(
          [folder],
          FollowUpdateMode.force,
          ignoreRetryAfter: true,
          cache: cache,
        ).toList();

        // The first detail attempt is made before the source has health
        // evidence. The successful probe then authorizes the queued retry,
        // which confirms the strong 404 and marks the comic suspect.
        expect(probeCalls, 1);
        expect(detailCalls, 4);
        expect(cache.isComicSuspectGone('test-source', 'one'), isTrue);
      },
    );

    test(
      'an empty successful probe still proves the source is reachable',
      () async {
        await cacheComics(['one']);
        var probeCalls = 0;
        final source = _detailSourceWithFavorite(
          (id) async {
            throw Exception('Invalid Status Code: 404. Not found.');
          },
          loadFolders: ([String? _]) async {
            probeCalls++;
            return const Res(<String, String>{});
          },
        );
        ComicSourceManager().add(source);

        await scanFollowUpdates(
          [folder],
          FollowUpdateMode.force,
          ignoreRetryAfter: true,
          cache: cache,
        ).toList();

        expect(probeCalls, 1);
        expect(cache.isComicSuspectGone('test-source', 'one'), isTrue);
      },
    );

    test(
      'a service error gates delist marks for the rest of the run',
      () async {
        await cacheComics(['one', 'two', 'three']);
        final source = _detailSource((id) async {
          if (id == 'one') throw Exception('Connection Timeout');
          if (id == 'two') {
            throw Exception('Invalid Status Code: 404. Not found.');
          }
          return _details(id);
        });
        ComicSourceManager().add(source);

        await scanFollowUpdates(
          [folder],
          FollowUpdateMode.force,
          ignoreRetryAfter: true,
          cache: cache,
        ).toList();

        // 'two' 404 arrived after a service-class error on the same source:
        // the delist gate rejects it (either order of 'two'/'three' keeps the
        // source unhealthy for marking).
        expect(cache.isComicSuspectGone('test-source', 'two'), isFalse);
        final two = cache
            .getComicsWithUpdatesInfo(folder)
            .firstWhere((c) => c.id == 'two');
        expect(two.retryAfter, isNotNull);
      },
    );

    test(
      'service errors accumulate across runs and roll back earlier marks',
      () async {
        // Batch 1: two successes then a delist-looking 404 -> marked.
        await cacheComics(['one', 'two', 'three']);
        final mixed = _detailSource((id) async {
          if (id == 'three') {
            throw Exception('Invalid Status Code: 404. Not found.');
          }
          return _details(id);
        });
        ComicSourceManager().add(mixed);
        await scanFollowUpdates(
          [folder],
          FollowUpdateMode.missing,
          cache: cache,
        ).toList();
        expect(cache.isComicSuspectGone('test-source', 'three'), isTrue);
        ComicSourceManager().remove('test-source');

        // Batch 2+3: fresh comics all fail with 500s. The counts carry over
        // across runs (3 + 3 >= 5), tripping the detector.
        final down = _detailSource((id) async {
          throw Exception('Invalid Status Code: 500. server-side error');
        });
        ComicSourceManager().add(down);
        for (final ids in [
          ['four', 'five', 'six'],
          ['seven', 'eight', 'nine'],
        ]) {
          await cache.refreshPage(
            _numericData(
              (page, [folder]) async =>
                  Res([for (final id in ids) _comic(id)], subData: 1),
            ),
            folder,
            1,
          );
          await scanFollowUpdates(
            [folder],
            FollowUpdateMode.missing,
            cache: cache,
          ).toList();
        }

        // The source tripped: the batch-1 mark is rolled back too.
        expect(cache.isComicSuspectGone('test-source', 'three'), isFalse);
      },
    );

    test('a dead probe on first hit trips the detector immediately', () async {
      await cacheComics(['one', 'two', 'three']);
      final source = _detailSourceWithFavorite((id) async {
        if (id == 'one' || id == 'two') return _details(id);
        throw Exception('Invalid Status Code: 404. Not found.');
      }, loadFolders: ([String? _]) async => throw Exception('site down'));
      ComicSourceManager().add(source);

      await scanFollowUpdates(
        [folder],
        FollowUpdateMode.force,
        ignoreRetryAfter: true,
        cache: cache,
      ).toList();

      // 'three' 404 was served while the list endpoint was down: the mark it
      // briefly received is rolled back and nothing else is marked.
      expect(cache.isComicSuspectGone('test-source', 'three'), isFalse);
      expect(
        cache.getComicsWithUpdatesInfo(folder).every((c) => !c.isSuspectGone),
        isTrue,
      );
    });

    test('a full re-probe window catches a source that dies mid-run', () async {
      kProbeWindowSize = 2;
      addTearDown(() => kProbeWindowSize = 20);
      // A single worker keeps the window counting deterministic.
      appdata.settings['followUpdateThreads'] = 1;
      addTearDown(() => appdata.settings['followUpdateThreads'] = 8);
      await cacheComics(['one', 'two', 'three', 'four']);
      var probeCalls = 0;
      final source = _detailSourceWithFavorite(
        (id) async {
          if (id == 'one' || id == 'three') {
            throw Exception('Invalid Status Code: 404. Not found.');
          }
          return _details(id);
        },
        loadFolders: ([String? _]) async {
          probeCalls++;
          if (probeCalls == 2) throw Exception('site down');
          return const Res(<String, String>{'remote': 'Remote'});
        },
      );
      ComicSourceManager().add(source);

      await scanFollowUpdates(
        [folder],
        FollowUpdateMode.force,
        ignoreRetryAfter: true,
        cache: cache,
      ).toList();

      // First probe (on 'one') said alive; the window then filled ('three'
      // hit, window size 2) and the re-probe found the site down: both marks
      // are rolled back.
      expect(probeCalls, 2);
      expect(cache.isComicSuspectGone('test-source', 'one'), isFalse);
      expect(cache.isComicSuspectGone('test-source', 'three'), isFalse);
    });

    test(
      'a resumed run backfills comics cached after the original run',
      () async {
        await cacheComics(['one', 'two']);
        final run = cache.createScanRun(
          mode: 'force',
          ignoreRetryAfter: true,
          total: 2,
          items: [('test-source', 'one'), ('test-source', 'two')],
        );
        cache.markScanItemDone(run.runId, 'test-source', 'one', result: 'ok');
        // A comic cached after the run was persisted.
        await cache.refreshPage(
          _numericData(
            (page, [folder]) async => Res(<Comic>[_comic('three')], subData: 1),
          ),
          folder,
          1,
        );

        var calls = <String>[];
        final source = _detailSource((id) async {
          calls.add(id);
          return _details(id);
        });
        ComicSourceManager().add(source);

        await scanFollowUpdates(
          [folder],
          FollowUpdateMode.force,
          ignoreRetryAfter: true,
          cache: cache,
        ).toList();

        // The interrupted run is resumed (same id), the new comic joins its
        // queue, the done item is not re-requested.
        expect(cache.getCurrentScanRun()!.runId, run.runId);
        expect(
          cache.getScanRunKeys(run.runId),
          contains('test-source\u0000three'),
        );
        expect(calls, contains('three'));
        expect(calls, isNot(contains('one')));
      },
    );
  });

  group('scan candidate SQL', () {
    test('getScanCandidates matches the full-scan manual filter', () async {
      const folderB = NetworkFavoriteFolderRef(
        sourceKey: 'test-source',
        folderId: 'remote-b',
        title: 'Remote B',
      );
      await cache.refreshFolders(
        _numericData(
          (page, [folder]) async => Res(<Comic>[_comic('one')], subData: 1),
        ),
      );
      await cache.refreshPage(
        _numericData(
          (page, [folder]) async => Res([
            for (final id in ['fresh', 'old', 'unchecked', 'cooled', 'suspect'])
              _comic(id),
          ], subData: 1),
        ),
        folder,
        1,
      );
      await cache.refreshPage(
        _numericData(
          (page, [folder]) async => Res([
            for (final id in ['old', 'unchecked-b', 'suspect-b']) _comic(id),
          ], subData: 1),
        ),
        folderB,
        1,
      );

      // Seed mixed check states directly in SQL: checked within the 24h
      // window, checked long ago, never checked (no row at all), cooling
      // down, and suspected-removed. 'old' lives in both folders.
      final db = sqlite3.open(
        '${tempDir.path}${Platform.pathSeparator}cache.db',
      );
      final now = DateTime.now();
      final seeds = <({String id, int? lastMs, int? retryMs, int suspect})>[
        (
          id: 'fresh',
          lastMs: now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
          retryMs: null,
          suspect: 0,
        ),
        (
          id: 'old',
          lastMs: now
              .subtract(const Duration(hours: 25))
              .millisecondsSinceEpoch,
          retryMs: null,
          suspect: 0,
        ),
        (
          id: 'cooled',
          lastMs: now
              .subtract(const Duration(hours: 25))
              .millisecondsSinceEpoch,
          retryMs: now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
          suspect: 0,
        ),
        (
          id: 'suspect',
          lastMs: now
              .subtract(const Duration(hours: 25))
              .millisecondsSinceEpoch,
          retryMs: null,
          suspect: 1,
        ),
        (id: 'suspect-b', lastMs: null, retryMs: null, suspect: 1),
      ];
      for (final s in seeds) {
        db.execute(
          '''INSERT INTO comic_check_state
             (source_key, comic_id, last_check_time, retry_after,
              check_suspect_gone)
             VALUES (?, ?, ?, ?, ?)''',
          ['test-source', s.id, s.lastMs, s.retryMs, s.suspect],
        );
      }
      db.dispose();

      // Reference implementation: every row plus the old Dart-side filters.
      Set<String> reference(
        FollowUpdateMode mode, {
        required bool ignoreRetryAfter,
        bool includeSuspect = false,
      }) {
        final out = <String>{};
        final refNow = DateTime.now();
        for (final f in [folder, folderB]) {
          for (final comic in cache.getComicsWithUpdatesInfo(f)) {
            if (comic.isSuspectGone && !includeSuspect) continue;
            final lct = comic.lastCheckTime;
            if (mode == FollowUpdateMode.missing) {
              if (lct != null) continue;
            } else if (mode == FollowUpdateMode.regular) {
              if (lct != null && refNow.difference(lct).inDays < 1) continue;
            }
            final ra = comic.retryAfter;
            if (!ignoreRetryAfter && ra != null && ra.isAfter(refNow)) {
              continue;
            }
            out.add('${comic.sourceKey}\u0000${comic.id}\u0000${f.folderId}');
          }
        }
        return out;
      }

      for (final mode in FollowUpdateMode.values) {
        for (final ignore in [false, true]) {
          final got = {
            for (final c in cache.getScanCandidates(
              [folder, folderB],
              modeName: mode.name,
              ignoreRetryAfter: ignore,
              includeSuspect: false,
            ))
              '${c.sourceKey}\u0000${c.comicId}\u0000${c.folderId}',
          };
          expect(
            got,
            reference(mode, ignoreRetryAfter: ignore),
            reason: '${mode.name} ignoreRetryAfter=$ignore',
          );
        }
      }
      // includeSuspect only re-adds the suspect rows.
      final all = cache.getScanCandidates(
        [folder, folderB],
        modeName: 'force',
        ignoreRetryAfter: true,
        includeSuspect: true,
      );
      expect(
        {for (final c in all) '${c.comicId}\u0000${c.folderId}'},
        reference(
          FollowUpdateMode.force,
          ignoreRetryAfter: true,
          includeSuspect: true,
        ).map((k) => k.split('\u0000').skip(1).join('\u0000')).toSet(),
      );
    });
  });

  test(
    'confirmed updates refresh the cover URL; unchanged comics keep it',
    () async {
      await cacheComics(['one']);
      var updateTime = '2026-08-01';
      var cover = 'https://example.invalid/old.jpg';
      final source = _detailSource((id) async {
        return Res(
          ComicDetails.fromJson({
            'title': 'Comic',
            'subtitle': 'Author',
            'cover': cover,
            'updateTime': updateTime,
            'tags': <String, List<String>>{},
            'chapters': <String, String>{'1': 'Chapter 1'},
            'sourceKey': 'test-source',
            'comicId': id,
          }),
        );
      });
      ComicSourceManager().add(source);
      addTearDown(() => ComicSourceManager().remove('test-source'));

      Future<void> checkOnce() => updateComic(
        cache.getComicsWithUpdatesInfo(folder).single,
        folder,
        cache: cache,
      );

      // Baseline: the first check establishes the marker, no "update" verdict
      // yet, so the cached cover stays untouched.
      await checkOnce();
      expect(
        cache.getCachedPage(folder, 1)!.comics.single.coverPath,
        'https://example.invalid/one.jpg',
      );

      // A confirmed update commits the new cover URL.
      cover = 'https://example.invalid/new.jpg';
      updateTime = '2026-08-02';
      await checkOnce();
      expect(
        cache.getCachedPage(folder, 1)!.comics.single.coverPath,
        'https://example.invalid/new.jpg',
      );

      // URL churn without an update (signed URLs, CDN rotation): the cached
      // cover wins so the image cache is not invalidated by every sweep.
      cover = 'https://example.invalid/signed.jpg';
      await checkOnce();
      expect(
        cache.getCachedPage(folder, 1)!.comics.single.coverPath,
        'https://example.invalid/new.jpg',
      );

      // An update with an empty cover keeps the existing URL.
      cover = '';
      updateTime = '2026-08-03';
      await checkOnce();
      expect(
        cache.getCachedPage(folder, 1)!.comics.single.coverPath,
        'https://example.invalid/new.jpg',
      );
    },
  );

  test('a canceled detail result cannot commit follow-up state', () async {
    await cacheComics(['late']);
    final gate = Completer<void>();
    final started = Completer<void>();
    final source = _detailSource((id) async {
      if (!started.isCompleted) started.complete();
      await gate.future;
      return _details(id);
    });
    ComicSourceManager().add(source);
    addTearDown(() => ComicSourceManager().remove('test-source'));

    final token = _TestScanToken();
    final future = updateComic(
      cache.getComicsWithUpdatesInfo(folder).single,
      folder,
      cache: cache,
      cancellationToken: token,
    );
    await started.future;
    token.canceled = true;
    gate.complete();

    final result = await future;
    expect(result.canceled, isTrue);
    final item = cache.getComicsWithUpdatesInfo(folder).single;
    expect(item.lastCheckTime, isNull);
    expect(item.updateMarker, isNull);
    expect(item.name, 'Comic late');
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
