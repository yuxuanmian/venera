import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/res.dart';

const retirementSourceA = 'retire-source-a';
const retirementSourceB = 'retire-source-b';
const retirementFolderOne = 'folder-1';
const retirementFolderTwo = 'folder-2';

/// All fixture timestamps are derived from one instant so a reopened database
/// and every regression scenario use the same historical time relationship.
final fixtureNow = DateTime.utc(2026, 9, 9, 12);
final fixtureYesterday = fixtureNow.subtract(const Duration(days: 1));
final fixtureNextWeek = fixtureNow.add(const Duration(days: 7));
final fixtureLegacyUpdate = fixtureNow.subtract(const Duration(days: 8));

class RetirementFakeCounters {
  int detailCalls = 0;
  int readerPageCalls = 0;
  int numberedPageCalls = 0;
  int cursorPageCalls = 0;
  int updateCheckCalls = 0;
  int optimizedCalls = 0;
}

/// Small source-shaped test double used to prove that ordinary pagination is
/// still available while retired update-check entry points stay untouched.
class RetirementFakeSource {
  RetirementFakeSource({
    this.sourceKey = key,
    this.failDetail = false,
    this.detailError,
    this.failOptimized = false,
    this.readerPageError,
    this.readerPagesPending = false,
  });

  static const key = 'retire-fake-source';

  final String sourceKey;
  final bool failDetail;
  final String? detailError;
  final bool failOptimized;
  final String? readerPageError;
  final bool readerPagesPending;
  final counters = RetirementFakeCounters();

  Comic _comic(String id, {bool withHint = false}) => Comic(
    'Fake $id',
    'https://example.invalid/$id.jpg',
    id,
    'Author',
    const [],
    '',
    sourceKey,
    null,
    null,
    favoriteUpdate: withHint
        ? FavoriteUpdateHint(
            marker: 'hint-$id',
            updateTime: fixtureYesterday.toIso8601String(),
            isNew: true,
            metadata: const {'sourceUnread': true},
          )
        : null,
  );

  Comic comic(String id, {bool withHint = false}) =>
      _comic(id, withHint: withHint);

  FavoriteData numberedData({bool withUpdateCheck = false}) => FavoriteData(
    key: sourceKey,
    title: 'Retirement fake',
    multiFolder: false,
    loadComic: (page, [_]) async {
      counters.numberedPageCalls++;
      return Res([
        _comic('numbered-$page', withHint: withUpdateCheck),
      ], subData: 2);
    },
    loadNext: null,
    updateCheck: withUpdateCheck ? _updateCheck() : null,
  );

  FavoriteData numberedComicData(
    String comicId, {
    bool withUpdateCheck = false,
    int? totalPages = 1,
    Future<Res<List<Comic>>> Function(int page, [String? folder])? loader,
  }) => FavoriteData(
    key: sourceKey,
    title: 'Retirement fake',
    multiFolder: false,
    loadComic:
        loader ??
        (page, [_]) async {
          counters.numberedPageCalls++;
          return Res([
            _comic(comicId, withHint: withUpdateCheck),
          ], subData: totalPages);
        },
    loadNext: null,
    updateCheck: withUpdateCheck ? _updateCheck() : null,
  );

  FavoriteData cursorData({bool withUpdateCheck = false}) => FavoriteData(
    key: sourceKey,
    title: 'Retirement fake',
    multiFolder: false,
    loadComic: null,
    loadNext: (token, [_]) async {
      counters.cursorPageCalls++;
      return Res([
        _comic('cursor-${token ?? 'root'}', withHint: withUpdateCheck),
      ], subData: null);
    },
    updateCheck: withUpdateCheck ? _updateCheck() : null,
  );

  FavoriteData updateCheckOnlyData() => FavoriteData(
    key: sourceKey,
    title: 'Retirement fake',
    multiFolder: false,
    loadComic: null,
    loadNext: null,
    updateCheck: FavoriteUpdateCheckData(
      scanInterval: const Duration(hours: 1),
      load: optimized,
    ),
  );

  FavoriteUpdateCheckData _updateCheck() => FavoriteUpdateCheckData(
    scanInterval: const Duration(hours: 1),
    load: ([_]) async {
      counters.updateCheckCalls++;
      return Res(
        FavoriteUpdateSnapshot(
          comics: [_comic('optimized', withHint: true)],
          pageSize: 1,
          total: 1,
        ),
      );
    },
  );

  Future<Res<FavoriteUpdateSnapshot>> optimized([String? folder]) async {
    counters.optimizedCalls++;
    if (failOptimized) return const Res.error('optimized disabled');
    return _updateCheck().load(folder);
  }

  Future<Res<ComicDetails>> detail(String id) async {
    counters.detailCalls++;
    if (detailError != null) return Res.error(detailError!);
    if (failDetail) return const Res.error('detail failed');
    return Res(
      ComicDetails.fromJson({
        'title': 'Fake $id',
        'subtitle': 'Author',
        'cover': '',
        'tags': <String, List<String>>{},
        'chapters': <String, String>{'1': 'Chapter 1'},
        'sourceKey': sourceKey,
        'comicId': id,
      }),
    );
  }

  Future<Res<List<String>>> readerPages(String id, String? ep) async {
    counters.readerPageCalls++;
    if (readerPagesPending) {
      return Completer<Res<List<String>>>().future;
    }
    if (readerPageError != null) return Res.error(readerPageError!);
    return const Res(<String>[]);
  }

  ComicSource buildComicSource({FavoriteData? favoriteData}) => ComicSource(
    'Retirement fake $sourceKey',
    sourceKey,
    null,
    null,
    null,
    favoriteData,
    const [],
    null,
    null,
    detail,
    null,
    readerPages,
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

class RetirementFixture {
  RetirementFixture({required this.directory, required this.cache});

  final Directory directory;
  final NetworkFavoriteCacheManager cache;

  bool _disposed = false;

  String get databasePath =>
      '${directory.path}${Platform.pathSeparator}retirement.db';

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    cache.close();
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  }
}

Future<RetirementFixture> createRetirementFixture() async {
  final directory = await Directory.systemTemp.createTemp(
    'venera-scan-retirement-',
  );
  // Product pages and services resolve the factory singleton. Use that same
  // object here so tests observe the exact database connection they exercise.
  final cache = NetworkFavoriteCacheManager();
  final fixture = RetirementFixture(directory: directory, cache: cache);
  await cache.init(databasePath: fixture.databasePath, migrateLegacy: false);
  seedRetirementHistory(fixture.databasePath);
  return fixture;
}

void seedRetirementHistory(String databasePath) {
  final database = sqlite3.open(databasePath);
  try {
    final yesterday = fixtureYesterday.millisecondsSinceEpoch;
    final nextWeek = fixtureNextWeek.millisecondsSinceEpoch;
    final favoriteTime = fixtureYesterday
        .toIso8601String()
        .replaceFirst('T', ' ')
        .substring(0, 19);
    final state = jsonEncode({
      'updatedAt': fixtureLegacyUpdate.toIso8601String(),
      'latestChapterId': 'chapter-10',
      'chapterCount': 10,
      'recentChapterIds': ['chapter-10', 'chapter-9'],
    });

    database.execute(
      '''
      INSERT INTO favorite_folders
        (source_key, folder_id, title, updated_at, full_cache_at,
         full_cache_pages, full_cache_comics)
      VALUES (?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?)
    ''',
      [
        retirementSourceA,
        retirementFolderOne,
        'Retirement folder 1',
        yesterday,
        yesterday,
        1,
        4,
        retirementSourceA,
        retirementFolderTwo,
        'Retirement folder 2',
        yesterday,
        yesterday,
        1,
        2,
        retirementSourceB,
        retirementFolderOne,
        'Retirement folder B',
        yesterday,
        yesterday,
        1,
        1,
      ],
    );

    final comics = <({String id, String folder, int order})>[
      (id: 'retire-a', folder: retirementFolderOne, order: 0),
      (id: 'retire-d', folder: retirementFolderOne, order: 1),
      (id: 'retire-c', folder: retirementFolderOne, order: 2),
      (id: 'retire-d', folder: retirementFolderTwo, order: 0),
      (id: 'retire-b', folder: retirementFolderTwo, order: 1),
      (id: 'retire-e', folder: retirementFolderOne, order: 0),
    ];
    for (final comic in comics) {
      final source = comic.id == 'retire-e'
          ? retirementSourceB
          : retirementSourceA;
      database.execute(
        '''
        INSERT INTO favorite_pages
          (source_key, folder_id, page_index, request_token, next_token,
           max_page, updated_at)
        VALUES (?, ?, 1, 'retirement-page', NULL, 1, ?)
        ON CONFLICT DO NOTHING
      ''',
        [source, comic.folder, yesterday],
      );
      database.execute(
        '''
        INSERT OR IGNORE INTO favorite_items
          (source_key, folder_id, page_index, comic_id, display_order,
           comic_json, favorite_id, favorite_time, search_text, last_update_time,
           last_check_time, has_new_update)
        VALUES (?, ?, 1, ?, ?, ?, NULL, ?, ?, NULL, NULL, 0)
      ''',
        [
          source,
          comic.folder,
          comic.id,
          comic.order,
          jsonEncode({
            'id': comic.id,
            'title': comic.id,
            'cover': '',
            'subTitle': '',
            'tags': <String>[],
            'sourceKey': source,
          }),
          favoriteTime,
          comic.id,
        ],
      );
      database.execute(
        '''
        INSERT OR IGNORE INTO favorite_membership (source_key, folder_id, comic_id)
        VALUES (?, ?, ?)
      ''',
        [source, comic.folder, comic.id],
      );
    }

    database.execute(
      '''
      INSERT INTO comic_check_state
        (source_key, comic_id, last_update_time, update_marker, update_state,
         last_check_time, has_new_update, retry_after, check_failures,
         check_not_found_count, check_suspect_gone, baseline_at,
         source_activity_at, next_check_at, auto_hot_until, manual_hot_until,
         manual_hot_enabled, old_schedule_jitter_applied, source_update_metadata)
      VALUES (?, 'retire-a', ?, 'legacy-test|chapter-10', ?, ?, 1, NULL, 0, 0, 0,
               ?, ?, ?, NULL, NULL, 0, 0, ?)
    ''',
      [
        retirementSourceA,
        fixtureLegacyUpdate.toIso8601String(),
        state,
        yesterday,
        yesterday,
        yesterday,
        nextWeek,
        jsonEncode({'source': 'retirement-fixture'}),
      ],
    );
    database.execute(
      '''
      INSERT INTO comic_check_state
        (source_key, comic_id, last_update_time, update_marker, update_state,
         last_check_time, has_new_update, retry_after, check_failures,
         check_not_found_count, check_suspect_gone, baseline_at,
         source_activity_at, next_check_at, auto_hot_until, manual_hot_until,
         manual_hot_enabled, old_schedule_jitter_applied, source_update_metadata)
      VALUES (?, 'retire-b', NULL, 'legacy-test|gone', NULL, ?, 0, ?, 2, 2, 1,
               NULL, NULL, NULL, NULL, NULL, 0, 0, NULL)
    ''',
      [retirementSourceA, yesterday, nextWeek],
    );
    database.execute(
      '''
      INSERT INTO comic_check_state
        (source_key, comic_id, last_update_time, update_marker, update_state,
         last_check_time, has_new_update, retry_after, check_failures,
         check_not_found_count, check_suspect_gone, baseline_at,
         source_activity_at, next_check_at, auto_hot_until, manual_hot_until,
         manual_hot_enabled, old_schedule_jitter_applied, source_update_metadata)
      VALUES (?, 'retire-e', ?, 'legacy-test|e', ?, ?, 0,
               NULL, 1, 0, 0, ?, ?, NULL, NULL, NULL, 0, 0, NULL)
    ''',
      [
        retirementSourceB,
        fixtureLegacyUpdate.toIso8601String(),
        state,
        yesterday,
        yesterday,
        yesterday,
      ],
    );

    database.execute(
      '''
      INSERT INTO favorite_update_scan_state
        (source_key, folder_id, marker_scheme, last_attempt_at, last_success_at,
         retry_after, check_failures, last_page_count, last_comic_count)
      VALUES (?, ?, 'legacy-list', ?, ?, ?, 2, 3, 6)
    ''',
      [retirementSourceA, retirementFolderTwo, yesterday, yesterday, nextWeek],
    );

    database.execute(
      '''
      INSERT INTO scan_queue (run_id, source_key, comic_id, status, result, error)
      VALUES (9003, ?, 'retire-a', 'pending', NULL, NULL),
             (9003, ?, 'retire-b', 'done', 'not_found', 'legacy error')
    ''',
      [retirementSourceA, retirementSourceA],
    );
    database.execute('INSERT INTO metadata (key, value) VALUES (?, ?)', [
      'follow_update_run',
      jsonEncode({
        'runId': 9003,
        'mode': 'regular',
        'ignoreRetryAfter': false,
        'total': 2,
        'status': 'running',
        'startedAt': yesterday,
        'finishedAt': null,
      }),
    ]);
  } finally {
    database.dispose();
  }
}

Map<String, List<Map<String, Object?>>> snapshotRetirementState(
  String databasePath,
) {
  final database = sqlite3.open(databasePath);
  try {
    return {
      'comic_check_state': _snapshotTable(
        database,
        'comic_check_state',
        'source_key, comic_id',
      ),
      'favorite_update_scan_state': _snapshotTable(
        database,
        'favorite_update_scan_state',
        'source_key, folder_id',
      ),
      'scan_queue': _snapshotTable(
        database,
        'scan_queue',
        'run_id, source_key, comic_id',
      ),
      'follow_update_run': _snapshotMetadata(database, 'follow_update_run'),
    };
  } finally {
    database.dispose();
  }
}

/// Snapshot the ordinary favorite cache separately from the retired scan
/// tables. Tests use this to prove that an ordinary list request still writes
/// and that stale responses never repopulate cleared pages.
Map<String, List<Map<String, Object?>>> snapshotRetirementCacheState(
  String databasePath,
) {
  final database = sqlite3.open(databasePath);
  try {
    return {
      'favorite_folders': _snapshotTable(
        database,
        'favorite_folders',
        'source_key, folder_id',
      ),
      'favorite_pages': _snapshotTable(
        database,
        'favorite_pages',
        'source_key, folder_id, page_index, request_token',
      ),
      'favorite_items': _snapshotTable(
        database,
        'favorite_items',
        'source_key, folder_id, page_index, comic_id',
      ),
      'favorite_membership': _snapshotTable(
        database,
        'favorite_membership',
        'source_key, folder_id, comic_id',
      ),
    };
  } finally {
    database.dispose();
  }
}

List<Map<String, Object?>> _snapshotTable(
  Database database,
  String table,
  String orderBy,
) {
  final columns = database
      .select('PRAGMA table_info($table)')
      .map((row) => row['name'] as String)
      .toList();
  final rows = database.select('SELECT * FROM $table ORDER BY $orderBy');
  return [
    for (final row in rows) {for (final column in columns) column: row[column]},
  ];
}

List<Map<String, Object?>> _snapshotMetadata(Database database, String key) {
  final rows = database.select(
    'SELECT key, value FROM metadata WHERE key = ? ORDER BY key',
    [key],
  );
  return [
    for (final row in rows) {'key': row['key'], 'value': row['value']},
  ];
}
