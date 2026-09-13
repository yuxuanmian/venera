import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates_service.dart';

import 'fixtures.dart';

void main() {
  late RetirementFixture fixture;
  late Directory appDirectory;

  setUp(() async {
    fixture = await createRetirementFixture();
    // `runCheckNow` reaches the coordinator, which resolves its store paths
    // from `App.dataPath`.  This is a separate directory rather than the
    // fixture's, so the round's own databases never hold the fixture open and
    // deletion at teardown still succeeds.
    appDirectory = await Directory.systemTemp.createTemp('venera-state-app-');
    App.dataPath = appDirectory.path;
    App.cachePath = appDirectory.path;
  });

  tearDown(() async {
    await fixture.dispose();
    try {
      await appDirectory.delete(recursive: true);
    } on PathAccessException {
      // Windows may release a native SQLite handle just after dispose.
    }
  });

  test(
    'history rows survive a close and reopen without resuming work',
    () async {
      final before = snapshotRetirementState(fixture.databasePath);
      final ordinaryBefore = snapshotRetirementCacheState(fixture.databasePath);

      // The product singleton is the connection used by pages and services;
      // close and reopen that same object instead of opening a parallel test
      // manager against the database.
      fixture.cache.close();
      final reopened = NetworkFavoriteCacheManager();

      await reopened.init(
        databasePath: fixture.databasePath,
        migrateLegacy: false,
      );
      await FollowUpdatesService.runCheckNow();
      // The retired scanner's forced entry point is gone: a manual check now
      // goes through the coordinator and respects the schedule, so there is no
      // second "ignore everything and scan" call to make.

      expect(snapshotRetirementState(fixture.databasePath), before);
      expect(
        snapshotRetirementCacheState(fixture.databasePath),
        ordinaryBefore,
      );
      expect(
        reopened.getFavoriteUpdateScanState(
          const NetworkFavoriteFolderRef(
            sourceKey: retirementSourceA,
            folderId: retirementFolderTwo,
          ),
        ),
        isNotNull,
      );
    },
  );

  test('schema keeps every retained column, default, key, and index', () {
    final database = sqlite3.open(fixture.databasePath);
    try {
      final expectedColumns = <String, List<String>>{
        'metadata': ['key', 'value'],
        'favorite_folders': [
          'source_key',
          'folder_id',
          'title',
          'updated_at',
          'full_cache_at',
          'full_cache_pages',
          'full_cache_comics',
        ],
        'favorite_pages': [
          'source_key',
          'folder_id',
          'page_index',
          'request_token',
          'next_token',
          'max_page',
          'updated_at',
        ],
        'favorite_items': [
          'source_key',
          'folder_id',
          'page_index',
          'comic_id',
          'display_order',
          'comic_json',
          'favorite_id',
          'favorite_time',
          'search_text',
          'last_update_time',
          'last_check_time',
          'has_new_update',
          'update_marker',
          'retry_after',
          'check_failures',
          'check_not_found_count',
          'check_suspect_gone',
        ],
        'favorite_membership': ['source_key', 'folder_id', 'comic_id'],
        'comic_check_state': [
          'source_key',
          'comic_id',
          'last_update_time',
          'update_marker',
          'update_state',
          'last_check_time',
          'has_new_update',
          'retry_after',
          'check_failures',
          'check_not_found_count',
          'check_suspect_gone',
          'baseline_at',
          'source_activity_at',
          'next_check_at',
          'auto_hot_until',
          'manual_hot_until',
          'manual_hot_enabled',
          'old_schedule_jitter_applied',
          'source_update_metadata',
        ],
        'favorite_update_scan_state': [
          'source_key',
          'folder_id',
          'marker_scheme',
          'last_attempt_at',
          'last_success_at',
          'retry_after',
          'check_failures',
          'last_page_count',
          'last_comic_count',
        ],
        'scan_queue': [
          'run_id',
          'source_key',
          'comic_id',
          'status',
          'result',
          'error',
        ],
      };

      for (final entry in expectedColumns.entries) {
        final rows = database.select('PRAGMA table_info(${entry.key})');
        expect(rows.map((row) => row['name']).toList(), entry.value);
      }

      void expectColumn(
        String table,
        String name, {
        required String type,
        required bool notNull,
        String? defaultSql,
        required int primaryKey,
      }) {
        final row = database
            .select('PRAGMA table_info($table)')
            .firstWhere((row) => row['name'] == name);
        expect(row['type'], type);
        expect(row['notnull'], notNull ? 1 : 0);
        expect(row['dflt_value']?.toString(), defaultSql);
        expect(row['pk'], primaryKey);
      }

      expectColumn(
        'metadata',
        'key',
        type: 'TEXT',
        notNull: false,
        primaryKey: 1,
      );
      expectColumn(
        'metadata',
        'value',
        type: 'TEXT',
        notNull: true,
        primaryKey: 0,
      );
      expectColumn(
        'favorite_folders',
        'full_cache_pages',
        type: 'INTEGER',
        notNull: true,
        defaultSql: '0',
        primaryKey: 0,
      );
      expectColumn(
        'favorite_folders',
        'full_cache_comics',
        type: 'INTEGER',
        notNull: true,
        defaultSql: '0',
        primaryKey: 0,
      );
      expectColumn(
        'favorite_items',
        'search_text',
        type: 'TEXT',
        notNull: true,
        defaultSql: "''",
        primaryKey: 0,
      );
      for (final column in [
        'has_new_update',
        'manual_hot_enabled',
        'old_schedule_jitter_applied',
      ]) {
        expectColumn(
          'comic_check_state',
          column,
          type: 'INTEGER',
          notNull: true,
          defaultSql: '0',
          primaryKey: 0,
        );
      }
      for (final column in [
        'check_failures',
        'check_not_found_count',
        'check_suspect_gone',
      ]) {
        expectColumn(
          'favorite_items',
          column,
          type: 'INTEGER',
          notNull: true,
          defaultSql: '0',
          primaryKey: 0,
        );
      }
      expectColumn(
        'favorite_update_scan_state',
        'check_failures',
        type: 'INTEGER',
        notNull: true,
        defaultSql: '0',
        primaryKey: 0,
      );
      expectColumn(
        'favorite_update_scan_state',
        'last_page_count',
        type: 'INTEGER',
        notNull: true,
        defaultSql: '0',
        primaryKey: 0,
      );
      expectColumn(
        'favorite_update_scan_state',
        'last_comic_count',
        type: 'INTEGER',
        notNull: true,
        defaultSql: '0',
        primaryKey: 0,
      );
      expectColumn(
        'scan_queue',
        'status',
        type: 'TEXT',
        notNull: true,
        defaultSql: "'pending'",
        primaryKey: 0,
      );

      final primaryKeys = <String, List<String>>{
        'favorite_folders': ['source_key', 'folder_id'],
        'favorite_pages': ['source_key', 'folder_id', 'request_token'],
        'favorite_items': ['source_key', 'folder_id', 'page_index', 'comic_id'],
        'favorite_membership': ['source_key', 'folder_id', 'comic_id'],
        'comic_check_state': ['source_key', 'comic_id'],
        'favorite_update_scan_state': ['source_key', 'folder_id'],
        'scan_queue': ['run_id', 'source_key', 'comic_id'],
      };
      for (final entry in primaryKeys.entries) {
        final rows =
            database
                .select('PRAGMA table_info(${entry.key})')
                .where((row) => (row['pk'] as int) > 0)
                .toList()
              ..sort((a, b) => (a['pk'] as int).compareTo(b['pk'] as int));
        expect(rows.map((row) => row['name']).toList(), entry.value);
      }

      final expectedIndexes = <String, List<String>>{
        'idx_comic_check_state_next_check': ['next_check_at'],
        'favorite_items_search': ['source_key', 'folder_id', 'search_text'],
        'idx_favorite_items_comic': ['source_key', 'folder_id', 'comic_id'],
      };
      for (final entry in expectedIndexes.entries) {
        final table = entry.key == 'idx_comic_check_state_next_check'
            ? 'comic_check_state'
            : 'favorite_items';
        expect(
          database
              .select('PRAGMA index_list($table)')
              .any((row) => row['name'] == entry.key),
          isTrue,
        );
        expect(
          database
              .select('PRAGMA index_info(${entry.key})')
              .map((row) => row['name'])
              .toList(),
          entry.value,
        );
      }

      expect(
        database.select('SELECT value FROM metadata WHERE key = ?', [
          'follow_update_run',
        ]),
        hasLength(1),
      );
    } finally {
      database.dispose();
    }
  });
}
