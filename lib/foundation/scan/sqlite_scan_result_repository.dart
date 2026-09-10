import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as file_path;
import 'package:sqlite3/sqlite3.dart';

import '../app.dart';
import 'execution_guard.dart';
import 'failure_sanitizer.dart';
import 'models.dart';
import 'observation_codec.dart';
import 'scan_limits.dart';
import 'scan_result_repository.dart';

/// SQLite implementation of the three-table latest-only scan store.
class SqliteScanResultRepository implements ScanResultRepository {
  SqliteScanResultRepository({
    String? databasePath,
    this.limits = const ScanLimits(),
    DateTime Function()? clock,
    void Function(String operation)? operationHook,
  }) : _configuredDatabasePath = databasePath,
       _clock = clock ?? DateTime.now,
       _operationHook = operationHook;

  final String? _configuredDatabasePath;
  final ScanLimits limits;
  final DateTime Function() _clock;
  final void Function(String operation)? _operationHook;
  final _events = StreamController<ScanRepositoryEvent>.broadcast();
  Database? _database;
  String? _dbInstanceId;
  bool _opened = false;

  /// Resolve the app-owned default only when the repository is first opened.
  /// The singleton is imported during app startup, before [App.dataPath] is
  /// initialized.
  String get databasePath =>
      _configuredDatabasePath ??
      file_path.join(App.dataPath, 'scan_results.db');

  @override
  String get dbInstanceId =>
      _dbInstanceId ?? (throw StateError('scan repository is not open'));

  Database get database =>
      _database ?? (throw StateError('scan repository is not open'));

  @override
  Stream<ScanRepositoryEvent> get events => _events.stream;

  @override
  Future<void> ensureOpen() async {
    if (_opened) return;
    final parent = Directory(file_path.dirname(databasePath));
    if (!parent.existsSync()) parent.createSync(recursive: true);
    try {
      _database = sqlite3.open(databasePath);
      database.execute('PRAGMA foreign_keys=ON');
      database.execute('PRAGMA journal_mode=WAL');
      database.execute('PRAGMA synchronous=FULL');
      _createSchema();
      final meta = database.select(
        'SELECT last_ordinal, db_instance_id FROM scan_meta WHERE singleton = 1',
      );
      if (meta.isEmpty) {
        _dbInstanceId = newScanUuidV4();
        database.execute(
          'INSERT INTO scan_meta(singleton, last_ordinal, db_instance_id) VALUES (1, 0, ?)',
          [_dbInstanceId],
        );
      } else {
        _dbInstanceId = meta.first['db_instance_id'] as String;
      }
      final interruptedAt = _nowMs();
      database.execute(
        '''UPDATE scan_scope_state
           SET status = 'interrupted', finished_at_ms = ?, failure_json = NULL
           WHERE status = 'running' ''',
        [interruptedAt],
      );
      _opened = true;
    } catch (error) {
      _database?.dispose();
      _database = null;
      throw ScanStorageException('Unable to open scan result database', error);
    }
  }

  void _createSchema() {
    database.execute('''
      CREATE TABLE IF NOT EXISTS scan_meta (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        last_ordinal INTEGER NOT NULL CHECK (last_ordinal >= 0),
        db_instance_id TEXT NOT NULL
      )
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS scan_scope_state (
        source_key TEXT NOT NULL,
        scope_type TEXT NOT NULL CHECK (scope_type IN ('comic', 'collection')),
        scope_key TEXT NOT NULL,
        scope_attempt_id TEXT NOT NULL UNIQUE,
        attempt_ordinal INTEGER NOT NULL CHECK (attempt_ordinal > 0),
        access_context_key TEXT,
        producer TEXT NOT NULL CHECK (producer IN ('comic', 'collection')),
        definition_revision TEXT NOT NULL,
        started_at_ms INTEGER NOT NULL,
        finished_at_ms INTEGER,
        status TEXT NOT NULL CHECK (status IN ('running', 'completed', 'failed', 'canceled', 'interrupted')),
        item_count INTEGER NOT NULL DEFAULT 0 CHECK (item_count >= 0),
        failure_json TEXT,
        PRIMARY KEY (source_key, scope_type, scope_key),
        CHECK (producer = scope_type),
        CHECK (
          (status = 'running' AND finished_at_ms IS NULL AND failure_json IS NULL) OR
          (status = 'completed' AND finished_at_ms IS NOT NULL AND failure_json IS NULL) OR
          (status = 'failed' AND finished_at_ms IS NOT NULL AND failure_json IS NOT NULL) OR
          (status IN ('canceled', 'interrupted') AND finished_at_ms IS NOT NULL AND failure_json IS NULL)
        )
      )
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS scan_item_state (
        source_key TEXT NOT NULL,
        comic_id TEXT NOT NULL,
        attempt_id TEXT NOT NULL UNIQUE,
        scope_attempt_id TEXT NOT NULL,
        attempt_ordinal INTEGER NOT NULL CHECK (attempt_ordinal > 0),
        access_context_key TEXT,
        producer TEXT NOT NULL CHECK (producer IN ('comic', 'collection')),
        definition_revision TEXT NOT NULL,
        observed_at_ms INTEGER NOT NULL,
        committed_at_ms INTEGER NOT NULL,
        observation_json TEXT,
        failure_json TEXT,
        PRIMARY KEY (source_key, comic_id),
        CHECK ((observation_json IS NOT NULL AND failure_json IS NULL) OR
               (observation_json IS NULL AND failure_json IS NOT NULL))
      )
    ''');
    database.execute(
      'CREATE INDEX IF NOT EXISTS scan_item_scope_idx ON scan_item_state(scope_attempt_id)',
    );
    database.execute('PRAGMA user_version = 1');
  }

  @override
  Future<ScanScopeHandle> beginScope({
    required String sourceKey,
    required ScanProducer producer,
    required String scopeKey,
    required String definitionRevision,
    String? scopeAttemptId,
    String? accessContextKey,
    ScanExecutionGuard? guard,
  }) async {
    await ensureOpen();
    guard?.check();
    _validateIdentity(sourceKey, scopeKey, definitionRevision);
    if (accessContextKey != null) {
      throw const ScanResultConflictException(
        'accessContextKey is not supported in v1',
      );
    }
    final attemptId = scopeAttemptId ?? newScanUuidV4();
    final startedAt = _nowMs();
    late final int ordinal;
    try {
      ordinal = _transaction('beginScope', () {
        final row = database
            .select('SELECT last_ordinal FROM scan_meta WHERE singleton = 1')
            .single;
        final previous = row['last_ordinal'] as int;
        if (previous == 0x7fffffffffffffff) {
          throw const ScanStorageException('scan ordinal exhausted');
        }
        final next = previous + 1;
        database.execute(
          'UPDATE scan_meta SET last_ordinal = ? WHERE singleton = 1',
          [next],
        );
        database.execute(
          '''INSERT INTO scan_scope_state (
               source_key, scope_type, scope_key, scope_attempt_id,
               attempt_ordinal, access_context_key, producer, definition_revision,
               started_at_ms, finished_at_ms, status, item_count, failure_json
             ) VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, NULL, 'running', 0, NULL)
             ON CONFLICT(source_key, scope_type, scope_key) DO UPDATE SET
               scope_attempt_id = excluded.scope_attempt_id,
               attempt_ordinal = excluded.attempt_ordinal,
               access_context_key = NULL,
               producer = excluded.producer,
               definition_revision = excluded.definition_revision,
               started_at_ms = excluded.started_at_ms,
               finished_at_ms = NULL,
               status = 'running',
               item_count = 0,
               failure_json = NULL''',
          [
            sourceKey,
            producer.value,
            scopeKey,
            attemptId,
            next,
            producer.value,
            definitionRevision,
            startedAt,
          ],
        );
        return next;
      });
    } on ScanStorageException {
      rethrow;
    } catch (error) {
      throw ScanStorageException('Unable to begin scan scope', error);
    }
    return ScanScopeHandle(
      sourceKey: sourceKey,
      producer: producer,
      scopeKey: scopeKey,
      scopeAttemptId: attemptId,
      attemptOrdinal: ordinal,
      definitionRevision: definitionRevision,
      accessContextKey: accessContextKey,
      dbInstanceId: dbInstanceId,
    );
  }

  @override
  Future<ScanItemWriteResult> saveItem(
    ScanIngestionContext context,
    ScanItemResult item, {
    DateTime? committedAt,
  }) async {
    await ensureOpen();
    _checkContext(context, item);
    context.guard?.check();
    if (item.accessContextKey != null) {
      throw const ScanResultConflictException(
        'accessContextKey is not supported in v1',
      );
    }
    final observedAt = DateTime.tryParse(item.observedAt);
    if (observedAt == null) {
      throw const ScanResultConflictException('observedAt is invalid');
    }
    final observationJson = item.observation == null
        ? null
        : jsonEncode(item.observation!.toJson());
    final failureJson = item.failure == null
        ? null
        : jsonEncode(
            FailureSanitizer.sanitize(item.failure, limits: limits).toJson(),
          );
    final payloadSize = utf8
        .encode(observationJson ?? failureJson ?? '')
        .length;
    if (payloadSize >
        (observationJson == null
            ? limits.maxFailureJsonBytes
            : limits.maxObservationJsonBytes)) {
      throw const ScanResultConflictException(
        'scan item payload exceeds its limit',
      );
    }
    final commitAt = (committedAt ?? _clock()).millisecondsSinceEpoch;
    late final ScanItemWriteDisposition disposition;
    try {
      disposition = _transaction('saveItem', () {
        final scopeRow = database.select(
          '''SELECT * FROM scan_scope_state
             WHERE source_key = ? AND scope_type = ? AND scope_key = ?''',
          [
            context.scope.sourceKey,
            context.scope.producer.value,
            context.scope.scopeKey,
          ],
        );
        if (scopeRow.isEmpty) {
          throw const ScanResultConflictException('scan scope is missing');
        }
        final scope = scopeRow.single;
        if (scope['scope_attempt_id'] != context.scope.scopeAttemptId ||
            scope['attempt_ordinal'] != context.scope.attemptOrdinal) {
          return ScanItemWriteDisposition.stale;
        }
        final currentRows = database.select(
          'SELECT * FROM scan_item_state WHERE source_key = ? AND comic_id = ?',
          [item.sourceKey, item.comicId],
        );
        if (currentRows.isNotEmpty) {
          final current = currentRows.single;
          final currentOrdinal = current['attempt_ordinal'] as int;
          if (currentOrdinal > context.scope.attemptOrdinal) {
            return ScanItemWriteDisposition.stale;
          }
          if (currentOrdinal == context.scope.attemptOrdinal) {
            final identical =
                current['attempt_id'] == item.attemptId &&
                current['scope_attempt_id'] == item.scopeAttemptId &&
                current['producer'] == item.producer.value &&
                current['definition_revision'] == item.definitionRevision &&
                current['observed_at_ms'] ==
                    observedAt.millisecondsSinceEpoch &&
                current['observation_json'] == observationJson &&
                current['failure_json'] == failureJson;
            if (identical) return ScanItemWriteDisposition.duplicate;
            throw const ScanResultConflictException(
              'same ordinal has a different item payload',
            );
          }
        }
        if (scope['status'] != ScanScopeStatus.running.value) {
          return ScanItemWriteDisposition.stale;
        }
        final attemptRows = database.select(
          'SELECT source_key, comic_id FROM scan_item_state WHERE attempt_id = ?',
          [item.attemptId],
        );
        if (attemptRows.isNotEmpty &&
            (attemptRows.single['source_key'] != item.sourceKey ||
                attemptRows.single['comic_id'] != item.comicId)) {
          throw const ScanResultConflictException(
            'attempt id is already used by another item',
          );
        }
        _operationHook?.call('saveItem.beforeWrite');
        database.execute(
          '''INSERT INTO scan_item_state (
               source_key, comic_id, attempt_id, scope_attempt_id, attempt_ordinal,
               access_context_key, producer, definition_revision, observed_at_ms,
               committed_at_ms, observation_json, failure_json
             ) VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(source_key, comic_id) DO UPDATE SET
               attempt_id = excluded.attempt_id,
               scope_attempt_id = excluded.scope_attempt_id,
               attempt_ordinal = excluded.attempt_ordinal,
               access_context_key = NULL,
               producer = excluded.producer,
               definition_revision = excluded.definition_revision,
               observed_at_ms = excluded.observed_at_ms,
               committed_at_ms = excluded.committed_at_ms,
               observation_json = excluded.observation_json,
               failure_json = excluded.failure_json''',
          [
            item.sourceKey,
            item.comicId,
            item.attemptId,
            item.scopeAttemptId,
            context.scope.attemptOrdinal,
            item.producer.value,
            item.definitionRevision,
            observedAt.millisecondsSinceEpoch,
            commitAt,
            observationJson,
            failureJson,
          ],
        );
        _operationHook?.call('saveItem.beforeScopeCount');
        database.execute(
          '''UPDATE scan_scope_state SET item_count = item_count + 1
             WHERE source_key = ? AND scope_type = ? AND scope_key = ?
               AND scope_attempt_id = ? AND attempt_ordinal = ? AND status = 'running' ''',
          [
            context.scope.sourceKey,
            context.scope.producer.value,
            context.scope.scopeKey,
            context.scope.scopeAttemptId,
            context.scope.attemptOrdinal,
          ],
        );
        return ScanItemWriteDisposition.written;
      });
    } on ScanStorageException {
      rethrow;
    } on ScanResultConflictException {
      rethrow;
    } catch (error) {
      throw ScanStorageException('Unable to save scan item', error);
    }
    if (disposition == ScanItemWriteDisposition.written) {
      final stored = await readLatestItem(item.sourceKey, item.comicId);
      if (stored != null) _events.add(ScanRepositoryEvent(item: stored));
    }
    return ScanItemWriteResult(disposition);
  }

  @override
  Future<ScanScopeWriteResult> finishScope(
    ScanIngestionContext context,
    ScanScopeStatus status, {
    ScanFailure? failure,
    bool allowCanceledAfterControl = false,
    DateTime? finishedAt,
  }) async {
    await ensureOpen();
    if (status == ScanScopeStatus.running ||
        status == ScanScopeStatus.interrupted) {
      throw const ScanResultConflictException('invalid scope terminal status');
    }
    if (!(status == ScanScopeStatus.canceled && allowCanceledAfterControl)) {
      context.guard?.check();
    }
    final safeFailure = status == ScanScopeStatus.failed
        ? FailureSanitizer.sanitize(failure, limits: limits)
        : null;
    final failureJson = safeFailure == null
        ? null
        : jsonEncode(safeFailure.toJson());
    final endAt = (finishedAt ?? _clock()).millisecondsSinceEpoch;
    late final ScanScopeWriteDisposition disposition;
    try {
      disposition = _transaction('finishScope', () {
        final rows = database.select(
          '''SELECT * FROM scan_scope_state
             WHERE source_key = ? AND scope_type = ? AND scope_key = ?''',
          [
            context.scope.sourceKey,
            context.scope.producer.value,
            context.scope.scopeKey,
          ],
        );
        if (rows.isEmpty) return ScanScopeWriteDisposition.stale;
        final current = rows.single;
        if (current['scope_attempt_id'] != context.scope.scopeAttemptId ||
            current['attempt_ordinal'] != context.scope.attemptOrdinal) {
          return ScanScopeWriteDisposition.stale;
        }
        if (current['status'] != ScanScopeStatus.running.value) {
          if (current['status'] == status.value &&
              current['failure_json'] == failureJson) {
            return ScanScopeWriteDisposition.duplicate;
          }
          return ScanScopeWriteDisposition.stale;
        }
        _operationHook?.call('finishScope.beforeWrite');
        database.execute(
          '''UPDATE scan_scope_state SET finished_at_ms = ?, status = ?, failure_json = ?
             WHERE source_key = ? AND scope_type = ? AND scope_key = ?
               AND scope_attempt_id = ? AND attempt_ordinal = ? AND status = 'running' ''',
          [
            endAt,
            status.value,
            failureJson,
            context.scope.sourceKey,
            context.scope.producer.value,
            context.scope.scopeKey,
            context.scope.scopeAttemptId,
            context.scope.attemptOrdinal,
          ],
        );
        return ScanScopeWriteDisposition.finished;
      });
    } on ScanStorageException {
      rethrow;
    } on ScanResultConflictException {
      rethrow;
    } catch (error) {
      throw ScanStorageException('Unable to finish scan scope', error);
    }
    if (disposition == ScanScopeWriteDisposition.finished) {
      final stored = await readMatchingScope(
        context.scope.sourceKey,
        context.scope.producer,
        context.scope.scopeKey,
        context.scope.scopeAttemptId,
      );
      if (stored != null) _events.add(ScanRepositoryEvent(scope: stored));
    }
    return ScanScopeWriteResult(disposition);
  }

  @override
  Future<ScanStoredItem?> readLatestItem(
    String sourceKey,
    String comicId,
  ) async {
    await ensureOpen();
    try {
      final rows = database.select(
        'SELECT * FROM scan_item_state WHERE source_key = ? AND comic_id = ?',
        [sourceKey, comicId],
      );
      return rows.isEmpty ? null : _itemFromRow(rows.single);
    } catch (error) {
      throw ScanStorageException('Unable to read scan item', error);
    }
  }

  @override
  Future<ScanStoredScope?> readMatchingScope(
    String sourceKey,
    ScanProducer producer,
    String scopeKey,
    String scopeAttemptId,
  ) async {
    await ensureOpen();
    try {
      final rows = database.select(
        '''SELECT * FROM scan_scope_state
           WHERE source_key = ? AND scope_type = ? AND scope_key = ? AND scope_attempt_id = ?''',
        [sourceKey, producer.value, scopeKey, scopeAttemptId],
      );
      return rows.isEmpty ? null : _scopeFromRow(rows.single);
    } catch (error) {
      throw ScanStorageException('Unable to read matching scan scope', error);
    }
  }

  @override
  Future<ScanStoredScope?> readScopeByAttemptId(
    String sourceKey,
    ScanProducer producer,
    String scopeAttemptId,
  ) async {
    await ensureOpen();
    try {
      final rows = database.select(
        '''SELECT * FROM scan_scope_state
           WHERE source_key = ? AND scope_type = ? AND scope_attempt_id = ?''',
        [sourceKey, producer.value, scopeAttemptId],
      );
      return rows.isEmpty ? null : _scopeFromRow(rows.single);
    } catch (error) {
      throw ScanStorageException('Unable to read scan scope by attempt', error);
    }
  }

  @override
  Future<ScanStoredScope?> readLatestScope(
    String sourceKey,
    ScanProducer producer,
    String scopeKey,
  ) async {
    await ensureOpen();
    try {
      final rows = database.select(
        '''SELECT * FROM scan_scope_state
           WHERE source_key = ? AND scope_type = ? AND scope_key = ?''',
        [sourceKey, producer.value, scopeKey],
      );
      return rows.isEmpty ? null : _scopeFromRow(rows.single);
    } catch (error) {
      throw ScanStorageException('Unable to read scan scope', error);
    }
  }

  ScanStoredItem _itemFromRow(Row row) {
    final producer = ScanProducerValue.parse(row['producer']);
    if (producer == null) {
      throw const ScanStorageException('stored item has invalid producer');
    }
    final observationJson = row['observation_json'] as String?;
    final failureJson = row['failure_json'] as String?;
    final common = {
      'attemptId': row['attempt_id'],
      'scopeAttemptId': row['scope_attempt_id'],
      'sourceKey': row['source_key'],
      'comicId': row['comic_id'],
      'producer': producer.value,
      'definitionRevision': row['definition_revision'],
      'observedAt': DateTime.fromMillisecondsSinceEpoch(
        row['observed_at_ms'] as int,
        isUtc: true,
      ).toIso8601String(),
    };
    final result = observationJson != null
        ? ScanItemResult.observed(
            attemptId: common['attemptId'] as String,
            scopeAttemptId: common['scopeAttemptId'] as String,
            sourceKey: common['sourceKey'] as String,
            comicId: common['comicId'] as String,
            producer: producer,
            definitionRevision: common['definitionRevision'] as String,
            observedAt: common['observedAt'] as String,
            observation: const ObservationCodec().normalizeObservation(
              jsonDecode(observationJson)['observation'] ??
                  jsonDecode(observationJson),
            ),
          )
        : ScanItemResult.failed(
            attemptId: common['attemptId'] as String,
            scopeAttemptId: common['scopeAttemptId'] as String,
            sourceKey: common['sourceKey'] as String,
            comicId: common['comicId'] as String,
            producer: producer,
            definitionRevision: common['definitionRevision'] as String,
            observedAt: common['observedAt'] as String,
            failure: FailureSanitizer.sanitize(
              jsonDecode(failureJson ?? '{}'),
              limits: limits,
            ),
          );
    return ScanStoredItem(
      result: result,
      attemptOrdinal: row['attempt_ordinal'] as int,
      observedAtMs: row['observed_at_ms'] as int,
      committedAtMs: row['committed_at_ms'] as int,
    );
  }

  ScanStoredScope _scopeFromRow(Row row) {
    final producer = ScanProducerValue.parse(row['producer']);
    final status = ScanScopeStatusValue.parse(row['status']);
    if (producer == null || status == null) {
      throw const ScanStorageException('stored scope has invalid enum');
    }
    final rawFailure = row['failure_json'] as String?;
    return ScanStoredScope(
      sourceKey: row['source_key'] as String,
      producer: producer,
      scopeKey: row['scope_key'] as String,
      scopeAttemptId: row['scope_attempt_id'] as String,
      attemptOrdinal: row['attempt_ordinal'] as int,
      accessContextKey: row['access_context_key'] as String?,
      definitionRevision: row['definition_revision'] as String,
      startedAtMs: row['started_at_ms'] as int,
      finishedAtMs: row['finished_at_ms'] as int?,
      status: status,
      itemCount: row['item_count'] as int,
      failure: rawFailure == null
          ? null
          : FailureSanitizer.sanitize(jsonDecode(rawFailure), limits: limits),
    );
  }

  void _checkContext(ScanIngestionContext context, ScanItemResult item) {
    if (context.scope.dbInstanceId != dbInstanceId) {
      throw const ScanResultConflictException(
        'scan repository instance changed',
      );
    }
    if (item.sourceKey != context.scope.sourceKey ||
        item.scopeAttemptId != context.scope.scopeAttemptId ||
        item.producer != context.scope.producer) {
      throw const ScanResultConflictException(
        'scan item does not match its scope',
      );
    }
  }

  void _validateIdentity(String sourceKey, String scopeKey, String revision) {
    if (sourceKey.isEmpty || scopeKey.isEmpty || revision.isEmpty) {
      throw const ScanResultConflictException(
        'scan identity must not be empty',
      );
    }
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

  int _nowMs() => _clock().millisecondsSinceEpoch;

  @override
  Future<void> close() async {
    if (!_opened) return;
    _opened = false;
    _database?.dispose();
    _database = null;
    _dbInstanceId = null;
    await _events.close();
  }
}

/// The app-level repository is opened lazily by the debug service/UI.
final scanResultRepository = SqliteScanResultRepository();
