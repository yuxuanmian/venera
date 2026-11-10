import 'dart:io';

import 'package:path/path.dart' as file_path;
import 'package:sqlite3/sqlite3.dart';

import '../app.dart';
import '../sqlite_recovery_batch.dart';
import 'judgment.dart';
import 'judgment_event.dart';
import 'judgment_repository.dart';
import 'judgment_state.dart';

/// SQLite implementation of the judgment state store.
///
/// Database: `App.dataPath/tracking_state.db`. It sits beside
/// `scan_results.db` and depends on it in no direction: either side can be
/// deleted or rebuilt without damaging the other (Contract J10, data-model
/// section 2).
class SqliteJudgmentRepository implements JudgmentStateRepository {
  SqliteJudgmentRepository({
    String? databasePath,
    void Function(String operation)? operationHook,
  }) : _configuredDatabasePath = databasePath,
       _operationHook = operationHook;

  final String? _configuredDatabasePath;
  final void Function(String operation)? _operationHook;
  Database? _database;
  bool _opened = false;

  static const int schemaVersion = 2;

  /// Columns this writer owns (data-model 2.1-2.3).
  ///
  /// The `ON CONFLICT DO UPDATE` list must contain exactly these.  Future
  /// scheduling, health and user-confirmation columns belong to other writers
  /// and must never be added here: a whole-row overwrite would silently clear
  /// them (research R-05).
  static const List<String> ownedColumns = [
    'fact_json',
    'fact_observed_at_ms',
    'evidence_schema',
    'last_decision',
    'last_evidence',
    'last_previous_value',
    'last_current_value',
    'last_reason',
    'decided_at_ms',
    'no_common_streak',
    'has_new_update',
    'processed_attempt_id',
    'algorithm_version',
  ];

  /// Resolve the app-owned default only when the repository is first opened.
  /// The singleton is imported during startup, before [App.dataPath] exists.
  String get databasePath =>
      _configuredDatabasePath ??
      file_path.join(App.dataPath, 'tracking_state.db');

  Database get database =>
      _database ?? (throw StateError('judgment repository is not open'));

  @override
  Future<void> ensureOpen() async {
    if (_opened) return;
    final parent = Directory(file_path.dirname(databasePath));
    if (!parent.existsSync()) parent.createSync(recursive: true);
    try {
      _database = sqlite3.open(databasePath);
      database.execute('PRAGMA foreign_keys = ON');
      database.execute('PRAGMA journal_mode = WAL');
      database.execute('PRAGMA synchronous = FULL');
      _createSchema();
      _opened = true;
    } catch (error) {
      _database?.dispose();
      _database = null;
      throw JudgmentStorageException(
        'Unable to open judgment state database',
        error,
      );
    }
  }

  /// Creates the schema from `contracts/state-schema.sql`.
  ///
  /// Both CHECK constraints are carried verbatim: the three fact columns live
  /// and die together, and a fact always has a label.
  void _createSchema() {
    database.execute('''
      CREATE TABLE IF NOT EXISTS judgment_state (
        source_key TEXT NOT NULL,
        comic_id   TEXT NOT NULL,

        fact_json            TEXT,
        fact_observed_at_ms  INTEGER,
        evidence_schema      TEXT,

        last_decision   TEXT    NOT NULL
                        CHECK (last_decision IN ('changed','unchanged','rebaseline','unknown')),
        last_evidence   TEXT
                        CHECK (last_evidence IS NULL OR last_evidence IN
                               ('updatedAt','latestChapterId','chapterCount','recentChapterIds')),
        last_previous_value TEXT,
        last_current_value  TEXT,
        last_reason     TEXT    NOT NULL
                        CHECK (last_reason IN (
                          'noUsableEvidence','noPreviousEvidence','labelChanged','noCommonEvidence',
                          'later','regressed','equal','different',
                          'increased','decreased','sameFirst','newerAnchor','noSafeAnchor',
                          'priority'
                        )),
        decided_at_ms     INTEGER NOT NULL,
        no_common_streak  INTEGER NOT NULL DEFAULT 0 CHECK (no_common_streak >= 0),

        has_new_update        INTEGER NOT NULL DEFAULT 0 CHECK (has_new_update IN (0, 1)),
        processed_attempt_id  TEXT,
        -- The judgmentAlgorithmVersion that produced this row.  NULL means the
        -- row predates the column, which the service reads as "produced by
        -- rules that no longer apply" and recomputes.
        algorithm_version     INTEGER,

        PRIMARY KEY (source_key, comic_id),

        CHECK ((fact_json IS NULL) = (fact_observed_at_ms IS NULL)),
        CHECK (fact_json IS NULL OR evidence_schema IS NOT NULL)
      )
    ''');
    _migrateSchema();
    database.execute('''
      CREATE TABLE IF NOT EXISTS comic_schedule_input (
        source_key TEXT NOT NULL,
        comic_id TEXT NOT NULL,
        attempt_id TEXT NOT NULL,
        algorithm_version INTEGER NOT NULL,
        observed_at_ms INTEGER NOT NULL,
        activity_at_ms INTEGER,
        PRIMARY KEY (source_key, comic_id),
        FOREIGN KEY (source_key, comic_id)
          REFERENCES judgment_state(source_key, comic_id) ON DELETE CASCADE
      )
    ''');
    database.execute('PRAGMA user_version = $schemaVersion');
  }

  /// Adds columns that `CREATE TABLE IF NOT EXISTS` cannot add to a table that
  /// already exists on a device.
  ///
  /// The same pattern as `favorites.dart` and the scan repository:
  /// `PRAGMA table_info` then one `ALTER TABLE ADD COLUMN` per missing column.
  /// Existing rows keep a NULL version, which is precisely the signal that
  /// their decision was produced by rules that may no longer apply.
  void _migrateSchema() {
    final columns = database
        .select('PRAGMA table_info(judgment_state)')
        .map((row) => row['name'] as String)
        .toSet();
    if (!columns.contains('algorithm_version')) {
      database.execute(
        'ALTER TABLE judgment_state ADD COLUMN algorithm_version INTEGER',
      );
    }
  }

  @override
  Future<Map<String, JudgmentState>> readSnapshot() async {
    await ensureOpen();
    try {
      final rows = database.select('SELECT * FROM judgment_state');
      final snapshot = <String, JudgmentState>{};
      for (final row in rows) {
        final state = _stateFromRow(row);
        snapshot[state.identity] = state;
      }
      return snapshot;
    } catch (error) {
      throw JudgmentStorageException('Unable to read judgment state', error);
    }
  }

  @override
  Future<JudgmentState?> readFor(String sourceKey, String comicId) async {
    await ensureOpen();
    try {
      final rows = database.select(
        'SELECT * FROM judgment_state WHERE source_key = ? AND comic_id = ?',
        [sourceKey, comicId],
      );
      return rows.isEmpty ? null : _stateFromRow(rows.single);
    } catch (error) {
      throw JudgmentStorageException('Unable to read judgment state', error);
    }
  }

  Map<String, ({JudgmentState state, ComicScheduleInput input})>
  readComicRecoveryInputs() {
    final rows = database.select('''
      SELECT j.*,
             i.attempt_id AS schedule_attempt_id,
             i.observed_at_ms AS schedule_observed_at_ms,
             i.activity_at_ms
      FROM judgment_state j
      JOIN comic_schedule_input i
        ON i.source_key = j.source_key
       AND i.comic_id = j.comic_id
       AND i.attempt_id = j.processed_attempt_id
       AND i.algorithm_version = j.algorithm_version
    ''');
    final result =
        <String, ({JudgmentState state, ComicScheduleInput input})>{};
    for (final row in rows) {
      final state = _stateFromRow(row);
      final observedAtMs = row['schedule_observed_at_ms'] as int;
      final activityAtMs = row['activity_at_ms'] as int?;
      final input = ComicScheduleInput(
        sourceKey: state.sourceKey,
        comicId: state.comicId,
        attemptId: row['schedule_attempt_id'] as String,
        conclusion: state.lastDecision,
        observedAtMs: observedAtMs,
        activityAt: activityAtMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(activityAtMs, isUtc: true),
      );
      result[state.identity] = (state: state, input: input);
    }
    return result;
  }

  Set<String> applyComicJudgments(
    Map<String, ({JudgmentState state, ComicScheduleInput? input})> rows,
  ) {
    if (rows.isEmpty) return {};
    return _transaction('applyComicJudgments', () {
      return writeRecoveryRows(database, rows, (entry) {
        _writeState(entry.state);
        final input = entry.input;
        if (input == null) {
          database.execute(
            'DELETE FROM comic_schedule_input '
            'WHERE source_key = ? AND comic_id = ?',
            [entry.state.sourceKey, entry.state.comicId],
          );
          return;
        }
        database.execute(
          '''
          INSERT INTO comic_schedule_input (
            source_key, comic_id, attempt_id, algorithm_version,
            observed_at_ms, activity_at_ms
          ) VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT (source_key, comic_id) DO UPDATE SET
            attempt_id = excluded.attempt_id,
            algorithm_version = excluded.algorithm_version,
            observed_at_ms = excluded.observed_at_ms,
            activity_at_ms = excluded.activity_at_ms
        ''',
          [
            input.sourceKey,
            input.comicId,
            input.attemptId,
            entry.state.algorithmVersion,
            input.observedAtMs,
            input.activityAt?.millisecondsSinceEpoch,
          ],
        );
      });
    });
  }

  @override
  Future<int> applyBatch(List<JudgmentState> rows) async {
    await ensureOpen();
    // No pending observation means no write at all (FR-024 / SC-002).
    if (rows.isEmpty) return 0;
    try {
      _transaction('applyBatch', () {
        for (final row in rows) {
          _writeState(row);
          database.execute(
            '''
            DELETE FROM comic_schedule_input
            WHERE source_key = ? AND comic_id = ?
              AND (attempt_id IS NOT ? OR algorithm_version IS NOT ?)
          ''',
            [
              row.sourceKey,
              row.comicId,
              row.processedAttemptId,
              row.algorithmVersion,
            ],
          );
        }
      });
      return rows.length;
    } on JudgmentStorageException {
      rethrow;
    } catch (error) {
      throw JudgmentStorageException('Unable to apply judgment batch', error);
    }
  }

  void _writeState(JudgmentState row) {
    database.execute(
      '''INSERT INTO judgment_state (
           source_key, comic_id,
           fact_json, fact_observed_at_ms, evidence_schema,
           last_decision, last_evidence, last_previous_value,
           last_current_value, last_reason, decided_at_ms,
           no_common_streak, has_new_update, processed_attempt_id,
           algorithm_version
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(source_key, comic_id) DO UPDATE SET
           fact_json = excluded.fact_json,
           fact_observed_at_ms = excluded.fact_observed_at_ms,
           evidence_schema = excluded.evidence_schema,
           last_decision = excluded.last_decision,
           last_evidence = excluded.last_evidence,
           last_previous_value = excluded.last_previous_value,
           last_current_value = excluded.last_current_value,
           last_reason = excluded.last_reason,
           decided_at_ms = excluded.decided_at_ms,
           no_common_streak = excluded.no_common_streak,
           has_new_update = excluded.has_new_update,
           processed_attempt_id = excluded.processed_attempt_id,
           algorithm_version = excluded.algorithm_version''',
      [
        row.sourceKey,
        row.comicId,
        row.factJson,
        row.factObservedAtMs,
        row.evidenceSchema,
        row.lastDecision.value,
        row.lastEvidence?.value,
        row.lastPreviousValue,
        row.lastCurrentValue,
        row.lastReason.value,
        row.decidedAtMs,
        row.noCommonStreak,
        row.hasNewUpdate ? 1 : 0,
        row.processedAttemptId,
        row.algorithmVersion,
      ],
    );
  }

  @override
  Future<int> clearVisibleFlag(String sourceKey, String comicId) async {
    await ensureOpen();
    try {
      // One statement, one row, one column.  Not `applyBatch` on a
      // `copyWith(hasNewUpdate: false)` row: that would rewrite all thirteen
      // owned columns and re-read the row first, and this runs on every comic
      // open (Contract E6).
      database.execute(
        'UPDATE judgment_state SET has_new_update = 0 '
        'WHERE source_key = ? AND comic_id = ? AND has_new_update != 0',
        [sourceKey, comicId],
      );
      return database.updatedRows;
    } on JudgmentStorageException {
      rethrow;
    } catch (error) {
      throw JudgmentStorageException(
        'Unable to clear the update flag of one comic',
        error,
      );
    }
  }

  @override
  Future<void> clear() async {
    await ensureOpen();
    try {
      _transaction('clear', () {
        database.execute('DELETE FROM judgment_state');
      });
    } on JudgmentStorageException {
      rethrow;
    } catch (error) {
      throw JudgmentStorageException('Unable to clear judgment state', error);
    }
  }

  @override
  Future<void> close() async {
    if (!_opened) return;
    _opened = false;
    _database?.dispose();
    _database = null;
  }

  JudgmentState _stateFromRow(Row row) {
    final decision = JudgmentConclusionValue.parse(row['last_decision']);
    final reason = JudgmentReasonValue.parse(row['last_reason']);
    final evidence = JudgmentEvidenceValue.parse(row['last_evidence']);
    if (decision == null || reason == null) {
      throw const JudgmentStorageException(
        'stored judgment state has an invalid enum',
      );
    }
    return JudgmentState(
      sourceKey: row['source_key'] as String,
      comicId: row['comic_id'] as String,
      factJson: row['fact_json'] as String?,
      factObservedAtMs: row['fact_observed_at_ms'] as int?,
      evidenceSchema: row['evidence_schema'] as String?,
      lastDecision: decision,
      lastEvidence: evidence,
      lastPreviousValue: row['last_previous_value'] as String?,
      lastCurrentValue: row['last_current_value'] as String?,
      lastReason: reason,
      decidedAtMs: row['decided_at_ms'] as int,
      noCommonStreak: row['no_common_streak'] as int,
      hasNewUpdate: (row['has_new_update'] as int) != 0,
      processedAttemptId: row['processed_attempt_id'] as String?,
      algorithmVersion: row['algorithm_version'] as int?,
    );
  }

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

/// The app-level repository, opened lazily by the judgment service.
final judgmentStateRepository = SqliteJudgmentRepository();
