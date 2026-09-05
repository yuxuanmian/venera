import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/tracking/update_state.dart';

void _seedFavoriteDatabase(String path) {
  final database = sqlite3.open(path);
  try {
    database.execute('''
      INSERT INTO favorite_folders
        (source_key, folder_id, title, updated_at)
      VALUES ('legacy-source', 'folder-1', 'Legacy', 1)
    ''');
    database.execute('''
      INSERT INTO favorite_pages
        (source_key, folder_id, page_index, request_token, updated_at)
      VALUES ('legacy-source', 'folder-1', 1, 'page-1', 1)
    ''');
    database.execute('''
      INSERT INTO favorite_items
        (source_key, folder_id, page_index, comic_id, display_order,
         comic_json, favorite_time, search_text)
      VALUES ('legacy-source', 'folder-1', 1, 'comic-1', 0,
              '{"title":"Legacy comic","cover":"","tags":[]}',
              '2026-09-01 00:00:00', 'legacy comic')
    ''');
    database.execute('''
      INSERT INTO comic_check_state
        (source_key, comic_id, last_update_time, update_marker,
         has_new_update, last_check_time, retry_after, check_failures,
         check_not_found_count, check_suspect_gone, baseline_at,
         source_activity_at, next_check_at, auto_hot_until,
         manual_hot_until, manual_hot_enabled, old_schedule_jitter_applied,
         source_update_metadata)
      VALUES ('legacy-source', 'comic-1', '2026-08-31', 'legacy|marker',
              1, 111, 222, 3, 4, 1, 333, 444, 555, 666,
              4102444800000, 1, 1, '{"isNew":true,"old":"diagnostic"}')
    ''');
    database.execute('DELETE FROM metadata WHERE key = ?', [
      'tracking_evidence_migration_v1',
    ]);
  } finally {
    database.dispose();
  }
}

void main() {
  late Directory tempDir;
  late String databasePath;
  late NetworkFavoriteCacheManager cache;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'venera-tracking-migration-',
    );
    databasePath = '${tempDir.path}${Platform.pathSeparator}cache.db';
    cache = NetworkFavoriteCacheManager.forTesting();
    await cache.init(databasePath: databasePath, migrateLegacy: false);
    cache.close();
    _seedFavoriteDatabase(databasePath);
  });

  tearDown(() async {
    cache.close();
    await tempDir.delete(recursive: true);
  });

  test(
    'invalidates only legacy evidence and preserves user/scheduler fields',
    () async {
      cache = NetworkFavoriteCacheManager.forTesting();
      await cache.init(databasePath: databasePath, migrateLegacy: false);

      final database = sqlite3.open(databasePath);
      try {
        final row = database.select(
          '''SELECT update_state, update_marker, source_update_metadata,
                      has_new_update, last_check_time, retry_after,
                      check_failures, check_not_found_count,
                      check_suspect_gone, baseline_at, source_activity_at,
                      next_check_at, auto_hot_until, manual_hot_until,
                      manual_hot_enabled, old_schedule_jitter_applied
               FROM comic_check_state
               WHERE source_key = 'legacy-source' AND comic_id = 'comic-1' ''',
        ).single;
        expect(row['update_state'], isNull);
        expect(row['update_marker'], isNull);
        expect(row['source_update_metadata'], isNull);
        expect(row['has_new_update'], 1);
        expect(row['last_check_time'], 111);
        expect(row['retry_after'], 222);
        expect(row['check_failures'], 3);
        expect(row['check_not_found_count'], 4);
        expect(row['check_suspect_gone'], 1);
        expect(row['baseline_at'], 333);
        expect(row['source_activity_at'], 444);
        expect(row['next_check_at'], 555);
        expect(row['auto_hot_until'], 666);
        expect(row['manual_hot_until'], 4102444800000);
        expect(row['manual_hot_enabled'], 1);
        expect(row['old_schedule_jitter_applied'], 1);
        expect(
          database.select('SELECT value FROM metadata WHERE key = ?', [
            'tracking_evidence_migration_v1',
          ]).single['value'],
          'done',
        );
      } finally {
        database.dispose();
      }
    },
  );

  test('repeated startup does not invalidate a new-format baseline', () async {
    cache = NetworkFavoriteCacheManager.forTesting();
    await cache.init(databasePath: databasePath, migrateLegacy: false);
    cache.recordComicCheckEverywhere(
      'legacy-source',
      'comic-1',
      updateState: const UpdateState(latestChapterId: 'chapter-2'),
      updateMarker: 'opaque-full-marker',
      completedAt: DateTime.utc(2026, 9, 2),
    );
    cache.close();

    cache = NetworkFavoriteCacheManager.forTesting();
    await cache.init(databasePath: databasePath, migrateLegacy: false);
    cache.close();

    final database = sqlite3.open(databasePath);
    try {
      final row = database.select(
        '''SELECT update_state, update_marker
               FROM comic_check_state
               WHERE source_key = 'legacy-source' AND comic_id = 'comic-1' ''',
      ).single;
      expect(row['update_marker'], 'opaque-full-marker');
      expect(row['update_state'], '{"latestChapterId":"chapter-2"}');
    } finally {
      database.dispose();
    }
  });
}
