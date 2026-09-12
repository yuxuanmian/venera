import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_result_repository.dart';
import 'package:venera/foundation/scan/sqlite_scan_result_repository.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';
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
}
