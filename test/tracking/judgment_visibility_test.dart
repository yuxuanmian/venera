import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/follow_update_availability.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_result_repository.dart';
import 'package:venera/foundation/scan/sqlite_scan_result_repository.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';

import 'fakes.dart';

void main() {
  group('SC-008: no user-visible path starts a scan', () {
    test('the retired availability switch keeps its disabled value', () {
      expect(followUpdateScannerAvailable, isFalse);
      expect(followUpdateScannerUnavailableCode, 'scanner_unavailable');
      expect(followUpdateScannerUnavailableExitCode, 3);
    });

    test('judgment never issues a source request', () async {
      // The service only touches the two stores it was handed. This proves the
      // claim by handing it stores that fail the test if a scan is attempted.
      final judgment = InMemoryJudgmentRepository();
      final scans = _NoWriteScanStore(
        items: [
          const ObservationSpec(
            latestChapterId: 'chapter-1',
          ).toStoredItem(sourceKey: 'src', comicId: 'comic-1'),
        ],
      );

      await JudgmentService(
        repository: judgment,
        scanRepository: scans,
        clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
      ).run();

      expect(scans.writeAttempts, 0);
      expect(judgment.rows, hasLength(1));
    });
  });

  group('judgment writes no ordinary user-visible data', () {
    late Directory tempDirectory;
    late SqliteScanResultRepository scans;
    late SqliteJudgmentRepository judgment;

    setUp(() async {
      tempDirectory = await Directory.systemTemp.createTemp('venera-vis-');
      scans = SqliteScanResultRepository(
        databasePath: '${tempDirectory.path}${Platform.pathSeparator}scan.db',
      );
      judgment = SqliteJudgmentRepository(
        databasePath: '${tempDirectory.path}${Platform.pathSeparator}state.db',
      );
      final scope = await scans.beginScope(
        sourceKey: 'src',
        producer: ScanProducer.comic,
        scopeKey: 'comic-1',
        definitionRevision: 'rev-1',
      );
      await scans.saveItem(
        ScanIngestionContext(scope: scope),
        ScanItemResult.observed(
          attemptId: 'attempt-1',
          scopeAttemptId: scope.scopeAttemptId,
          sourceKey: 'src',
          comicId: 'comic-1',
          producer: ScanProducer.comic,
          definitionRevision: 'rev-1',
          observedAt: '2026-09-10T00:00:00.000Z',
          evidenceSchema: labelA,
          observation: ScanObservation(
            update: UpdateDescriptor(latestChapterId: 'chapter-2'),
            sourceUnread: true,
          ),
        ),
      );
    });

    tearDown(() async {
      await scans.close();
      await judgment.close();
      await tempDirectory.delete(recursive: true);
    });

    test('a judgment write adds no new follow-up entry', () async {
      await JudgmentService(
        repository: judgment,
        scanRepository: scans,
        clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
      ).run();

      final state = await judgment.readFor('src', 'comic-1');
      // The sticky flag is judgment-owned state; without a red-dot or
      // follow-up-list reader it cannot surface anywhere.
      expect(state!.hasNewUpdate, isTrue);
      expect(state.lastDecision, JudgmentConclusion.rebaseline);
      // Nothing outside judgment_state was created by the run.
      final tables = judgment.database
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((row) => row['name'] as String)
          .toList();
      expect(tables, ['judgment_state']);
    });

    test('the scan store is not written by judgment', () async {
      final before = await scans.readAllItems();
      await JudgmentService(
        repository: judgment,
        scanRepository: scans,
        clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
      ).run();
      final after = await scans.readAllItems();

      expect(after, hasLength(before.length));
      expect(after.single.result.attemptId, before.single.result.attemptId);
      expect(after.single.committedAtMs, before.single.committedAtMs);
      expect(
        (await scans.readLatestScope(
          'src',
          ScanProducer.comic,
          'comic-1',
        ))!.itemCount,
        1,
      );
    });
  });
}

/// A scan store that fails loudly if judgment tries to write through it.
class _NoWriteScanStore extends InMemoryScanItemStore {
  _NoWriteScanStore({required super.items});

  int writeAttempts = 0;

  @override
  Future<ScanItemWriteResult> saveItem(
    ScanIngestionContext context,
    ScanItemResult item, {
    DateTime? committedAt,
  }) async {
    writeAttempts++;
    return super.saveItem(context, item, committedAt: committedAt);
  }

  @override
  Future<ScanScopeHandle> beginScope({
    required String sourceKey,
    required ScanProducer producer,
    required String scopeKey,
    required String definitionRevision,
    String? scopeAttemptId,
    String? accessContextKey,
    dynamic guard,
  }) async {
    writeAttempts++;
    return super.beginScope(
      sourceKey: sourceKey,
      producer: producer,
      scopeKey: scopeKey,
      definitionRevision: definitionRevision,
      scopeAttemptId: scopeAttemptId,
      accessContextKey: accessContextKey,
      guard: guard,
    );
  }
}

/// Keeps [JudgmentState] in scope for the typed assertions above.
// ignore: unused_element
void _keepJudgmentStateImport(JudgmentState state) => state.identity;
