import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/source_adapter.dart';

import 'scan_kernel/fakes.dart';

void main() {
  const a = NetworkFavoriteFolderRef(sourceKey: 'a', folderId: '');
  const b = NetworkFavoriteFolderRef(sourceKey: 'b', folderId: '');
  late NetworkFavoriteCacheManager cache;
  late Directory directory;
  late String path;

  Future<void> openDb() async {
    cache = NetworkFavoriteCacheManager.forTesting();
    await cache.init(databasePath: path, migrateLegacy: false);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('venera-collection-');
    path = '${directory.path}/favorites.db';
    await openDb();
  });

  tearDown(() async {
    cache.close();
    await directory.delete(recursive: true);
  });

  Future<FavoriteFullCacheProgress> publish(
    _Remote remote,
    NetworkFavoriteFolderRef folder,
  ) => cache.cacheAllPages(remote.data, folder, isCanceled: () => false).last;

  test('source badges persist independently of the favorite snapshot', () async {
    final remote = _Remote('a', ['one', 'two']);
    final source = makeScanTestSource(
      'a',
      favoriteData: remote.data,
      scan: ScanCapabilities.supported(
        primary: ScanProducer.collection,
        collection: ScanCapability.collection(
          (_, _, _) async => const {},
          evidenceSchema: '{"sourceunread":"is_new"}',
        ),
      ),
    );
    ComicSourceManager().add(source);
    addTearDown(() => ComicSourceManager().remove(source.key));
    expect((await publish(remote, a)).isComplete, isTrue);
    final completed = cache.getFullCacheStatus(a).completedAt;
    cache.takeFollowUpdateChangeBatch();

    remote.calls.clear();
    remote.sourceUnread = {'one': true};
    await cache.collections.open(remote.data, a).loadPage(1);
    expect(cache.collections.readSourceUnreadIds('a'), {'one'});
    expect(remote.calls, [1]);
    expect(cache.getFullCacheStatus(a).completedAt, completed);
    expect(cache.takeFollowUpdateChangeBatch().isEmpty, isTrue);

    remote.sourceUnread = {};
    cache.close();
    await openDb();
    await cache.collections.open(remote.data, a).loadPage(1);
    expect(cache.collections.readSourceUnreadIds('a'), {'one'});

    // Both visits fetch the same page. The older affirmative reply lands last.
    remote.sourceUnread = {'one': true};
    final late = remote.hold(1);
    final old = cache.collections
        .open(remote.data, a, restart: true)
        .loadPage(1);
    remote.sourceUnread = {'one': false};
    await cache.collections.open(remote.data, a, restart: true).loadPage(1);
    late.complete();
    expect((await old).success, isTrue);
    expect(cache.collections.readSourceUnreadIds('a'), isEmpty);

    remote.sourceUnread = {'one': true};
    await cache.collections.open(remote.data, a, restart: true).loadPage(1);
    final oldAccount = remote.hold(1);
    final inFlight = cache.collections
        .open(remote.data, a, restart: true)
        .loadPage(1);
    cache.invalidateFavoriteSessionForSource('a');
    oldAccount.complete();
    expect((await inFlight).error, isTrue);
    expect(cache.collections.readSourceUnreadIds('a'), isEmpty);
  });

  test(
    'publishes all pages once and an unchanged opening only loads page one',
    () async {
      final remote = _Remote('a', ['one', 'two']);
      expect((await publish(remote, a)).isComplete, isTrue);
      cache.takeFollowUpdateChangeBatch();
      remote.ids = ['two', 'one'];
      remote.calls.clear();
      final tail = remote.hold(2);
      final visit = cache.collections.open(remote.data, a);
      cache.collections.show(visit);
      expect((await visit.loadPage(1)).data.single.id, 'two');
      await _until(() => remote.calls.contains(2));
      expect(remote.calls, [1, 2]);
      expect(cache.getCachedPage(a, 1)!.comics.single.id, 'one');
      expect(cache.searchCachedComics(a, 'two').single.id, 'two');
      final generation = cache.cacheGeneration;
      tail.complete();
      await _until(() => cache.getCachedPage(a, 1)!.comics.single.id == 'two');
      expect(cache.getCachedPage(a, 1)!.comics.single.id, 'two');
      expect(cache.getCachedPage(a, 2)!.comics.single.id, 'one');
      expect(cache.cacheGeneration, generation);
      expect(cache.takeFollowUpdateChangeBatch().isEmpty, isTrue);
      expect((await visit.loadPage(2)).data.single.id, 'one');

      remote.calls.clear();
      final next = cache.collections.open(remote.data, a, restart: true);
      cache.collections.show(next);
      await next.loadPage(1);
      await Future<void>.delayed(const Duration(milliseconds: 420));
      expect((await next.loadPage(2)).data.single.id, 'one');
      expect(remote.calls, [1]);
      cache.collections.hide(next);
    },
  );

  test(
    'confirmed changes survive restart and a stale source cannot publish over them',
    () async {
      final remote = _Remote('a', ['old', 'other']);
      expect((await publish(remote, a)).isComplete, isTrue);
      final previous = cache.getFullCacheStatus(a).completedAt;
      cache.takeFollowUpdateChangeBatch();
      cache.collections.recordChange(a, 'new', true, remote.comic('new'));
      cache.collections.recordChange(a, 'old', false, null);
      expect(cache.takeFollowUpdateChangeBatch().isEmpty, isTrue);
      cache.close();
      await openDb();
      final visit = cache.collections.open(remote.data, a);
      expect(visit.recent.single.id, 'new');
      expect(visit.wasRemoved('old'), isTrue);
      expect(cache.isFavoriteKnown('a', 'new'), isTrue);
      expect(cache.getFavoriteComicIds('a'), {'old', 'other'});
      expect(
        (await publish(remote, a)).errorMessage,
        contains('recent favorite changes'),
      );
      expect(cache.getFullCacheStatus(a).completedAt, previous);

      remote.ids = ['other', 'new'];
      expect((await publish(remote, a)).isComplete, isTrue);
      expect(cache.getFavoriteComicIds('a'), {'other', 'new'});
      expect(
        cache.collections.open(remote.data, a, restart: true).recent.single.id,
        'new',
      );
      visit.markRecentShown();
      expect(
        cache.collections.open(remote.data, a, restart: true).recent,
        isEmpty,
      );
    },
  );

  test('quick switch resumes A, settled switch leaves A unpublished', () async {
    cache.collections.settleDelay = const Duration(minutes: 1);
    final first = _Remote('a', List.generate(6, (i) => 'a-$i'));
    final second = _Remote('b', ['b-one', 'b-two']);
    final aVisit = cache.collections.open(first.data, a);
    final bVisit = cache.collections.open(second.data, b);
    final secondPage = first.hold(2);
    final lastPage = first.hold(6);
    cache.collections.show(aVisit);
    await aVisit.loadPage(1);
    cache.collections.settleNow();
    await _until(() => first.calls.contains(5));
    expect(first.calls, [1, 2, 3, 4, 5]);
    cache.collections.show(bVisit);
    await bVisit.loadPage(1);
    secondPage.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(first.calls, [1, 2, 3, 4, 5]);
    cache.collections.show(aVisit);
    await _until(() => first.calls.contains(6));
    expect(first.calls, [1, 2, 3, 4, 5, 6]);
    expect(second.calls, [1]);

    cache.collections.show(bVisit);
    cache.collections.settleNow();
    await _until(() => cache.getFullCacheStatus(b).isComplete);
    lastPage.completeError(const SocketException('Connection lost'));
    await Future<void>.delayed(Duration.zero);
    expect(second.calls, [1, 2]);
    expect(cache.getFullCacheStatus(b).isComplete, isTrue);
    expect(cache.getFullCacheStatus(a).isComplete, isFalse);
    expect(cache.getCachedPage(a, 1), isNull);
    expect(aVisit.cacheFailed, isFalse);
    expect(aVisit.takeCacheWarning(), isFalse);
    cache.collections.hide(bVisit);
  });

  test('opening updates keeps the hidden favorites sync running', () async {
    cache.collections.settleDelay = const Duration(minutes: 1);
    final remote = _Remote('a', ['one', 'two']);
    final visit = cache.collections.open(remote.data, a);
    final tail = remote.hold(2);
    cache.collections.show(visit);
    await visit.loadPage(1);
    cache.collections.settleNow();
    await _until(() => remote.calls.contains(2));

    cache.collections.hide(visit);
    final progress = await cache.collections.continueForUpdates(
      remote.data,
      isCanceled: () => false,
    );
    expect(progress, isNotNull);
    cache.collections.settleNow();
    tail.complete();

    expect((await progress!.last).isComplete, isTrue);
    expect(remote.calls, [1, 2]);
    expect(cache.getFavoriteComicIds('a'), {'one', 'two'});
  });

  test(
    'opening updates can join the directory request for an empty source',
    () async {
      final response = Completer<Res<Map<String, String>>>();
      var requests = 0;
      final data = FavoriteData(
        key: 'a',
        title: 'Remote favorites',
        multiFolder: true,
        loadComic: null,
        loadNext: null,
        loadFolders: ([_]) {
          requests++;
          return response.future;
        },
      );

      final directoryRequest = cache.refreshFolders(data);
      final updatesRequest = cache.refreshFolders(data);
      expect(requests, 1);
      expect(cache.hasLoadedFavoriteDirectory('a'), isFalse);

      response.complete(const Res({}));
      expect((await directoryRequest).data, isEmpty);
      expect((await updatesRequest).data, isEmpty);
      expect(cache.hasLoadedFavoriteDirectory('a'), isTrue);
      cache.invalidateFavoriteSessionForSource('a');
      expect(cache.hasLoadedFavoriteDirectory('a'), isFalse);
    },
  );

  test(
    'an unread probe reuses the first page when favorites changed',
    () async {
      final remote = _Remote('a', ['one', 'two']);
      expect((await publish(remote, a)).isComplete, isTrue);
      final db = sqlite3.open(path);
      try {
        db.execute('UPDATE favorite_folders SET full_cache_at = 1');
      } finally {
        db.dispose();
      }
      remote.calls.clear();
      remote.ids = ['three', 'two'];
      final stages = <String>[];

      expect(
        await cache.collections.refreshUnreadIfNeeded(
          remote.data,
          a,
          onChecking: () => stages.add('checking'),
          onSyncing: () => stages.add('syncing'),
          isCanceled: () => false,
        ),
        isTrue,
      );
      expect(stages, ['checking', 'syncing']);
      expect(remote.calls, [1, 2]);
      expect(cache.getFavoriteComicIds('a'), {'two', 'three'});
    },
  );

  test(
    'numbered batches wait for the homepage and publish in page order',
    () async {
      final remote = _Remote('a', List.generate(7, (i) => 'comic-$i'));
      final home = remote.hold(1);
      final second = remote.hold(2);
      final fifth = remote.hold(5);
      final complete = publish(remote, a);
      await _until(() => remote.calls.isNotEmpty);
      expect(remote.calls, [1]);

      home.complete();
      await _until(() => remote.calls.contains(5));
      expect(remote.calls, [1, 2, 3, 4, 5]);
      fifth.complete();
      await Future<void>.delayed(Duration.zero);
      expect(remote.calls, [1, 2, 3, 4, 5]);
      expect(cache.getFavoriteComicIds('a'), isEmpty);

      second.complete();
      expect((await complete).isComplete, isTrue);
      expect(remote.calls, [1, 2, 3, 4, 5, 6, 7]);
      expect([
        for (var page = 1; page <= 7; page++)
          cache.getCachedPage(a, page)!.comics.single.id,
      ], remote.ids);
    },
  );

  test(
    'foreground and automatic caching share a page and explicit caching joins',
    () async {
      final remote = _Remote('a', ['one', 'two']);
      final visit = cache.collections.open(remote.data, a);
      final tail = remote.hold(2);
      cache.collections.show(visit);
      await visit.loadPage(1);
      final visible = visit.loadPage(2);
      await Future<void>.delayed(const Duration(milliseconds: 420));
      final complete = publish(remote, a);
      await Future<void>.delayed(Duration.zero);
      expect(remote.calls, [1, 2]);
      tail.complete();
      expect((await visible).data.single.id, 'two');
      expect((await complete).isComplete, isTrue);
      expect(remote.calls, [1, 2]);
      cache.collections.hide(visit);
    },
  );

  test('numbered pages can publish with no exact source total', () async {
    final remote = _Remote('a', ['one', 'two'], knownTotal: false);
    expect((await publish(remote, a)).isComplete, isTrue);
    expect(cache.getFullCacheStatus(a).comicCount, 2);
    expect(cache.getCachedPage(a, 2)!.comics.single.id, 'two');
  });

  test(
    'cursor pages publish together and a repeated cursor keeps the old cache',
    () async {
      String? loop;
      final requested = <String?>[];
      final remote = _Remote('a', []);
      final data = FavoriteData(
        key: 'a',
        title: 'A',
        multiFolder: true,
        loadComic: null,
        loadNext: (_, [folder]) async => throw StateError('Legacy request'),
        loadCacheNext: (next, folder) async {
          expect(folder, a.folderId);
          requested.add(next);
          return Res(
            FavoriteCachePage(
              [remote.comic(next == null ? 'first' : 'last')],
              null,
              null,
              next: next == null ? 'after-first' : loop,
            ),
          );
        },
      );
      final first = await cache
          .cacheAllPages(data, a, isCanceled: () => false)
          .last;
      expect(first.isComplete, isTrue);
      expect(first.totalPages, 2);
      expect(requested, [null, 'after-first']);
      expect(cache.getCachedNextPage(a, null)!.nextToken, 'after-first');
      expect(cache.searchCachedComics(a, 'last').single.id, 'last');
      final saved = cache.getFullCacheStatus(a).completedAt;
      loop = 'after-first';
      final bad = await cache
          .cacheAllPages(data, a, isCanceled: () => false)
          .last;
      expect(bad.isComplete, isFalse);
      expect(bad.errorMessage, contains('Invalid favorite cache page'));
      expect(cache.getFullCacheStatus(a).completedAt, saved);
    },
  );

  test(
    'an opted-in collection still notifies tracking immediately after an addition',
    () async {
      final remote = _Remote('a', ['old']);
      final source = makeScanTestSource(
        'a',
        favoriteData: remote.data,
        scan: ScanCapabilities.supported(
          primary: ScanProducer.collection,
          collection: ScanCapability.collection(
            (_, __, ___) async => const {},
            itemFailures: true,
          ),
        ),
      )..data['account'] = 'test';
      ComicSourceManager().add(source);
      addTearDown(() => ComicSourceManager().remove(source.key));
      expect((await publish(remote, a)).isComplete, isTrue);
      cache.takeFollowUpdateChangeBatch();

      final add = await cache.changeFavorite(
        data: remote.data,
        folder: a,
        comicId: 'new',
        isAdding: true,
        comic: remote.comic('new'),
      );
      expect(add.success, isTrue);
      expect(cache.takeFollowUpdateChangeBatch().remoteAdditionComicIds['a'], {
        'new',
      });
      expect(cache.getFavoriteComicIds('a'), {'old'});
      remote.ids.add('new');
      expect((await publish(remote, a)).isComplete, isTrue);
      expect(cache.getFavoriteComicIds('a'), {'old', 'new'});
      expect(
        cache.takeFollowUpdateChangeBatch().remoteAdditionComicIds,
        isEmpty,
      );
    },
  );

  test(
    'changing a source sort setting starts a new visit even if its first page looks the same',
    () async {
      final remote = _Remote(
        'a',
        ['first', 'middle', 'last'],
        cacheSettings: ['sort'],
      );
      final source = makeScanTestSource('a', favoriteData: remote.data)
        ..data['settings'] = {'sort': 'dd'};
      ComicSourceManager().add(source);
      addTearDown(() => ComicSourceManager().remove(source.key));
      expect((await publish(remote, a)).isComplete, isTrue);
      final original = cache.collections.open(remote.data, a);
      source.data['settings']['sort'] = 'da';
      remote.ids = ['first', 'last', 'middle'];
      final next = cache.collections.open(remote.data, a);
      expect(next.pageStorageKey, isNot(original.pageStorageKey));
      cache.collections.show(next);
      await next.loadPage(1);
      cache.collections.settleNow();
      await _until(() => cache.getCachedPage(a, 2)!.comics.single.id == 'last');
      cache.collections.hide(next);
    },
  );

  test(
    'moving a favorite marks the old category, the new category and All',
    () async {
      const all = NetworkFavoriteFolderRef(sourceKey: 'a', folderId: '-1');
      const old = NetworkFavoriteFolderRef(sourceKey: 'a', folderId: '0');
      const next = NetworkFavoriteFolderRef(sourceKey: 'a', folderId: '1');
      final remote = _Remote('a', ['gallery']);
      final data = FavoriteData(
        key: 'a',
        title: 'A',
        multiFolder: true,
        singleFolderForSingleComic: true,
        cacheAllFolder: '-1',
        loadComic: remote.data.loadComic,
        loadNext: null,
        loadCachePage: remote.data.loadCachePage,
      );
      expect(
        (await cache.cacheAllPages(data, old, isCanceled: () => false).last)
            .isComplete,
        isTrue,
      );
      cache.takeFollowUpdateChangeBatch();
      cache.collections.recordFavoriteMutation(
        data,
        next,
        'gallery',
        true,
        remote.comic('gallery'),
      );
      expect(cache.collections.open(data, old).wasRemoved('gallery'), isTrue);
      expect(cache.collections.open(data, next).recent.single.id, 'gallery');
      expect(cache.collections.open(data, all).recent.single.id, 'gallery');
      expect(cache.getCachedPage(old, 1)!.comics.single.id, 'gallery');
      expect(cache.takeFollowUpdateChangeBatch().isEmpty, isTrue);
    },
  );
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(
    ready(),
    isTrue,
    reason: 'The asynchronous cache operation did not complete',
  );
}

class _Remote {
  _Remote(
    this.source,
    this.ids, {
    this.knownTotal = true,
    this.cacheSettings = const [],
  });

  final String source;
  List<String> ids;
  final bool knownTotal;
  final List<String> cacheSettings;
  final calls = <int>[];
  Map<String, bool> sourceUnread = {};
  final _holds = <int, Completer<void>>{};

  late final data = FavoriteData(
    key: source,
    title: source,
    multiFolder: false,
    loadComic: (_, [folder]) async =>
        throw StateError('Unexpected legacy load'),
    loadNext: null,
    cacheSettings: cacheSettings,
    addOrDelFavorite: (_, __, ___, ____) async => const Res(true),
    loadCachePage: (page, _, total) async {
      calls.add(page);
      final unread = sourceUnread;
      if (_holds.remove(page) case final hold?) await hold.future;
      expect(total, page == 1 || !knownTotal ? isNull : ids.length);
      return Res(
        FavoriteCachePage(
          page <= ids.length ? [comic(ids[page - 1])] : [],
          ids.length,
          knownTotal ? ids.length : null,
          sourceUnread: unread,
        ),
      );
    },
  );

  Comic comic(String id) => Comic(
    id,
    'https://example.invalid/$id.png',
    id,
    null,
    const [],
    '',
    source,
    null,
    null,
  );
  Completer<void> hold(int page) => _holds[page] = Completer<void>();
}
