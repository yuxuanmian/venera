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

/// Contract: FR-035 (update flags) and — since 007 — FR-009 / FR-010.
///
/// The upgrade path must not lose a flagged comic and must not touch its source.
/// 007 removed the second half of the migration (the manual-preference and
/// scheduler-column copy into `schedule_state`) because that half was **lazily
/// destructive**: a re-run overwrote live schedule rows with old values and
/// `activityAtMs = null`.  The tests below pin both halves of that statement:
/// what the migration still does, and what it must never do again.
void main() {
  late Directory tempDir;
  late SqliteJudgmentRepository judgment;
  late SqliteScheduleRepository schedule;
  late NetworkFavoriteCacheManager cache;
  late Object? previousEnabledSources;

  /// One legacy row, in the shape `comic_check_state` still holds and the
  /// migration still reads: `(sourceKey, comicId, hasNewUpdate)`.
  LegacyFollowUpRow legacy({
    required String comicId,
    bool hasNewUpdate = false,
    String sourceKey = 'src',
  }) => LegacyFollowUpRow(
    sourceKey: sourceKey,
    comicId: comicId,
    hasNewUpdate: hasNewUpdate,
  );

  FollowUpMigration buildMigration(List<LegacyFollowUpRow> rows) =>
      FollowUpMigration(
        judgmentRepository: judgment,
        metadataStore: cache,
        source: () async => rows,
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

  /// One live schedule row, all seven columns set, so a blind overwrite is
  /// visible in every field rather than only in `next_at`.
  Future<void> seedLiveSchedule(String comicId) async {
    await schedule.ensureOpen();
    await schedule.applyBatch([
      ScheduleState(
        sourceKey: 'src',
        comicId: comicId,
        nextAtMs: 111,
        activityAtMs: 222,
        autoHotUntilMs: 333,
        manualHotEnabled: true,
        manualHotUntilMs: 444,
        oldScheduleJitterApplied: true,
      ),
    ]);
  }

  setUp(() async {
    previousEnabledSources = appdata.settings['enabledSources'];
    tempDir = Directory.systemTemp.createTempSync('venera-migration-');
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
      tempDir.deleteSync(recursive: true);
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

    test(
      'retention over a mixed population is 100% of the in-scope rows',
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
          reason:
              'every legacy row lands in exactly one bucket: copied, '
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
        final flagged =
            snapshot.values
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
      },
    );

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
      await buildMigration([legacy(comicId: 'one', hasNewUpdate: true)]).run();
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

  /// A compile-time absence cannot be asserted from Dart, so the shape is read
  /// from the source.  Comments are stripped first: this file explains at length
  /// what was removed, and the guard is about **code**, not about prose being
  /// allowed to name the retired types.
  String codeOf(String path) => File(path)
      .readAsStringSync()
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  group('the migration never touches schedule storage (FR-009 / FR-010)', () {
    test('it adds no schedule row when the store is empty', () async {
      await seedJudgment('one');
      expect(await schedule.readAll(), isEmpty);

      await buildMigration([
        legacy(comicId: 'one', hasNewUpdate: true),
        legacy(comicId: 'not-in-target'),
      ]).run();

      expect(
        await schedule.readAll(),
        isEmpty,
        reason:
            '007 removed the schedule half of the migration outright; a '
            'row appearing here means it came back',
      );
    });

    test('it does not overwrite a live schedule row', () async {
      await seedJudgment('one');
      await seedLiveSchedule('one');
      final before = (await schedule.readAll())['src\u0000one']!;

      await buildMigration([legacy(comicId: 'one', hasNewUpdate: true)]).run();

      final after = (await schedule.readAll())['src\u0000one']!;
      expect(after.nextAtMs, before.nextAtMs);
      expect(after.activityAtMs, before.activityAtMs);
      expect(after.autoHotUntilMs, before.autoHotUntilMs);
      expect(after.manualHotEnabled, before.manualHotEnabled);
      expect(after.manualHotUntilMs, before.manualHotUntilMs);
      expect(after.oldScheduleJitterApplied, before.oldScheduleJitterApplied);
    });

    test('a re-run cannot blind-overwrite live schedule data', () async {
      // The registered risk this requirement closes: on a device that already
      // ran the 006 migration, a repeated run used to rewrite `next_at` /
      // `auto_hot_until` from stale legacy values and clear `activity_at`.
      await seedJudgment('one');
      await seedLiveSchedule('one');

      // First run: performed with the marker absent.
      await buildMigration([legacy(comicId: 'one')]).run();
      final afterFirst = (await schedule.readAll())['src\u0000one']!;

      // Force a second, real run (the marker is normally the guard) and prove it
      // still cannot write.
      cache.writeMetadataValue(followUpMigrationKey, 'not-done');
      await buildMigration([legacy(comicId: 'one', hasNewUpdate: true)]).run();

      final afterSecond = (await schedule.readAll())['src\u0000one']!;
      expect(afterSecond.nextAtMs, afterFirst.nextAtMs);
      expect(afterSecond.activityAtMs, afterFirst.activityAtMs);
      expect(afterSecond.autoHotUntilMs, afterFirst.autoHotUntilMs);
      expect(afterSecond.manualHotEnabled, afterFirst.manualHotEnabled);
      expect(afterSecond.manualHotUntilMs, afterFirst.manualHotUntilMs);
      expect(
        afterSecond.oldScheduleJitterApplied,
        afterFirst.oldScheduleJitterApplied,
      );
    });

    test('the manual hot-window columns stay exactly as stored', () async {
      // The columns survive (FR-031: no data is deleted) and their value is
      // whatever was already there — the migration neither enables nor clears
      // them.
      await seedJudgment('on');
      await seedJudgment('off');
      await schedule.ensureOpen();
      await schedule.applyBatch([
        const ScheduleState(
          sourceKey: 'src',
          comicId: 'on',
          manualHotEnabled: true,
          manualHotUntilMs: 987654321,
        ),
        const ScheduleState(sourceKey: 'src', comicId: 'off'),
      ]);

      await buildMigration([
        legacy(comicId: 'on'),
        legacy(comicId: 'off'),
      ]).run();

      final all = await schedule.readAll();
      expect(all['src\u0000on']!.manualHotEnabled, isTrue);
      expect(all['src\u0000on']!.manualHotUntilMs, 987654321);
      expect(all['src\u0000off']!.manualHotEnabled, isFalse);
      expect(all['src\u0000off']!.manualHotUntilMs, isNull);
    });

    test('the migration is structurally unable to write schedule state', () {
      final source = codeOf('lib/foundation/tracking/follow_up_migration.dart');
      expect(source, isNot(contains('ScheduleStateRepository')));
      expect(source, isNot(contains('scheduleRepository')));
      expect(source, isNot(contains('schedule_state')));
      expect(source, isNot(contains('ScheduleState')));
      expect(source, isNot(contains('manualHot')));
      expect(source, isNot(contains('scheduleRowsCopied')));
      expect(source, isNot(contains('scheduleRowsExpired')));
      // The half that must still be there, so this is not a test of an empty
      // file.
      expect(source, contains('judgmentRepository.applyBatch'));
    });

    test('the legacy projection is narrowed to the flag', () {
      // The migration consumes `LegacyFollowUpRow`; if the retired scheduler
      // columns came back to that type, the schedule half could grow back
      // without any test noticing.
      final event = codeOf('lib/foundation/tracking/judgment_event.dart');
      final row = event.substring(
        event.indexOf('class LegacyFollowUpRow'),
        event.indexOf('class JudgmentRowResult'),
      );
      expect(row, contains('hasNewUpdate'));
      expect(row, contains('sourceKey'));
      expect(row, contains('comicId'));
      expect(row, isNot(contains('nextCheckAtMs')));
      expect(row, isNot(contains('autoHotUntilMs')));
      expect(row, isNot(contains('manualHotEnabled')));
      expect(row, isNot(contains('manualHotUntilMs')));

      final favorites = codeOf('lib/foundation/favorites.dart');
      final read = favorites.substring(
        favorites.indexOf('List<LegacyFollowUpRow> readLegacyFollowUpRows()'),
        favorites.indexOf('int countUpdates('),
      );
      expect(read, contains('SELECT source_key, comic_id, has_new_update'));
      expect(read, isNot(contains('next_check_at')));
      expect(read, isNot(contains('auto_hot_until')));
      expect(read, isNot(contains('manual_hot_enabled')));
      expect(read, isNot(contains('manual_hot_until')));
    });

    test('the writer entry point is gone from production code', () {
      expect(
        codeOf('lib/foundation/favorites.dart'),
        isNot(contains('toggleManualHotWindow')),
      );
      for (final path in const [
        'lib/pages/comic_details_page/comic_page.dart',
        'lib/pages/comic_details_page/favorite.dart',
        'lib/pages/follow_updates_page.dart',
      ]) {
        expect(
          codeOf(path),
          isNot(contains('toggleManualHotWindow')),
          reason: '$path must have no manual hot-window write path',
        );
      }
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
        metadataStore: cache,
        source: () async {
          sourceReads++;
          return [legacy(comicId: 'one', hasNewUpdate: true)];
        },
      ).run();

      expect(second.alreadyMigrated, isTrue);
      expect(sourceReads, 0, reason: 'the marker short-circuits the read');
      expect(second.legacyRows, 0);
      expect(second.flagRowsCopied, 0);
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
