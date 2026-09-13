import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_result_repository.dart';
import 'package:venera/foundation/scan/sqlite_scan_result_repository.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';

import '../tracking/fakes.dart';

/// Contract: `specs/006-local-follow-up-loop/contracts/follow-up-integration.md`
/// F4 and `contracts/judgment-event-v1.md` E6 — when the visible flag is
/// cleared, and what that clearing costs.
void main() {
  late Directory tempDirectory;
  late SqliteScanResultRepository scans;
  late SqliteJudgmentRepository judgment;
  late JudgmentService service;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('venera-markread-');
    App.dataPath = tempDirectory.path;
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

    final scope = await scans.beginScope(
      sourceKey: 'src',
      producer: ScanProducer.comic,
      scopeKey: 'default',
      definitionRevision: 'rev-1',
    );
    final context = ScanIngestionContext(scope: scope);
    for (final comicId in const ['one', 'two', 'three']) {
      await scans.saveItem(
        context,
        ScanItemResult.observed(
          attemptId: 'attempt-$comicId',
          scopeAttemptId: scope.scopeAttemptId,
          sourceKey: 'src',
          comicId: comicId,
          producer: ScanProducer.comic,
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
    try {
      await tempDirectory.delete(recursive: true);
    } on PathAccessException {
      // Windows may release a native SQLite handle just after dispose.
    }
  });

  /// Raises the flag on one comic, as a real change would.
  Future<void> flag(String comicId) async {
    final state = (await judgment.readSnapshot())['src\u0000$comicId']!;
    await judgment.applyBatch([state.copyWith(hasNewUpdate: true)]);
  }

  group('the clear targets exactly one comic (F4)', () {
    test('clearing one comic leaves its siblings flagged', () async {
      await service.run();
      await flag('one');
      await flag('two');

      final cleared = await service.clearVisibleFlag('src', 'one');

      expect(cleared, 1);
      final snapshot = await judgment.readSnapshot();
      expect(snapshot['src\u0000one']!.hasNewUpdate, isFalse);
      expect(snapshot['src\u0000two']!.hasNewUpdate, isTrue);
      expect(snapshot['src\u0000three']!.hasNewUpdate, isFalse);
    });

    test(
      'the comparison baseline survives, so the next change is still caught',
      () async {
        await service.run();
        await flag('one');
        final before = (await judgment.readSnapshot())['src\u0000one']!;

        await service.clearVisibleFlag('src', 'one');

        final after = (await judgment.readSnapshot())['src\u0000one']!;
        expect(after.factJson, before.factJson);
        expect(after.evidenceSchema, before.evidenceSchema);
        expect(after.processedAttemptId, before.processedAttemptId);
        expect(after.hasNewUpdate, isFalse, reason: 'only the flag changed');
      },
    );

    test(
      'clearing issues no source request and re-reads no observation',
      () async {
        await service.run();
        await flag('one');
        final evidenceBefore = await scans.readAllItems();

        await service.clearVisibleFlag('src', 'one');

        // The observation store is untouched, and its rows are byte-identical:
        // the mark-read path is storage-only.
        final evidenceAfter = await scans.readAllItems();
        expect(evidenceAfter, hasLength(evidenceBefore.length));
        for (final before in evidenceBefore) {
          final after = evidenceAfter.firstWhere(
            (item) => item.result.comicId == before.result.comicId,
          );
          expect(after.result.attemptId, before.result.attemptId);
          expect(
            jsonEncode(after.result.observation!.toJson()),
            jsonEncode(before.result.observation!.toJson()),
          );
        }
      },
    );

    test('clearing is a no-op when the flag is already down', () async {
      await service.run();
      expect(await service.clearVisibleFlag('src', 'one'), 0);
      expect(await service.clearVisibleFlag('src', 'never-seen'), 0);
    });

    test('clearing all of them empties the list source', () async {
      await service.run();
      for (final comicId in const ['one', 'two', 'three']) {
        await flag(comicId);
      }
      for (final comicId in const ['one', 'two', 'three']) {
        await service.clearVisibleFlag('src', comicId);
      }
      expect(
        (await judgment.readSnapshot()).values.where(
          (state) => state.hasNewUpdate,
        ),
        isEmpty,
      );
    });
  });

  group('the cost is per-comic, not per-state-count (E6)', () {
    test('one statement for a small table and for a large one', () async {
      Future<int> statementsFor(int totalRows) async {
        final dir = await Directory.systemTemp.createTemp('venera-cost-');
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
          expect(await probe.clearVisibleFlag('bulk', 'comic-0'), 1);
          return log.length;
        } finally {
          await repository.close();
          await dir.delete(recursive: true);
        }
      }

      final small = await statementsFor(4);
      final large = await statementsFor(400);
      expect(large, small);
      expect(
        small,
        1,
        reason:
            'a read-all + rewrite shape would issue begin/commit and grow '
            'with the table; this runs on every comic open',
      );
    });
  });

  group(
    'the flag is the only list source, so clearing is visible immediately',
    () {
      test('the visible set is exactly the flagged set', () async {
        await service.run();
        await flag('two');

        final flagged = (await judgment.readSnapshot()).values
            .where((state) => state.hasNewUpdate)
            .map((state) => state.comicId)
            .toList();
        expect(flagged, ['two']);

        await service.clearVisibleFlag('src', 'two');
        expect(
          (await judgment.readSnapshot()).values
              .where((state) => state.hasNewUpdate)
              .map((state) => state.comicId),
          isEmpty,
        );
      });

      test('merely reading the store never clears anything (F4)', () async {
        await service.run();
        await flag('one');

        // What the page and the badge do on every build.
        await judgment.readSnapshot();
        await judgment.readFor('src', 'one');

        expect(
          (await judgment.readSnapshot())['src\u0000one']!.hasNewUpdate,
          isTrue,
          reason: 'opening the follow-up page MUST NOT mark anything read',
        );
      });
    },
  );
}
