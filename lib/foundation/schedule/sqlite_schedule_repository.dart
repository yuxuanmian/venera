import 'dart:io';

import 'package:path/path.dart' as file_path;
import 'package:sqlite3/sqlite3.dart';

import '../app.dart';
import 'schedule_repository.dart';
import 'schedule_state.dart';

/// SQLite implementation of the single-table schedule store.
///
/// Database: `App.dataPath/schedule_state.db`, schema v1.  It sits beside
/// `scan_results.db` and `tracking_state.db`, and depends on them in no
/// direction: any one of the three can be deleted or rebuilt without damaging
/// the other two (`contracts/schedule-v1.md` S1/S2).
///
/// The DDL here mirrors `specs/006-local-follow-up-loop/contracts/schedule-state-schema.sql`
/// verbatim, CHECK constraints included.  That attachment is a design document
/// and is never read at runtime; `schedule_repository_test.dart` parses it and
/// asserts this schema matches it column for column, so the two cannot drift.
class SqliteScheduleRepository implements ScheduleStateRepository {
  SqliteScheduleRepository({
    String? databasePath,
    void Function(String operation)? operationHook,
  }) : _configuredDatabasePath = databasePath,
       _operationHook = operationHook;

  final String? _configuredDatabasePath;
  final void Function(String operation)? _operationHook;
  Database? _database;
  bool _opened = false;

  static const int schemaVersion = 1;

  /// Columns this writer owns.  All seven, plus the two identity columns.
  ///
  /// The `ON CONFLICT DO UPDATE` list must contain exactly these: the whole
  /// table belongs to the schedule domain, so a missed column here is silently
  /// dropped on every update rather than being owned by somebody else.
  static const List<String> ownedColumns = [
    'next_at',
    'activity_at',
    'auto_hot_until',
    'manual_hot_enabled',
    'manual_hot_until',
    'old_schedule_jitter_applied',
  ];

  /// Resolve the app-owned default only when the repository is first opened.
  /// The singleton is imported during startup, before [App.dataPath] exists.
  String get databasePath =>
      _configuredDatabasePath ??
      file_path.join(App.dataPath, 'schedule_state.db');

  Database get database =>
      _database ?? (throw StateError('schedule repository is not open'));

  @override
  Future<void> ensureOpen() async {
    if (_opened) return;
    final parent = Directory(file_path.dirname(databasePath));
    if (!parent.existsSync()) parent.createSync(recursive: true);
    try {
      _database = sqlite3.open(databasePath);
      database.execute('PRAGMA journal_mode = WAL');
      database.execute('PRAGMA synchronous = FULL');
      _createSchema();
      _opened = true;
    } catch (error) {
      _database?.dispose();
      _database = null;
      throw ScheduleStorageException(
        'Unable to open schedule state database',
        error,
      );
    }
  }

  /// Creates the schema from `contracts/schedule-state-schema.sql`.
  ///
  /// Both CHECK constraints are carried verbatim.  The manual-hot one is what
  /// makes "enabled without a deadline" unrepresentable rather than merely
  /// discouraged.
  void _createSchema() {
    database.execute('''
      CREATE TABLE IF NOT EXISTS schedule_state (
        source_key TEXT NOT NULL,
        comic_id   TEXT NOT NULL,

        next_at     INTEGER,
        activity_at INTEGER,
        auto_hot_until INTEGER,

        manual_hot_enabled INTEGER NOT NULL DEFAULT 0
                           CHECK (manual_hot_enabled IN (0, 1)),
        manual_hot_until   INTEGER,

        old_schedule_jitter_applied INTEGER NOT NULL DEFAULT 0
                                    CHECK (old_schedule_jitter_applied IN (0, 1)),

        PRIMARY KEY (source_key, comic_id),

        CHECK ((manual_hot_enabled = 0) OR (manual_hot_until IS NOT NULL))
      )
    ''');
    _migrateSchema();
    database.execute('PRAGMA user_version = $schemaVersion');
  }

  /// Adds columns that `CREATE TABLE IF NOT EXISTS` cannot add to a table that
  /// already exists on a device.
  ///
  /// The same pattern the judgment and scan repositories use: `PRAGMA
  /// table_info`, then one `ALTER TABLE ADD COLUMN` per missing column.  The
  /// schedule store ships at v1, so today this is a no-op; it exists so the v1
  /// table can never become un-migratable.
  void _migrateSchema() {
    final columns = database
        .select('PRAGMA table_info(schedule_state)')
        .map((row) => row['name'] as String)
        .toSet();
    for (final column in ownedColumns) {
      if (!columns.contains(column)) {
        database.execute(
          'ALTER TABLE schedule_state ADD COLUMN $column INTEGER',
        );
      }
    }
  }

  @override
  Future<Map<String, ScheduleState>> readAll() async {
    await ensureOpen();
    try {
      return _snapshotOf(database.select('SELECT * FROM schedule_state'));
    } catch (error) {
      throw ScheduleStorageException('Unable to read schedule state', error);
    }
  }

  @override
  Future<Map<String, ScheduleState>> readExpired(int nowMs) async {
    await ensureOpen();
    try {
      // Only the two conditions this store can answer alone.  See the
      // interface doc: "no observation" and "no schedule record" are merged by
      // the caller, which is the only place that can see both stores.
      return _snapshotOf(
        database.select(
          'SELECT * FROM schedule_state WHERE next_at IS NULL OR next_at <= ?',
          [nowMs],
        ),
      );
    } catch (error) {
      throw ScheduleStorageException('Unable to read expired schedules', error);
    }
  }

  @override
  Future<int> applyBatch(List<ScheduleState> rows) async {
    await ensureOpen();
    // No recomputed row means no write at all.
    if (rows.isEmpty) return 0;
    try {
      _transaction('applyBatch', () {
        for (final row in rows) {
          database.execute(
            '''INSERT INTO schedule_state (
                 source_key, comic_id,
                 next_at, activity_at, auto_hot_until,
                 manual_hot_enabled, manual_hot_until,
                 old_schedule_jitter_applied
               ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(source_key, comic_id) DO UPDATE SET
                 next_at = excluded.next_at,
                 activity_at = excluded.activity_at,
                 auto_hot_until = excluded.auto_hot_until,
                 manual_hot_enabled = excluded.manual_hot_enabled,
                 manual_hot_until = excluded.manual_hot_until,
                 old_schedule_jitter_applied = excluded.old_schedule_jitter_applied''',
            [
              row.sourceKey,
              row.comicId,
              row.nextAtMs,
              row.activityAtMs,
              row.autoHotUntilMs,
              row.manualHotEnabled ? 1 : 0,
              row.manualHotUntilMs,
              row.oldScheduleJitterApplied ? 1 : 0,
            ],
          );
        }
      });
      return rows.length;
    } on ScheduleStorageException {
      rethrow;
    } catch (error) {
      throw ScheduleStorageException('Unable to apply schedule batch', error);
    }
  }

  @override
  Future<void> clear() async {
    await ensureOpen();
    try {
      _transaction('clear', () {
        database.execute('DELETE FROM schedule_state');
      });
    } on ScheduleStorageException {
      rethrow;
    } catch (error) {
      throw ScheduleStorageException('Unable to clear schedule state', error);
    }
  }

  @override
  Future<void> close() async {
    if (!_opened) return;
    _opened = false;
    _database?.dispose();
    _database = null;
  }

  Map<String, ScheduleState> _snapshotOf(ResultSet rows) {
    final snapshot = <String, ScheduleState>{};
    for (final row in rows) {
      final state = _stateFromRow(row);
      snapshot[state.identity] = state;
    }
    return snapshot;
  }

  ScheduleState _stateFromRow(Row row) => ScheduleState(
    sourceKey: row['source_key'] as String,
    comicId: row['comic_id'] as String,
    nextAtMs: row['next_at'] as int?,
    activityAtMs: row['activity_at'] as int?,
    autoHotUntilMs: row['auto_hot_until'] as int?,
    manualHotEnabled: (row['manual_hot_enabled'] as int) != 0,
    manualHotUntilMs: row['manual_hot_until'] as int?,
    oldScheduleJitterApplied: (row['old_schedule_jitter_applied'] as int) != 0,
  );

  T _transaction<T>(String operation, T Function() action) {
    _operationHook?.call('$operation.begin');
    database.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      database.execute('COMMIT');
      _operationHook?.call('$operation.commit');
      return result;
    } catch (_) {
      try {
        database.execute('ROLLBACK');
      } catch (_) {}
      rethrow;
    }
  }
}

/// The app-level repository, opened lazily by the schedule service.
final scheduleStateRepository = SqliteScheduleRepository();
