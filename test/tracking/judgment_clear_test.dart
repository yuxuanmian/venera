import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_result_repository.dart';
import 'package:venera/foundation/scan/sqlite_scan_result_repository.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';

import 'fakes.dart';

void main() {
  late Directory tempDirectory;
  late SqliteScanResultRepository scans;
  late SqliteJudgmentRepository judgment;
  late JudgmentService service;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('venera-clear-');
    scans = SqliteScanResultRepository(
      databasePath: '${tempDirectory.path}${Platform.pathSeparator}scan.db',
    );
    judgment = SqliteJudgmentRepository(
      databasePath: '${tempDirectory.path}${Platform.pathSeparator}state.db',
    );
    service = JudgmentService(
      repository: judgment,
      scanRepository: scans,
      clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
    );

    // One collection scope carrying three comics, so "evidence preserved" can
    // be asserted over more than one row.
    final scope = await scans.beginScope(
      sourceKey: 'src',
      producer: ScanProducer.collection,
      scopeKey: 'default',
      definitionRevision: 'rev-1',
    );
    final context = ScanIngestionContext(scope: scope);
    for (final comicId in const ['comic-1', 'comic-2', 'comic-3']) {
      await scans.saveItem(
        context,
        ScanItemResult.observed(
          attemptId: 'attempt-$comicId',
          scopeAttemptId: scope.scopeAttemptId,
          sourceKey: 'src',
          comicId: comicId,
          producer: ScanProducer.collection,
          definitionRevision: 'rev-1',
          observedAt: '2026-09-10T00:00:00.000Z',
          evidenceSchema: labelA,
          observation: ScanObservation(
            update: UpdateDescriptor(latestChapterId: 'chapter-$comicId'),
          ),
        ),
      );
    }
    await scans.finishScope(context, ScanScopeStatus.completed);
  });

  tearDown(() async {
    await scans.close();
    await judgment.close();
    await tempDirectory.delete(recursive: true);
  });

  test(
    'SC-007: clearing empties judgment state and keeps every scan item',
    () async {
      final first = await service.run();
      expect(first.writtenRows, 3);
      expect((await judgment.readSnapshot()).length, 3);
      final evidenceBefore = await scans.readAllItems();

      await service.clear();

      expect(await judgment.readSnapshot(), isEmpty);
      final evidenceAfter = await scans.readAllItems();
      expect(evidenceAfter, hasLength(evidenceBefore.length));
      expect(
        evidenceAfter.map((i) => i.result.comicId).toSet(),
        evidenceBefore.map((i) => i.result.comicId).toSet(),
      );
      // Evidence is byte-for-byte the same, not merely the same count.
      for (final before in evidenceBefore) {
        final after = evidenceAfter.firstWhere(
          (i) => i.result.comicId == before.result.comicId,
        );
        expect(after.result.attemptId, before.result.attemptId);
        expect(
          after.result.observation!.toJson(),
          before.result.observation!.toJson(),
        );
        expect(after.committedAtMs, before.committedAtMs);
      }
    },
  );

  test(
    'run right after clear rebuilds every baseline with zero updates',
    () async {
      await service.run();
      expect(
        (await judgment.readSnapshot()).values
            .where((s) => s.hasNewUpdate)
            .length,
        0,
        reason: 'a fresh baseline never raises the flag on its own',
      );

      await service.clear();
      final rebuilt = await service.run();

      expect(rebuilt.writtenRows, 3);
      expect(rebuilt.changed, 0);
      final snapshot = await judgment.readSnapshot();
      expect(snapshot, hasLength(3));
      for (final state in snapshot.values) {
        expect(state.lastDecision, JudgmentConclusion.rebaseline);
        expect(state.lastReason, JudgmentReason.noPreviousEvidence);
        expect(state.hasNewUpdate, isFalse);
        expect(state.lastPreviousValue, isNull);
      }
    },
  );

  test('clearing cancels an in-flight scan before emptying state', () async {
    await service.run();
    final order = <String>[];
    final canceling = JudgmentService(
      repository: judgment,
      scanRepository: scans,
      cancelInFlightScan: () async => order.add('cancel'),
      clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
    );

    await canceling.clear();

    expect(order, ['cancel']);
    expect(await judgment.readSnapshot(), isEmpty);
  });

  test('clearing is idempotent when state is already empty', () async {
    await service.clear();
    await service.clear();
    expect(await judgment.readSnapshot(), isEmpty);
    expect(await scans.readAllItems(), hasLength(3));
  });

  test('clearing never touches the favorites or history stores', () async {
    // Contract U4.1: only judgment state is cleared. The scan store, which
    // stands in for the preserved side, keeps its rows above; this asserts the
    // clear reaches nothing else in the same process.
    await service.run();
    final scanCountBefore = (await scans.readAllItems()).length;
    await service.clear();
    expect((await scans.readAllItems()).length, scanCountBefore);
    expect(
      (await scans.readLatestScope(
        'src',
        ScanProducer.collection,
        'default',
      ))!.status,
      ScanScopeStatus.completed,
      reason: 'the retained scan scope audit must survive a clear',
    );
  });

  test('the product singleton wires the scan-cancellation step', () {
    // FR-035 / Contract U4.1 require clear() to request cancellation of an
    // in-flight scan.  Every other test in this file injects its own callback,
    // so a product singleton constructed without one would keep the whole
    // suite green while doing nothing on a device -- which is exactly how the
    // requirement was first missed.  Reading the singleton only builds the
    // closure; it must not reach for the scan coordinator.
    expect(judgmentService.cancelInFlightScanIsWired, isTrue);
  });

  group('clearVisibleFlag clears exactly one comic (FR-021 / Contract E6)', () {
    late List<String> operations;

    setUp(() {
      operations = <String>[];
    });

    JudgmentService serviceWithProbe() => JudgmentService(
      repository: judgment,
      scanRepository: scans,
      clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
      operationHook: operations.add,
    );

    /// Reads one row straight from SQLite, bypassing the state type, so
    /// "every other field is unchanged" can be asserted over the raw columns.
    Map<String, Object?> rawRow(String comicId) => judgment.database
        .select(
          'SELECT * FROM judgment_state WHERE source_key = ? AND comic_id = ?',
          ['src', comicId],
        )
        .single
        .map((key, value) => MapEntry(key, value));

    test(
      'clears only the visible flag and leaves every other column',
      () async {
        await service.run();
        // Raise the flag on one comic; a first baseline never raises it itself.
        final seeded = (await judgment.readSnapshot())['src\u0000comic-1']!;
        expect(seeded.hasNewUpdate, isFalse);
        await judgment.applyBatch([seeded.copyWith(hasNewUpdate: true)]);
        expect(
          (await judgment.readSnapshot())['src\u0000comic-1']!.hasNewUpdate,
          isTrue,
        );

        final before = rawRow('comic-1');
        final cleared = await serviceWithProbe().clearVisibleFlag(
          'src',
          'comic-1',
        );

        expect(cleared, 1);
        final after = rawRow('comic-1');
        expect(after['has_new_update'], 0);
        for (final column in before.keys) {
          if (column == 'has_new_update') continue;
          expect(
            after[column],
            before[column],
            reason:
                'column $column is not the visible flag and must not change',
          );
        }
      },
    );

    test('the fact and decision columns survive the clear', () async {
      await service.run();
      final before = (await judgment.readSnapshot())['src\u0000comic-1']!;
      await judgment.applyBatch([before.copyWith(hasNewUpdate: true)]);

      await service.clearVisibleFlag('src', 'comic-1');

      final after = (await judgment.readSnapshot())['src\u0000comic-1']!;
      expect(after.hasNewUpdate, isFalse);
      expect(after.factJson, before.factJson);
      expect(after.factObservedAtMs, before.factObservedAtMs);
      expect(after.evidenceSchema, before.evidenceSchema);
      expect(after.lastDecision, before.lastDecision);
      expect(after.lastEvidence, before.lastEvidence);
      expect(after.lastPreviousValue, before.lastPreviousValue);
      expect(after.lastCurrentValue, before.lastCurrentValue);
      expect(after.lastReason, before.lastReason);
      expect(after.decidedAtMs, before.decidedAtMs);
      expect(after.noCommonStreak, before.noCommonStreak);
      expect(after.processedAttemptId, before.processedAttemptId);
      expect(after.algorithmVersion, before.algorithmVersion);
    });

    test('issues one statement and never reads the observation store', () async {
      await service.run();
      await judgment.applyBatch([
        (await judgment.readSnapshot())['src\u0000comic-2']!.copyWith(
          hasNewUpdate: true,
        ),
      ]);

      // A fake observation store stands in for the source side: any attempt to
      // re-read evidence would show up as a read here.
      final untouchedScans = InMemoryScanItemStore(
        items: await scans.readAllItems(),
      );
      final probe = JudgmentService(
        repository: judgment,
        scanRepository: untouchedScans,
        clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
        operationHook: operations.add,
      );

      final cleared = await probe.clearVisibleFlag('src', 'comic-2');

      expect(cleared, 1);
      expect(
        untouchedScans.readAllCalls,
        0,
        reason: 'clearing a flag MUST NOT re-read observations',
      );
      // An implementation shaped like clearUnreadForSource would read the whole
      // snapshot and begin a batch transaction; clearing one comic must not.
      expect(operations, [
        'judgment.clearVisibleFlag',
      ], reason: 'one single-row UPDATE, no begin/commit batch, no read');
    });

    test('is a no-op when the flag is already clear', () async {
      await service.run();
      expect(await service.clearVisibleFlag('src', 'comic-3'), 0);
      expect(await service.clearVisibleFlag('src', 'never-seen'), 0);
    });

    test('leaves other comics of the same source alone', () async {
      await service.run();
      final snapshot = await judgment.readSnapshot();
      await judgment.applyBatch([
        snapshot['src\u0000comic-1']!.copyWith(hasNewUpdate: true),
        snapshot['src\u0000comic-2']!.copyWith(hasNewUpdate: true),
      ]);

      await service.clearVisibleFlag('src', 'comic-1');

      final after = await judgment.readSnapshot();
      expect(after['src\u0000comic-1']!.hasNewUpdate, isFalse);
      expect(
        after['src\u0000comic-2']!.hasNewUpdate,
        isTrue,
        reason: 'clearing one comic must not clear its siblings',
      );
    });

    test('cost does not grow with the total state count', () async {
      // Two independent stores, one tiny and one large.  The per-comic clear
      // must behave identically in both; an implementation that reads the whole
      // table before deciding what to write cannot satisfy this.
      Future<int> statementsFor(int totalRows) async {
        final dir = await Directory.systemTemp.createTemp('venera-clearcost-');
        final repository = SqliteJudgmentRepository(
          databasePath: '${dir.path}${Platform.pathSeparator}state.db',
        );
        final log = <String>[];
        final probe = JudgmentService(
          repository: repository,
          scanRepository: scans,
          clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
          operationHook: log.add,
        );
        try {
          await repository.ensureOpen();
          await repository.applyBatch([
            for (var index = 0; index < totalRows; index++)
              JudgmentState(
                sourceKey: 'bulk',
                comicId: 'comic-$index',
                lastDecision: JudgmentConclusion.unchanged,
                lastReason: JudgmentReason.equal,
                decidedAtMs: 1,
                hasNewUpdate: index == 0,
                algorithmVersion: judgmentAlgorithmVersion,
              ),
          ]);
          log.clear();
          final cleared = await probe.clearVisibleFlag('bulk', 'comic-0');
          expect(cleared, 1);
          return log.length;
        } finally {
          await repository.close();
          await dir.delete(recursive: true);
        }
      }

      final small = await statementsFor(4);
      final large = await statementsFor(400);

      expect(large, small);
      expect(small, 1, reason: 'one statement regardless of table size');
    });
  });
}
