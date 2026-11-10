import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/favorite_search.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates_query.dart';
import 'package:venera/foundation/schedule/sqlite_schedule_repository.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';

void main() {
  late Directory tempDir;
  late String favoritePath;
  late String trackingPath;
  late String schedulePath;
  late FollowUpdatesQueryService queryService;
  late SqliteJudgmentRepository queryTrackingRepository;
  late SqliteScheduleRepository queryScheduleRepository;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('venera-follow-query-');
    favoritePath = '${tempDir.path}${Platform.pathSeparator}favorites.db';
    trackingPath = '${tempDir.path}${Platform.pathSeparator}tracking.db';
    schedulePath = '${tempDir.path}${Platform.pathSeparator}schedule.db';

    final cache = NetworkFavoriteCacheManager.forTesting();
    await cache.init(databasePath: favoritePath, migrateLegacy: false);
    cache.close();

    final favorites = sqlite3.open(favoritePath);
    _insertComic(
      favorites,
      sourceKey: 'src',
      comicId: 'dup',
      folderId: 'f1',
      pageIndex: 0,
      displayOrder: 0,
      title: 'Duplicate',
      tags: const ['needle'],
    );
    _insertComic(
      favorites,
      sourceKey: 'src',
      comicId: 'dup',
      folderId: 'f2',
      pageIndex: 0,
      displayOrder: 1,
      title: 'Duplicate',
      tags: const ['needle'],
    );
    for (final id in ['tie-a', 'tie-b']) {
      _insertComic(
        favorites,
        sourceKey: 'src',
        comicId: id,
        folderId: 'f1',
        pageIndex: 0,
        displayOrder: id == 'tie-a' ? 2 : 1,
        title: 'Tie',
        tags: const ['needle'],
      );
    }
    _insertComic(
      favorites,
      sourceKey: 'src',
      comicId: 'unloaded',
      folderId: 'f1',
      pageIndex: 0,
      displayOrder: 3,
      title: 'Not on the first page',
      tags: const ['needle', 'deep-match'],
    );
    _insertComic(
      favorites,
      sourceKey: 'src',
      comicId: 'expired',
      folderId: 'f1',
      pageIndex: 0,
      displayOrder: 4,
      title: 'Expired boundary',
      tags: const ['needle'],
    );
    _insertComic(
      favorites,
      sourceKey: 'src',
      comicId: 'manual-only',
      folderId: 'f1',
      pageIndex: 0,
      displayOrder: 5,
      title: 'Manual only',
      tags: const ['needle'],
    );
    _insertComic(
      favorites,
      sourceKey: 'other',
      comicId: 'disallowed',
      folderId: 'f1',
      pageIndex: 0,
      displayOrder: 0,
      title: 'Disallowed source',
      tags: const ['needle'],
    );
    favorites.execute('''
      INSERT INTO favorite_items (
        source_key, folder_id, page_index, comic_id, display_order, comic_json,
        favorite_id, favorite_time, search_text, has_new_update
      ) VALUES (
        'src', 'f1', 0, 'unrelated-corrupt-json', 99, '{broken',
        NULL, '2026-11-10 12:00:00', 'needle', 0
      )
      ''');
    favorites.dispose();

    const now = 1789041600000;
    final tracking = sqlite3.open(trackingPath);
    tracking.execute('''
      CREATE TABLE judgment_state (
        source_key TEXT NOT NULL,
        comic_id TEXT NOT NULL,
        has_new_update INTEGER NOT NULL,
        PRIMARY KEY (source_key, comic_id)
      )
    ''');
    for (final identity in const [
      ('src', 'dup'),
      ('src', 'unloaded'),
      ('src', 'expired'),
      ('other', 'disallowed'),
      ('src', 'missing-from-cache'),
    ]) {
      tracking.execute('INSERT INTO judgment_state VALUES (?, ?, 1)', [
        identity.$1,
        identity.$2,
      ]);
    }
    tracking.dispose();

    final schedule = sqlite3.open(schedulePath);
    schedule.execute('''
      CREATE TABLE schedule_state (
        source_key TEXT NOT NULL,
        comic_id TEXT NOT NULL,
        auto_hot_until INTEGER,
        manual_hot_enabled INTEGER NOT NULL DEFAULT 0,
        manual_hot_until INTEGER,
        PRIMARY KEY (source_key, comic_id)
      )
    ''');
    for (final row in [
      ('src', 'dup', now + 30000),
      ('src', 'tie-b', now + 20000),
      ('src', 'tie-a', now + 20000),
      ('src', 'unloaded', now + 10000),
      ('src', 'expired', now),
      ('other', 'disallowed', now + 60000),
    ]) {
      schedule.execute(
        'INSERT INTO schedule_state (source_key, comic_id, auto_hot_until) VALUES (?, ?, ?)',
        [row.$1, row.$2, row.$3],
      );
    }
    schedule.execute(
      '''
      INSERT INTO schedule_state (
        source_key, comic_id, auto_hot_until, manual_hot_enabled,
        manual_hot_until
      ) VALUES ('src', 'manual-only', NULL, 1, ?)
      ''',
      [now + 50000],
    );
    schedule.dispose();

    queryTrackingRepository = SqliteJudgmentRepository(
      databasePath: trackingPath,
    );
    queryScheduleRepository = SqliteScheduleRepository(
      databasePath: schedulePath,
    );
    queryService = FollowUpdatesQueryService(
      favoriteDatabasePath: () => favoritePath,
      trackingDatabasePath: () => trackingPath,
      scheduleDatabasePath: () => schedulePath,
      trackingRepository: queryTrackingRepository,
      scheduleRepository: queryScheduleRepository,
    );
  });

  tearDown(() async {
    await queryTrackingRepository.close();
    await queryScheduleRepository.close();
    try {
      tempDir.deleteSync(recursive: true);
    } on PathAccessException {
      // Windows may release native SQLite handles just after dispose.
    } on PathNotFoundException {
      // Already gone.
    }
  });

  test('cold start creates missing tracking and schedule stores', () async {
    File(trackingPath).deleteSync();
    File(schedulePath).deleteSync();

    expect(
      await queryService.readVisibleUnreadIdentities(
        allowedSourceKeys: const ['src'],
      ),
      isEmpty,
    );
    expect(
      await queryService.queryPage(
        allowedSourceKeys: const ['src'],
        now: DateTime.fromMillisecondsSinceEpoch(1789041600000, isUtc: true),
        tab: FollowUpdatesTab.recent,
        pageSize: 2,
      ),
      isA<FollowUpdatesPageResult>().having(
        (result) => result.totalCount,
        'totalCount',
        0,
      ),
    );
    expect(File(trackingPath).existsSync(), isTrue);
    expect(File(schedulePath).existsSync(), isTrue);
  });

  test('recent paging searches all candidates, deduplicates, excludes strict '
      'boundaries, and invalidates a stale cursor', () async {
    final now = DateTime.fromMillisecondsSinceEpoch(1789041600000, isUtc: true);
    final unread = await queryService.readVisibleUnreadIdentities(
      allowedSourceKeys: const ['src'],
    );
    expect(unread, {
      const FollowUpdatesIdentity('src', 'dup'),
      const FollowUpdatesIdentity('src', 'unloaded'),
      const FollowUpdatesIdentity('src', 'expired'),
    });

    final firstPage = await queryService.queryPage(
      allowedSourceKeys: const ['src'],
      now: now,
      tab: FollowUpdatesTab.recent,
      query: 'needle',
      pageSize: 2,
    );
    expect(firstPage.totalCount, 4);
    expect(
      firstPage.items.map((item) => item.comicId),
      ['dup', 'tie-a'],
      reason:
          'the duplicate favorite appears once; equal hot deadlines use '
          'the stable comic-id tiebreaker',
    );
    expect(firstPage.items.first.comic.title, 'Duplicate');
    expect(firstPage.nextCursor, isNotNull);

    final secondPage = await queryService.queryPage(
      allowedSourceKeys: const ['src'],
      now: now,
      tab: FollowUpdatesTab.recent,
      query: 'needle',
      pageSize: 2,
      cursor: firstPage.nextCursor,
    );
    expect(
      secondPage.items.map((item) => item.comicId),
      ['tie-b', 'unloaded'],
      reason:
          'the second page finds a matching item that was never decoded '
          'or displayed on the first page',
    );
    expect(secondPage.hasMore, isFalse);

    final schedule = sqlite3.open(schedulePath);
    schedule.execute(
      '''
        UPDATE schedule_state SET auto_hot_until = ?
        WHERE source_key = 'src' AND comic_id = 'tie-b'
        ''',
      [now.millisecondsSinceEpoch + 40000],
    );
    schedule.dispose();

    await expectLater(
      queryService.queryPage(
        allowedSourceKeys: const ['src'],
        now: now,
        tab: FollowUpdatesTab.recent,
        query: 'needle',
        pageSize: 2,
        cursor: firstPage.nextCursor,
      ),
      throwsA(isA<FollowUpdatesCursorExpiredException>()),
      reason: 'a committed refresh invalidates the old continuation token',
    );
  });
}

void _insertComic(
  Database database, {
  required String sourceKey,
  required String comicId,
  required String folderId,
  required int pageIndex,
  required int displayOrder,
  required String title,
  required List<String> tags,
}) {
  final json = <String, dynamic>{
    'id': comicId,
    'sourceKey': sourceKey,
    'title': title,
    'cover': 'https://example.invalid/$comicId.jpg',
    'subTitle': 'Author',
    'tags': tags,
  };
  database.execute(
    '''
    INSERT INTO favorite_items (
      source_key, folder_id, page_index, comic_id, display_order, comic_json,
      favorite_id, favorite_time, search_text, has_new_update
    ) VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, 0)
    ''',
    [
      sourceKey,
      folderId,
      pageIndex,
      comicId,
      displayOrder,
      jsonEncode(json),
      '2026-11-10 12:00:00',
      buildFavoriteSearchText(comicId, json),
    ],
  );
}
