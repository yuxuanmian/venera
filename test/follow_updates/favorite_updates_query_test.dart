import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorite_updates_query.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates_query.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/source_adapter.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_event.dart';
import 'package:venera/foundation/tracking/judgment_repository.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';

import '../scan_kernel/fakes.dart';
import '../tracking/fakes.dart';

void main() {
  const key = 'src';
  const first = NetworkFavoriteFolderRef(sourceKey: key, folderId: 'first');
  const second = NetworkFavoriteFolderRef(sourceKey: key, folderId: 'second');
  const all = NetworkFavoriteFolderRef(sourceKey: key, folderId: 'all');
  const single = NetworkFavoriteFolderRef(sourceKey: key, folderId: '');
  final manager = ComicSourceManager();
  final cache = NetworkFavoriteCacheManager();
  late Directory directory;
  late String favoritePath;
  late _PausableJudgmentRepository tracking;
  late FavoriteUpdatesQuery query;
  late Object? previousEnabledSources;
  late Object? previousFavoriteSources;
  late Map<String, List<Comic>> remote;
  late Map<String, bool> sourceUnread;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('venera-favorite-new-');
    favoritePath = '${directory.path}/favorites.db';
    await cache.init(databasePath: favoritePath, migrateLegacy: false);
    tracking = _PausableJudgmentRepository('${directory.path}/tracking.db');
    query = FavoriteUpdatesQuery(
      favoriteDatabasePath: () => favoritePath,
      trackingRepository: tracking,
    );
    previousEnabledSources = appdata.settings['enabledSources'];
    previousFavoriteSources = appdata.settings['favorites'];
    appdata.settings['enabledSources'] = [key, 'other'];
    appdata.settings['favorites'] = [key, 'other'];
    remote = {};
    sourceUnread = {};
  });

  tearDown(() async {
    manager.remove(key);
    manager.remove('other');
    appdata.settings['enabledSources'] = previousEnabledSources;
    appdata.settings['favorites'] = previousFavoriteSources;
    await tracking.close();
    cache.close();
    await directory.delete(recursive: true);
  });

  FavoriteData install({
    String sourceKey = key,
    bool multiFolder = false,
    String? aggregate,
    bool usesSourceUnread = false,
    bool requiresAccount = false,
  }) {
    final data = FavoriteData(
      key: sourceKey,
      title: sourceKey,
      multiFolder: multiFolder,
      cacheAllFolder: aggregate,
      loadComic: null,
      loadNext: null,
      loadFolders: ([comicId]) async =>
          Res({for (final folderId in remote.keys) folderId: folderId}),
      loadCachePage: (page, folder, _) async {
        final comics = remote[folder] ?? const [];
        return Res(
          FavoriteCachePage(
            comics.skip(page - 1).take(1).toList(),
            comics.length,
            comics.length,
            sourceUnread: sourceUnread,
          ),
        );
      },
    );
    manager.add(
      makeScanTestSource(
        sourceKey,
        favoriteData: data,
        account: requiresAccount
            ? AccountConfig(null, null, null, () {}, null, null, null, null)
            : null,
        scan: usesSourceUnread
            ? ScanCapabilities.supported(
                primary: ScanProducer.collection,
                collection: ScanCapability.collection(
                  (_, _, _) async => const {},
                  evidenceSchema: '{"sourceunread":"is_new"}',
                ),
              )
            : ScanCapabilities.supported(
                primary: ScanProducer.comic,
                comic: ScanCapability.comic(
                  (_, _) async => null,
                  evidenceSchema: '{"latestchapterid":"last_chapter.id"}',
                ),
              ),
      ),
    );
    return data;
  }

  Comic comic(
    String id,
    String title, {
    String? author,
    List<String> tags = const [],
    String sourceKey = key,
  }) => Comic(title, '', id, author, tags, '', sourceKey, null, null);

  Future<void> publish(
    FavoriteData data,
    NetworkFavoriteFolderRef folder,
  ) async {
    final progress = await cache
        .cacheAllPages(data, folder, isCanceled: () => false)
        .last;
    expect(progress.isComplete, isTrue, reason: progress.errorMessage);
  }

  Future<void> markLocalUnread(
    Iterable<String> ids, {
    String sourceKey = key,
  }) => tracking.applyBatch([
    for (final id in ids)
      JudgmentState(
        sourceKey: sourceKey,
        comicId: id,
        lastDecision: JudgmentConclusion.changed,
        lastReason: JudgmentReason.different,
        decidedAtMs: 0,
        hasNewUpdate: true,
      ),
  ]);

  test(
    'queries the complete folder union before search and pagination',
    () async {
      final data = install(multiFolder: true);
      expect(favoriteUpdatesSupported(data), isTrue);
      expect(favoriteUpdateFolders(data), isEmpty);
      expect(favoriteUpdatesCacheReady(data), isFalse);
      expect(await query.count(data), isNull);

      final numbers = List.generate(
        12,
        (i) => comic('comic_$i', 'Volume ${i.toString().padLeft(2, '0')}'),
      );
      final deep = comic(
        'deep',
        'Z Last Volume',
        author: 'Deep Author',
        tags: ['Special 100%'],
      );
      remote['first'] = [comic('tie-b', 'A Tie'), ...numbers];
      remote['second'] = [numbers.last, deep, comic('tie-a', 'A Tie')];
      cache.cacheFolderSnapshot(key, {'first': 'First', 'second': 'Second'});
      expect(favoriteUpdateFolders(data), [first, second]);
      await publish(data, first);
      expect(await query.queryPage(data), isNull);
      await publish(data, second);
      expect(favoriteUpdatesCacheReady(data), isTrue);

      // Simulate both sides of a cache mismatch: an item without membership
      // and a membership for which there is no displayable item.
      final db = sqlite3.open(favoritePath);
      try {
        db.execute('''
        DELETE FROM favorite_membership
        WHERE source_key = 'src' AND folder_id = 'first' AND comic_id = 'comic_0'
      ''');
        db.execute(
          "INSERT INTO favorite_membership VALUES ('src', 'first', 'missing')",
        );
      } finally {
        db.dispose();
      }
      await markLocalUnread([
        ...numbers.map((comic) => comic.id),
        'tie-a',
        'tie-b',
        'deep',
        'missing',
      ]);

      final other = install(sourceKey: 'other');
      remote[''] = [comic('tie-a', 'A Other', sourceKey: 'other')];
      await publish(
        other,
        const NetworkFavoriteFolderRef(sourceKey: 'other', folderId: ''),
      );
      await markLocalUnread(['tie-a'], sourceKey: 'other');
      final page = (await query.queryPage(data, pageSize: 2))!;
      expect(page.items.map((entry) => entry.comicId), ['tie-a', 'tie-b']);
      expect(page.items.every((entry) => entry.sourceKey == key), isTrue);
      expect(page.totalCount, 14);
      expect(await query.count(data), page.totalCount);
      final next = (await query.queryPage(
        data,
        pageSize: 2,
        after: page.nextCursor,
      ))!;
      expect(next.items.map((entry) => entry.comicId), ['comic_1', 'comic_2']);
      await expectLater(
        query.queryPage(other, pageSize: 2, after: page.nextCursor),
        throwsA(isA<FollowUpdatesCursorExpiredException>()),
      );
      final search = (await query.queryPage(
        data,
        keyword: 'VOLUME author SPECIAL 100%',
        pageSize: 2,
      ))!;
      expect(search.items.single.comicId, 'deep');
      expect(search.totalCount, 1);
      expect(search.hasMore, isFalse);
      expect(await query.count(data), 14);
    },
  );

  test(
    'declared All folder and confirmed source unread are authoritative',
    () async {
      final data = install(
        multiFolder: true,
        aggregate: 'all',
        usesSourceUnread: true,
      );
      expect(favoriteUpdateFolders(data), [all]);
      cache.cacheFolderSnapshot(key, {'first': 'First', 'second': 'Second'});
      remote['first'] = [comic('outside', 'Outside All')];
      remote['all'] = [
        comic('read', 'Confirmed Read'),
        comic('new', 'Confirmed Unread'),
        comic('unknown', 'No Source State'),
      ];
      sourceUnread = {'outside': true, 'read': false, 'new': true};
      await publish(data, first);
      expect(await query.count(data), isNull);
      await publish(data, all);
      await markLocalUnread(['read', 'unknown', 'outside']);
      expect(favoriteUpdatesCacheReady(data), isTrue);
      expect(await query.count(data), 1);
      expect((await query.queryPage(data))!.items.single.comicId, 'new');

      sourceUnread = {};
      await publish(data, all);
      expect(await query.count(data), 1);
      sourceUnread = {'new': false};
      await publish(data, all);
      expect(await query.count(data), 0);
      expect((await query.queryPage(data))!.items, isEmpty);
    },
  );

  test(
    'a replacement account invalidates pending reads and old cursors',
    () async {
      final data = install(requiresAccount: true);
      final source = manager.find(key)!;
      expect(favoriteUpdatesSupported(data), isFalse);
      source.data['account'] = {'name': 'old'};
      expect(favoriteUpdateFolders(data), [single]);
      remote[''] = [comic('a', 'A'), comic('b', 'B')];
      await publish(data, single);
      await markLocalUnread(['a', 'b']);
      final before = (await query.queryPage(data, pageSize: 1))!;

      final resume = Completer<void>();
      tracking.gate = resume.future;
      final stalePage = query.queryPage(data);
      final staleCount = query.count(data);
      source.data['account'] = {'name': 'new'};
      cache.invalidateFavoriteSessionForSource(key);
      expect(favoriteUpdatesCacheReady(data), isFalse);
      await publish(data, single);
      resume.complete();
      expect(await stalePage, isNull);
      expect(await staleCount, isNull);
      await expectLater(
        query.queryPage(data, pageSize: 1, after: before.nextCursor),
        throwsA(isA<FollowUpdatesCursorExpiredException>()),
      );
    },
  );

  test('disabled and replaced sources cannot finish a pending query', () async {
    final data = install();
    await publish(data, single);
    final resume = Completer<void>();
    tracking.gate = resume.future;
    final staleCount = query.count(data);
    appdata.settings['enabledSources'] = <String>[];
    expect(favoriteUpdatesSupported(data), isFalse);
    resume.complete();
    expect(await staleCount, isNull);

    appdata.settings['enabledSources'] = [key];
    final stalePage = query.queryPage(data);
    manager.remove(key);
    final replacement = install();
    expect(favoriteUpdatesSupported(data), isFalse);
    expect(favoriteUpdatesSupported(replacement), isTrue);
    expect(await stalePage, isNull);
  });

  test(
    'removing a source from Favorites invalidates pending queries',
    () async {
      final data = install();
      await publish(data, single);
      final resume = Completer<void>();
      tracking.gate = resume.future;
      final staleCount = query.count(data);
      appdata.settings['favorites'] = <String>[];
      expect(favoriteUpdatesSupported(data), isFalse);
      expect(favoriteUpdatesCacheReady(data), isFalse);
      resume.complete();
      expect(await staleCount, isNull);
      expect(await query.queryPage(data), isNull);
    },
  );

  test('blocked comics are excluded from both counts and pages', () async {
    final before = appdata.settings['blockedWords'];
    addTearDown(() => appdata.settings['blockedWords'] = before);
    appdata.settings['blockedWords'] = ['restricted'];
    final data = install();
    remote[''] = [
      comic('one', 'Visible title'),
      comic('two', 'Blocked title', tags: ['genre:restricted']),
    ];
    await publish(data, single);
    await markLocalUnread(['one', 'two']);

    expect(await query.count(data), 1);
    final page = await query.queryPage(data);
    expect(page!.items.map((entry) => entry.comic.id), ['one']);
  });

  test('only a confirmed empty directory answers with zero', () async {
    final data = install(multiFolder: true);
    expect(favoriteUpdateFolders(data), isEmpty);
    expect(await query.count(data), isNull);
    expect((await cache.refreshFolders(data)).data, isEmpty);
    expect(favoriteUpdateFolders(data), isEmpty);
    expect(favoriteUpdatesCacheReady(data), isTrue);
    expect(await query.count(data), 0);
    expect((await query.queryPage(data))!.items, isEmpty);

    cache.invalidateFavoriteSessionForSource(key);
    expect(favoriteUpdatesCacheReady(data), isFalse);
    expect(await query.count(data), isNull);
  });

  test('a failed read is distinct from an unready or empty cache', () async {
    final data = install();
    expect(await query.count(data), isNull);
    await publish(data, single);
    expect(await query.count(data), 0);
    final badPath = FavoriteUpdatesQuery(
      favoriteDatabasePath: () => '${directory.path}/missing.db',
      trackingRepository: tracking,
    );
    await expectLater(
      badPath.count(data),
      throwsA(isA<FollowUpdatesQueryException>()),
    );
  });

  test(
    'judgment and reader clears invalidate after commit without new scheduling events',
    () async {
      final data = install();
      remote[''] = [
        comic('comic', 'Tracked Comic'),
        comic('another', 'Another'),
      ];
      await publish(data, single);
      final scans = InMemoryScanItemStore();
      final service = JudgmentService(
        repository: tracking,
        scanRepository: scans,
      );
      final reads = <Future<int?>>[];
      service.unreadRevision.addListener(() => reads.add(query.count(data)));
      final batches = <JudgmentBatchEvent>[];
      final subscription = service.events.listen(batches.add);
      addTearDown(subscription.cancel);

      scans.replace(
        const ObservationSpec(
          latestChapterId: 'a',
        ).toStoredItem(sourceKey: key, comicId: 'comic', attemptId: 'baseline'),
      );
      await service.run();
      expect(await reads.last, 0);
      scans.replace(
        const ObservationSpec(
          latestChapterId: 'b',
        ).toStoredItem(sourceKey: key, comicId: 'comic', attemptId: 'changed'),
      );
      await service.run();
      expect(await reads.last, 1);
      expect(batches, hasLength(2));

      final before = service.unreadRevision.value;
      expect(await service.clearVisibleFlag(key, 'comic'), 1);
      expect(service.unreadRevision.value, before + 1);
      expect(await reads.last, 0);
      expect(await service.clearVisibleFlag(key, 'comic'), 0);
      expect(service.unreadRevision.value, before + 1);
      expect(batches, hasLength(2));

      await markLocalUnread(['comic', 'another']);
      final page = (await query.queryPage(data, pageSize: 1))!;
      expect(await service.clearUnreadForSource(key), 2);
      expect(await reads.last, 0);
      await expectLater(
        query.queryPage(data, pageSize: 1, after: page.nextCursor),
        throwsA(isA<FollowUpdatesCursorExpiredException>()),
      );
      await markLocalUnread(['comic']);
      await service.clear();
      expect(await reads.last, 0);
      expect(batches, hasLength(2));
    },
  );

  test('a failed judgment batch does not invalidate unread queries', () async {
    final repository = InMemoryJudgmentRepository()
      ..failNextBatch = StateError('failed write');
    final scans = InMemoryScanItemStore()
      ..replace(
        const ObservationSpec(
          latestChapterId: 'a',
        ).toStoredItem(sourceKey: key, comicId: 'comic'),
      );
    final service = JudgmentService(
      repository: repository,
      scanRepository: scans,
    );
    await expectLater(service.run(), throwsA(isA<JudgmentStorageException>()));
    expect(service.unreadRevision.value, 0);
  });
}

class _PausableJudgmentRepository extends SqliteJudgmentRepository {
  _PausableJudgmentRepository(String path) : super(databasePath: path);

  Future<void>? gate;

  @override
  Future<void> ensureOpen() async {
    if (gate case final pending?) await pending;
    await super.ensureOpen();
  }
}
