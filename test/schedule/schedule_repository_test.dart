import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/schedule/schedule_repository.dart';
import 'package:venera/foundation/schedule/schedule_state.dart';
import 'package:venera/foundation/schedule/sqlite_schedule_repository.dart';

/// Parses the `CREATE TABLE schedule_state (...)` block out of the design
/// attachment and returns its column names in declaration order.
///
/// The attachment is a design document, never read at runtime, so nothing else
/// would notice it drifting from the implementation.  Reading it here is the
/// point: the contract and the shipped DDL are compared as text-derived data
/// rather than as two hand-maintained lists that a reviewer must keep in sync.
List<String> _contractColumns() {
  final file = File(
    '../specs/006-local-follow-up-loop/contracts/schedule-state-schema.sql',
  );
  expect(
    file.existsSync(),
    isTrue,
    reason: 'the schedule DDL attachment must exist at ${file.path}',
  );
  final sql = file.readAsStringSync();

  final create = RegExp(
    r'CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+schedule_state\s*\(',
    caseSensitive: false,
  ).firstMatch(sql);
  expect(create, isNotNull, reason: 'attachment must declare schedule_state');

  // Walk to the matching close paren so nested parens in CHECK clauses do not
  // truncate the block.
  final body = StringBuffer();
  var depth = 1;
  for (var i = create!.end; i < sql.length; i++) {
    final char = sql[i];
    if (char == '(') depth++;
    if (char == ')') {
      depth--;
      if (depth == 0) break;
    }
    body.write(char);
  }

  final columns = <String>[];
  for (final rawLine in body.toString().split('\n')) {
    // Strip line comments, then take the first identifier of a definition line.
    final line = rawLine.split('--').first.trim();
    if (line.isEmpty) continue;
    final upper = line.toUpperCase();
    // Table-level constraints are not columns.
    if (upper.startsWith('PRIMARY KEY') ||
        upper.startsWith('CHECK') ||
        upper.startsWith('UNIQUE') ||
        upper.startsWith('FOREIGN KEY')) {
      continue;
    }
    final match = RegExp(r'^([a-z_][a-z0-9_]*)').firstMatch(line);
    if (match == null) continue;
    final name = match.group(1)!;
    if (name.toLowerCase() == 'create') continue;
    columns.add(name);
  }
  return columns;
}

void main() {
  late Directory tempDir;
  late SqliteScheduleRepository repository;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('schedule_repo_test');
    repository = SqliteScheduleRepository(
      databasePath: '${tempDir.path}/schedule_state.db',
    );
  });

  tearDown(() async {
    await repository.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('the declared columns match contracts/state-schema.sql exactly', () {
    test('column set and order equal the attachment', () async {
      await repository.ensureOpen();
      final actual = repository.database
          .select('PRAGMA table_info(schedule_state)')
          .map((row) => row['name'] as String)
          .toList();
      final contract = _contractColumns();

      expect(
        actual,
        equals(contract),
        reason:
            'the shipped DDL and the design attachment must agree column for '
            'column. Update BOTH together, plus ScheduleState and '
            'ownedColumns.',
      );
    });

    test('identity columns are the first two, owned columns the rest', () {
      final contract = _contractColumns();
      expect(contract.take(2).toList(), ['source_key', 'comic_id']);
      expect(
        contract.sublist(2),
        equals(SqliteScheduleRepository.ownedColumns),
        reason:
            'ownedColumns is the update list; a drift silently drops a '
            'column on every recompute',
      );
      expect(SqliteScheduleRepository.ownedColumns, hasLength(6));
      expect(contract, hasLength(8));
    });

    test('user_version is the declared schema version', () async {
      await repository.ensureOpen();
      final version =
          repository.database.select('PRAGMA user_version').single.values.first
              as int;
      expect(version, SqliteScheduleRepository.schemaVersion);
    });
  });

  group('applyBatch', () {
    test('writes rows and is idempotent per identity', () async {
      await repository.ensureOpen();
      final written = await repository.applyBatch([
        const ScheduleState(
          sourceKey: 'a',
          comicId: '1',
          nextAtMs: 1000,
          activityAtMs: 500,
        ),
        const ScheduleState(sourceKey: 'a', comicId: '2', nextAtMs: 2000),
      ]);
      expect(written, 2);

      final snapshot = await repository.readAll();
      expect(snapshot.keys, hasLength(2));
      expect(snapshot['a\u00001']!.nextAtMs, 1000);
      expect(snapshot['a\u00002']!.nextAtMs, 2000);

      // Re-applying the same identity updates rather than duplicating.
      await repository.applyBatch([
        const ScheduleState(
          sourceKey: 'a',
          comicId: '1',
          nextAtMs: 9999,
          activityAtMs: 500,
        ),
      ]);
      final updated = await repository.readAll();
      expect(updated, hasLength(2));
      expect(updated['a\u00001']!.nextAtMs, 9999);
    });

    test('an empty batch is a no-op', () async {
      await repository.ensureOpen();
      expect(await repository.applyBatch(const []), 0);
      expect(await repository.readAll(), isEmpty);
    });

    test('a failing row rolls the whole batch back', () async {
      await repository.ensureOpen();
      // Seed one good row so we can prove the rollback did not leave a partial
      // write of the second batch behind.
      await repository.applyBatch([
        const ScheduleState(sourceKey: 'a', comicId: 'seed', nextAtMs: 1),
      ]);

      await expectLater(
        repository.applyBatch([
          const ScheduleState(sourceKey: 'a', comicId: 'ok', nextAtMs: 2),
          // Enabled with no deadline violates the table CHECK, so the first row
          // of this batch must not survive.
          const ScheduleState(
            sourceKey: 'a',
            comicId: 'bad',
            manualHotEnabled: true,
          ),
        ]),
        throwsA(isA<ScheduleStorageException>()),
      );

      final snapshot = await repository.readAll();
      expect(snapshot.keys, ['a\u0000seed']);
      expect(snapshot.containsKey('a\u0000ok'), isFalse);
    });
  });

  group('CHECK ((manual_hot_enabled = 0) OR (manual_hot_until IS NOT NULL))', () {
    test('rejects enabled without a deadline', () async {
      await repository.ensureOpen();
      expect(
        () => repository.database.execute(
          "INSERT INTO schedule_state (source_key, comic_id, manual_hot_enabled) "
          "VALUES ('a', 'x', 1)",
        ),
        throwsA(isA<SqliteException>()),
      );
    });

    test('accepts enabled with a deadline and disabled without one', () async {
      await repository.ensureOpen();
      addTearDown(() {});
      await repository.applyBatch([
        const ScheduleState(
          sourceKey: 'a',
          comicId: 'on',
          manualHotEnabled: true,
          manualHotUntilMs: 5000,
        ),
        const ScheduleState(
          sourceKey: 'a',
          comicId: 'off',
          manualHotEnabled: false,
        ),
      ]);
      final snapshot = await repository.readAll();
      expect(snapshot['a\u0000on']!.manualHotUntilMs, 5000);
      expect(snapshot['a\u0000off']!.manualHotEnabled, isFalse);
    });

    test('rejects a value outside 0/1', () async {
      await repository.ensureOpen();
      expect(
        () => repository.database.execute(
          "INSERT INTO schedule_state (source_key, comic_id, manual_hot_enabled) "
          "VALUES ('a', 'x', 2)",
        ),
        throwsA(isA<SqliteException>()),
      );
    });
  });

  group('readExpired', () {
    test(
      'returns only the two conditions this store can answer alone',
      () async {
        await repository.ensureOpen();
        await repository.applyBatch([
          // next_at in the future: not expired.
          const ScheduleState(
            sourceKey: 'a',
            comicId: 'future',
            nextAtMs: 5000,
          ),
          // next_at reached: expired.
          const ScheduleState(sourceKey: 'a', comicId: 'past', nextAtMs: 1000),
          // next_at exactly now: expired (<=).
          const ScheduleState(sourceKey: 'a', comicId: 'now', nextAtMs: 2000),
          // next_at null: expired.
          const ScheduleState(sourceKey: 'a', comicId: 'null'),
        ]);

        final expired = await repository.readExpired(2000);
        expect(
          expired.keys.toSet(),
          {'a\u0000past', 'a\u0000now', 'a\u0000null'},
          reason:
              'no schedule record and no observation are merged by the '
              'caller, not here',
        );
      },
    );

    test('now is supplied by the caller', () async {
      await repository.ensureOpen();
      await repository.applyBatch([
        const ScheduleState(sourceKey: 'a', comicId: 'one', nextAtMs: 1000),
      ]);
      expect(await repository.readExpired(999), isEmpty);
      expect(await repository.readExpired(1000), hasLength(1));
    });
  });

  group('clear', () {
    test('deletes every row so all identities become due again', () async {
      await repository.ensureOpen();
      await repository.applyBatch([
        const ScheduleState(sourceKey: 'a', comicId: '1', nextAtMs: 99999),
      ]);
      await repository.clear();
      expect(await repository.readAll(), isEmpty);
    });
  });

  group('persistence', () {
    test('rows survive close and reopen', () async {
      await repository.ensureOpen();
      await repository.applyBatch([
        const ScheduleState(
          sourceKey: 'a',
          comicId: '1',
          nextAtMs: 42,
          activityAtMs: 7,
          autoHotUntilMs: 8,
          manualHotEnabled: true,
          manualHotUntilMs: 9,
          oldScheduleJitterApplied: true,
        ),
      ]);
      await repository.close();

      final reopened = SqliteScheduleRepository(
        databasePath: '${tempDir.path}/schedule_state.db',
      );
      addTearDown(reopened.close);
      final snapshot = await reopened.readAll();
      final state = snapshot['a\u00001']!;
      expect(state.nextAtMs, 42);
      expect(state.activityAtMs, 7);
      expect(state.autoHotUntilMs, 8);
      expect(state.manualHotEnabled, isTrue);
      expect(state.manualHotUntilMs, 9);
      expect(state.oldScheduleJitterApplied, isTrue);
    });
  });
}
