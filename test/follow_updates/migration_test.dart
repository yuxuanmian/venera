import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/schedule/schedule_state.dart';
import 'package:venera/foundation/schedule/sqlite_schedule_repository.dart';
import 'package:venera/foundation/tracking/follow_up_migration.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_event.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';

/// Contract: FR-035 (update flags) and FR-036 (manual preference) — the upgrade
/// path must not lose a flagged comic, must not grant a window the user's own
/// deadline had closed, and must not touch its source.
void main() {
  late Directory tempDir;
  late SqliteJudgmentRepository judgment;
  late SqliteScheduleRepository schedule;
  late NetworkFavoriteCacheManager cache;
  late Object? previousEnabledSources;

  /// One legacy row, in the shape `comic_check_state` still holds.
  LegacyFollowUpRow legacy({
    required String comicId,
    bool hasNewUpdate = false,
    int? nextCheckAtMs,
    int? autoHotUntilMs,
    bool manualHotEnabled = false,
    int? manualHotUntilMs,
    String sourceKey = 'src',
  }) => LegacyFollowUpRow(
    sourceKey: sourceKey,
    comicId: comicId,
    hasNewUpdate: hasNewUpdate,
    nextCheckAtMs: nextCheckAtMs,
    autoHotUntilMs: autoHotUntilMs,
    manualHotEnabled: manualHotEnabled,
    manualHotUntilMs: manualHotUntilMs,
  );

  FollowUpMigration buildMigration(
    List<LegacyFollowUpRow> rows, {
    DateTime? now,
  }) => FollowUpMigration(
    judgmentRepository: judgment,
    scheduleRepository: schedule,
    metadataStore: cache,
    source: () async => rows,
    clock: () => now ?? DateTime.utc(2026, 9, 10, 12),
  );

  /// Seeds one judgment row so the migration has a target to write into.
  Future<void> seedJudgment(String comicId, {bool flagged = false}) async {
    await judgment.ensureOpen();
    await judgment.applyBatch([
      JudgmentState(
        sourceKey: 'src',
        comicId: comicId,
        lastDecision: JudgmentConclusion.unchanged,
        lastReason: JudgmentReason.equal,
        decidedAtMs: 1,
        hasNewUpdate: flagged,
        algorithmVersion: judgmentAlgorithmVersion,
      ),
    ]);
  }

  Future<void> seedSchedule(String comicId, {int? nextAtMs}) async {
    await schedule.ensureOpen();
    await schedule.applyBatch([
      ScheduleState(
        sourceKey: 'src',
        comicId: comicId,
        nextAtMs: nextAtMs,
        activityAtMs: 1,
      ),
    ]);
  }

  setUp(() async {
    previousEnabledSources = appdata.settings['enabledSources'];
    tempDir = await Directory.systemTemp.createTemp('venera-migration-');
    App.dataPath = tempDir.path;
    App.cachePath = tempDir.path;
    cache = NetworkFavoriteCacheManager.forTesting();
    await cache.init(
      databasePath: '${tempDir.path}${Platform.pathSeparator}cache.db',
      migrateLegacy: false,
    );
    judgment = SqliteJudgmentRepository(
      databasePath: '${tempDir.path}${Platform.pathSeparator}state.db',
    );
    schedule = SqliteScheduleRepository(
      databasePath: '${tempDir.path}${Platform.pathSeparator}schedule.db',
    );
  });

  tearDown(() async {
    await judgment.close();
    await schedule.close();
    cache.close();
    appdata.settings['enabledSources'] = previousEnabledSources;
    try {
      await tempDir.delete(recursive: true);
    } on PathAccessException {
      // Windows may release a native SQLite handle just after dispose.
    } on PathNotFoundException {
      // Already gone.
    }
  });

  group('the update flag migrates without loss (FR-035)', () {
    test('a flagged comic stays flagged', () async {
      await seedJudgment('one');
      final report = await buildMigration([
        legacy(comicId: 'one', hasNewUpdate: true),
      ]).run();

      expect(report.flagRowsCopied, 1);
      expect(
        (await judgment.readFor('src', 'one'))!.hasNewUpdate,
        isTrue,
        reason: 'losing this would silently hide an update the user was owed',
      );
    });

    test('retention over a mixed population is 100% of the in-scope rows',
        () async {
      for (final id in const ['a', 'b', 'c', 'd']) {
        await seedJudgment(id);
      }
      // Two flagged in scope, two flagged out of scope, two unflagged.
      final report = await buildMigration([
        legacy(comicId: 'a', hasNewUpdate: true),
        legacy(comicId: 'b'),
        legacy(comicId: 'c', hasNewUpdate: true),
        legacy(comicId: 'd', hasNewUpdate: true),
        legacy(comicId: 'gone-1', hasNewUpdate: true),
        legacy(comicId: 'gone-2'),
      ]).run();

      expect(report.legacyRows, 6);
      expect(
        report.isFullyAccounted,
        isTrue,
        reason: 'every legacy row lands in exactly one bucket: copied, '
            'orphaned, or in scope with nothing to do',
      );
      expect(
        report.flagRowsCopied + report.flagRowsOrphaned,
        lessThanOrEqualTo(report.legacyRows),
      );
      expect(report.flagRowsOrphaned, 2);
      expect(
        report.flagRowsAlreadyClear,
        1,
        reason: 'comic "b" is in scope and unflagged',
      );

      final snapshot = await judgment.readSnapshot();
      final flagged = snapshot.values
          .where((state) => state.hasNewUpdate)
          .map((state) => state.comicId)
          .toList()
        ..sort();
      expect(flagged, ['a', 'c', 'd']);
      expect(
        snapshot.containsKey('src\u0000gone-1'),
        isFalse,
        reason: 'an identity the target does not have MUST NOT be created',
      );
    });

    test('a conflict is resolved with logical OR', () async {
      // Already flagged in judgment state, unflagged in the legacy store: the
      // migration must not lower it.
      await seedJudgment('one', flagged: true);
      await buildMigration([legacy(comicId: 'one')]).run();
      expect(
        (await judgment.readFor('src', 'one'))!.hasNewUpdate,
        isTrue,
        reason: 'the migration only ever raises the flag',
      );
    });

    test('the other judgment columns are untouched', () async {
      await seedJudgment('one');
      final before = (await judgment.readFor('src', 'one'))!;
      await buildMigration([
        legacy(comicId: 'one', hasNewUpdate: true),
      ]).run();
      final after = (await judgment.readFor('src', 'one'))!;

      expect(after.lastDecision, before.lastDecision);
      expect(after.lastReason, before.lastReason);
      expect(after.decidedAtMs, before.decidedAtMs);
      expect(after.factJson, before.factJson);
      expect(after.processedAttemptId, before.processedAttemptId);
      expect(after.algorithmVersion, before.algorithmVersion);
      expect(after.hasNewUpdate, isTrue);
    });
  });

  group('the manual preference migrates, the retired anchors do not (FR-036)',
      () {
    test('an unexpired manual window is preserved', () async {
      await seedSchedule('one');
      final until = DateTime.utc(2026, 12, 1).millisecondsSinceEpoch;
      await buildMigration([
        legacy(
          comicId: 'one',
          manualHotEnabled: true,
          manualHotUntilMs: until,
        ),
      ]).run();

      final state = (await schedule.readAll())['src\u0000one']!;
      expect(state.manualHotEnabled, isTrue);
      expect(state.manualHotUntilMs, until);
    });

    test('an expired manual window is migrated as OFF', () async {
      await seedSchedule('one');
      final expired = DateTime.utc(2026, 1, 1).millisecondsSinceEpoch;
      final report = await buildMigration([
        legacy(
          comicId: 'one',
          manualHotEnabled: true,
          manualHotUntilMs: expired,
        ),
      ]).run();

      final state = (await schedule.readAll())['src\u0000one']!;
      expect(
        state.manualHotEnabled,
        isFalse,
        reason: 'migrating must not grant a window the user let lapse',
      );
      expect(
        state.manualHotUntilMs,
        expired,
        reason: 'the deadline is kept so the user can re-enable from it',
      );
      expect(report.scheduleRowsExpired, 1);
    });

    test('next_at and the automatic window are copied', () async {
      await seedSchedule('one');
      final next = DateTime.utc(2027, 1, 1).millisecondsSinceEpoch;
      final auto = DateTime.utc(2027, 2, 1).millisecondsSinceEpoch;
      await buildMigration([
        legacy(comicId: 'one', nextCheckAtMs: next, autoHotUntilMs: auto),
      ]).run();

      final state = (await schedule.readAll())['src\u0000one']!;
      expect(state.nextAtMs, next);
      expect(state.autoHotUntilMs, auto);
    });

    test('the retired activity anchors are NOT migrated', () async {
      await seedSchedule('one');
      await buildMigration([legacy(comicId: 'one')]).run();

      final state = (await schedule.readAll())['src\u0000one']!;
      expect(
        state.activityAtMs,
        isNull,
        reason: 'the new anchor is derived from the observation; copying '
            'baseline_at / source_activity_at would introduce a second, '
            'disagreeing notion of "when did it move"',
      );
      expect(
        state.oldScheduleJitterApplied,
        isFalse,
        reason: 'the jitter offset is a stable hash of the identity, so '
            're-applying it to an unmarked row yields the same offset',
      );
    });

    test('only identities that already have a schedule row are written',
        () async {
      await seedSchedule('has-row');
      await seedJudgment('judgment-only');
      final report = await buildMigration([
        legacy(comicId: 'has-row', manualHotEnabled: true, manualHotUntilMs: 9),
        legacy(comicId: 'judgment-only', manualHotEnabled: true),
        legacy(comicId: 'nowhere'),
      ]).run();

      final all = await schedule.readAll();
      expect(all.keys, ['src\u0000has-row']);
      expect(report.scheduleRowsCopied, 1);
    });
  });

  group('the migration is one-time and non-destructive', () {
    test('a repeated run does nothing', () async {
      await seedJudgment('one');
      final first = await buildMigration([
        legacy(comicId: 'one', hasNewUpdate: true),
      ]).run();
      expect(first.alreadyMigrated, isFalse);
      expect(first.flagRowsCopied, 1);

      // A second run must return before reading the legacy store at all.
      var sourceReads = 0;
      final second = await FollowUpMigration(
        judgmentRepository: judgment,
        scheduleRepository: schedule,
        metadataStore: cache,
        source: () async {
          sourceReads++;
          return [legacy(comicId: 'one', hasNewUpdate: true)];
        },
      ).run();

      expect(second.alreadyMigrated, isTrue);
      expect(sourceReads, 0, reason: 'the marker short-circuits the read');
    });

    test('the source table is not cleared', () async {
      await seedJudgment('one');
      final rows = [legacy(comicId: 'one', hasNewUpdate: true)];
      await buildMigration(rows).run();

      // The migration reads and copies; emptying the legacy table needs its own
      // storage migration, and a destructive migration would also be
      // unrecoverable on rollback.
      expect(rows, hasLength(1));
      expect(rows.single.hasNewUpdate, isTrue);
    });

    test('existing observations and judgment rows survive', () async {
      await seedJudgment('keep-me');
      await seedJudgment('also-keep');
      final before = await judgment.readSnapshot();

      await buildMigration([legacy(comicId: 'no-such-comic')]).run();

      final after = await judgment.readSnapshot();
      expect(after.length, before.length);
      for (final entry in before.entries) {
        expect(after.containsKey(entry.key), isTrue);
        expect(after[entry.key]!.lastDecision, entry.value.lastDecision);
        expect(after[entry.key]!.decidedAtMs, entry.value.decidedAtMs);
      }
    });

    test('a marker written by a previous run is respected', () async {
      cache.writeMetadataValue(followUpMigrationKey, 'done');
      await seedJudgment('one');

      final report = await buildMigration([
        legacy(comicId: 'one', hasNewUpdate: true),
      ]).run();

      expect(report.alreadyMigrated, isTrue);
      expect((await judgment.readFor('src', 'one'))!.hasNewUpdate, isFalse);
    });
  });
}
