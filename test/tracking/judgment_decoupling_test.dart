import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_result_repository.dart';
import 'package:venera/foundation/scan/sqlite_scan_result_repository.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_repository.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';

import 'fakes.dart';

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('venera-decouple-');
  });

  tearDown(() async {
    await tempDirectory.delete(recursive: true);
  });

  String pathOf(String name) =>
      '${tempDirectory.path}${Platform.pathSeparator}$name';

  /// Seeds a real scan database with one observation, then closes it.
  Future<void> seedScanDatabase(String path) async {
    final repository = SqliteScanResultRepository(databasePath: path);
    await repository.ensureOpen();
    final scope = await repository.beginScope(
      sourceKey: 'src',
      producer: ScanProducer.comic,
      scopeKey: 'comic-1',
      definitionRevision: 'rev-1',
    );
    await repository.saveItem(
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
          update: UpdateDescriptor(latestChapterId: 'chapter-1'),
        ),
      ),
    );
    await repository.close();
  }

  test('SC-006: deleting the scan database leaves judgment readable', () async {
    final scanPath = pathOf('scan_results.db');
    final judgmentPath = pathOf('tracking_state.db');
    await seedScanDatabase(scanPath);

    final scans = SqliteScanResultRepository(databasePath: scanPath);
    final judgment = SqliteJudgmentRepository(databasePath: judgmentPath);
    addTearDown(scans.close);
    addTearDown(judgment.close);

    final service = JudgmentService(
      repository: judgment,
      scanRepository: scans,
      clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
    );
    expect((await service.run()).writtenRows, 1);
    final before = await judgment.readFor('src', 'comic-1');
    expect(before, isNotNull);

    // Remove the scan side entirely, then rebuild both sides.
    await scans.close();
    for (final suffix in const ['', '-wal', '-shm']) {
      final file = File('$scanPath$suffix');
      if (file.existsSync()) file.deleteSync();
    }

    final reopenedScans = SqliteScanResultRepository(databasePath: scanPath);
    addTearDown(reopenedScans.close);
    await reopenedScans.ensureOpen();
    // The scan side reports an empty store, not an error.
    expect(await reopenedScans.readAllItems(), isEmpty);

    final reopenedJudgment = SqliteJudgmentRepository(
      databasePath: judgmentPath,
    );
    addTearDown(reopenedJudgment.close);
    await reopenedJudgment.ensureOpen();
    expect(await reopenedJudgment.readFor('src', 'comic-1'), isNotNull);

    // Running judgment over the empty scan store writes nothing.
    final service2 = JudgmentService(
      repository: reopenedJudgment,
      scanRepository: reopenedScans,
      clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
    );
    final summary = await service2.run();
    expect(summary.writtenRows, 0);
  });

  test(
    'SC-006: deleting the judgment database leaves scan evidence intact',
    () async {
      final scanPath = pathOf('scan_results.db');
      final judgmentPath = pathOf('tracking_state.db');
      await seedScanDatabase(scanPath);

      final scans = SqliteScanResultRepository(databasePath: scanPath);
      final judgment = SqliteJudgmentRepository(databasePath: judgmentPath);
      addTearDown(scans.close);
      addTearDown(judgment.close);

      final service = JudgmentService(
        repository: judgment,
        scanRepository: scans,
        clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
      );
      await service.run();

      await judgment.close();
      for (final suffix in const ['', '-wal', '-shm']) {
        final file = File('$judgmentPath$suffix');
        if (file.existsSync()) file.deleteSync();
      }

      // Scan evidence is complete and readable without the judgment database.
      final items = await scans.readAllItems();
      expect(items, hasLength(1));
      expect(items.single.result.comicId, 'comic-1');
      expect(
        items.single.result.observation!.update!.latestChapterId,
        'chapter-1',
      );

      // A rebuilt judgment store starts empty and can rebuild from that evidence.
      final rebuilt = SqliteJudgmentRepository(databasePath: judgmentPath);
      addTearDown(rebuilt.close);
      await rebuilt.ensureOpen();
      expect(await rebuilt.readFor('src', 'comic-1'), isNull);

      final rebuiltService = JudgmentService(
        repository: rebuilt,
        scanRepository: scans,
        clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
      );
      expect((await rebuiltService.run()).writtenRows, 1);
      final state = await rebuilt.readFor('src', 'comic-1');
      expect(state!.lastReason, JudgmentReason.noPreviousEvidence);
    },
  );

  test('clearAllCache does not touch judgment state', () async {
    final scanPath = pathOf('scan_results.db');
    final judgmentPath = pathOf('tracking_state.db');
    await seedScanDatabase(scanPath);

    final scans = SqliteScanResultRepository(databasePath: scanPath);
    final judgment = SqliteJudgmentRepository(databasePath: judgmentPath);
    addTearDown(scans.close);
    addTearDown(judgment.close);
    await JudgmentService(
      repository: judgment,
      scanRepository: scans,
      clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
    ).run();

    final before = await judgment.readFor('src', 'comic-1');

    // The favorites cache has its own database; clearing it must not disturb
    // the judgment store.
    final cache = NetworkFavoriteCacheManager.forTesting();
    await cache.init(
      databasePath: pathOf('favorites.db'),
      migrateLegacy: false,
    );
    addTearDown(cache.close);
    cache.clearAllCache();

    final after = await judgment.readFor('src', 'comic-1');
    expect(after!.factJson, before!.factJson);
    expect(after.processedAttemptId, before.processedAttemptId);
    expect(after.decidedAtMs, before.decidedAtMs);
  });

  test(
    'an unreadable judgment store reports storage failure, not empty',
    () async {
      final scanPath = pathOf('scan_results.db');
      await seedScanDatabase(scanPath);
      final scans = SqliteScanResultRepository(databasePath: scanPath);
      addTearDown(scans.close);

      // A directory where the database file should be makes open() fail.
      final brokenPath = pathOf('broken-dir');
      Directory(brokenPath).createSync();
      final broken = SqliteJudgmentRepository(databasePath: brokenPath);
      addTearDown(broken.close);

      await expectLater(
        JudgmentService(
          repository: broken,
          scanRepository: scans,
          clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
        ).run(),
        throwsA(isA<JudgmentStorageException>()),
      );
    },
  );

  test(
    'FR-041: rows for an unfavorited comic are kept and produce no update',
    () async {
      final scanPath = pathOf('scan_results.db');
      final judgmentPath = pathOf('tracking_state.db');
      await seedScanDatabase(scanPath);
      final scans = SqliteScanResultRepository(databasePath: scanPath);
      final judgment = SqliteJudgmentRepository(databasePath: judgmentPath);
      addTearDown(scans.close);
      addTearDown(judgment.close);

      final service = JudgmentService(
        repository: judgment,
        scanRepository: scans,
        clock: FixedClock(DateTime.utc(2026, 9, 10, 12)).call,
      );
      await service.run();
      final before = await judgment.readFor('src', 'comic-1');

      // "Unfavoriting" only changes the favorites cache; there is no deletion
      // path into either store.
      final cache = NetworkFavoriteCacheManager.forTesting();
      await cache.init(
        databasePath: pathOf('favorites-unfav.db'),
        migrateLegacy: false,
      );
      addTearDown(cache.close);
      cache.clearAllCache();

      final after = await judgment.readFor('src', 'comic-1');
      expect(after, isNotNull);
      expect(after!.factJson, before!.factJson);
      // Nothing new runs, so no new judgment (and no new update) is produced.
      expect((await service.run()).writtenRows, 0);
    },
  );

  test(
    'the judgment database has its own file and no scan dependency',
    () async {
      final judgmentPath = pathOf('tracking_state.db');
      final judgment = SqliteJudgmentRepository(databasePath: judgmentPath);
      addTearDown(judgment.close);
      await judgment.ensureOpen();
      expect(File(judgmentPath).existsSync(), isTrue);

      // No foreign keys and no reference to the scan tables.
      final tables = judgment.database
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((row) => row['name'] as String)
          .toList();
      expect(tables, ['judgment_state']);
      expect(
        judgment.database.select('PRAGMA foreign_key_list(judgment_state)'),
        isEmpty,
      );
    },
  );
}
