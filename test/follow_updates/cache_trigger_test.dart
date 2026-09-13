import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates_service.dart';
import 'package:venera/foundation/schedule/schedule_service.dart';
import 'package:venera/foundation/schedule/schedule_state.dart';
import 'package:venera/foundation/schedule/sqlite_schedule_repository.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_debug_service.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';

import '../tracking/fakes.dart';

/// Contract: `specs/006-local-follow-up-loop/contracts/follow-up-integration.md`
/// F1 — the cache-change trigger is the third of the three triggers, and it
/// MUST use the same range rule as the other two.  FR-007 adds the debounce.
void main() {
  late InMemoryScanItemStore scanItems;
  late InMemoryJudgmentRepository judgmentRepository;
  late JudgmentService judgment;
  late SqliteScheduleRepository scheduleRepository;
  late ScheduleService schedule;
  late _CountingScanService scan;
  late NetworkFavoriteCacheManager cache;
  late Directory tempDir;

  setUp(() async {
    scanItems = InMemoryScanItemStore();
    judgmentRepository = InMemoryJudgmentRepository();
    judgment = JudgmentService(
      repository: judgmentRepository,
      scanRepository: scanItems,
      clock: () => DateTime.utc(2026, 9, 10, 12),
    );
    scheduleRepository = SqliteScheduleRepository(databasePath: ':memory:');
    schedule = ScheduleService(
      repository: scheduleRepository,
      events: judgment.events,
      clock: () => DateTime.utc(2026, 9, 10, 12),
    );
    scan = _CountingScanService();
    // A real directory, not `:memory:`: the cache's init also consults
    // `App.dataPath` for its legacy-migration bookkeeping, and an unset path
    // makes it block rather than fail.
    tempDir = await Directory.systemTemp.createTemp('venera-cache-trigger-');
    App.dataPath = tempDir.path;
    App.cachePath = tempDir.path;
    cache = NetworkFavoriteCacheManager.forTesting();
    await cache.init(
      databasePath: '${tempDir.path}${Platform.pathSeparator}cache.db',
      migrateLegacy: false,
    );
  });

  tearDown(() async {
    await schedule.close();
    cache.close();
    try {
      await tempDir.delete(recursive: true);
    } on PathAccessException {
      // Windows may release a native SQLite handle just after dispose.
    } on PathNotFoundException {
      // Already gone.
    }
  });

  FollowUpdateCoordinator buildCoordinator({
    Duration debounce = const Duration(milliseconds: 20),
  }) => FollowUpdateCoordinator(
    judgmentService: judgment,
    scanService: scan,
    scheduleService: schedule,
    scanRepository: scanItems,
    favoriteCache: cache,
    criterionSourceKeys: () => const {'src'},
    completeSourceKeys: () => const {'src'},
    clock: () => DateTime.utc(2026, 9, 10, 12),
    cacheChangeDebounce: debounce,
  );

  group('the cache-change trigger (F1)', () {
    test('attaching listens to the favorite cache', () {
      final coordinator = buildCoordinator();
      expect(coordinator.cacheListenerAttached, isFalse);
      coordinator.attachObservationConsumer();
      expect(coordinator.cacheListenerAttached, isTrue);
      coordinator.attachObservationConsumer();
      expect(coordinator.cacheListenerAttached, isTrue);
      coordinator.detachObservationConsumer();
      expect(coordinator.cacheListenerAttached, isFalse);
    });

    test('a cache change requests a round', () async {
      final coordinator = buildCoordinator();
      coordinator.attachObservationConsumer();

      cache.notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(scan.calls, hasLength(1));
    });

    test('the trigger uses the same range rule as the other two', () async {
      // One future-scheduled identity and one with no schedule row.
      const nowMs = 1789041600000;
      scanItems.replace(
        const ObservationSpec(
          latestChapterId: 'c1',
        ).toStoredItem(sourceKey: 'src', comicId: 'due-none'),
      );
      scanItems.replace(
        const ObservationSpec(
          latestChapterId: 'c2',
        ).toStoredItem(sourceKey: 'src', comicId: 'future'),
      );
      await scheduleRepository.ensureOpen();
      await scheduleRepository.applyBatch([
        const ScheduleState(
          sourceKey: 'src',
          comicId: 'future',
          nextAtMs: nowMs + 100000,
          activityAtMs: 0,
        ),
      ]);

      final fromCache = buildCoordinator();
      fromCache.attachObservationConsumer();
      cache.notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final cacheDue = scan.calls.single!;

      scan.calls.clear();
      await buildCoordinator().runRound(FollowUpdateTrigger.startup);
      final startupDue = scan.calls.single!;

      expect(
        cacheDue,
        startupDue,
        reason: 'all three triggers share one range rule',
      );
      expect(cacheDue['src'], contains('due-none'));
      expect(cacheDue['src'], isNot(contains('future')));
    });
  });

  group('the debounce (FR-007)', () {
    test('a burst of notifications becomes one round', () async {
      final coordinator = buildCoordinator();
      coordinator.attachObservationConsumer();

      // A full cache writes hundreds of pages and notifies on each.
      for (var i = 0; i < 200; i++) {
        cache.notifyListeners();
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(
        scan.calls,
        hasLength(1),
        reason: 'without coalescing this would be 200 round requests',
      );
    });

    test(
      'notifications spaced beyond the window produce separate rounds',
      () async {
        final coordinator = buildCoordinator(
          debounce: const Duration(milliseconds: 10),
        );
        coordinator.attachObservationConsumer();

        cache.notifyListeners();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        cache.notifyListeners();
        await Future<void>.delayed(const Duration(milliseconds: 60));

        expect(scan.calls, hasLength(2));
      },
    );

    test('the debounce window is an implementation parameter', () async {
      // The only requirement is "a burst becomes one trigger"; the length of
      // the window must not change what is scanned.
      for (final window in [
        const Duration(milliseconds: 5),
        const Duration(milliseconds: 40),
      ]) {
        scan.calls.clear();
        final coordinator = buildCoordinator(debounce: window);
        coordinator.attachObservationConsumer();
        cache.notifyListeners();
        await Future<void>.delayed(window + const Duration(milliseconds: 60));
        expect(scan.calls, hasLength(1), reason: 'for window $window');
        coordinator.detachObservationConsumer();
      }
    });

    test('a pending trigger is cancelled by detaching', () async {
      final coordinator = buildCoordinator(
        debounce: const Duration(seconds: 5),
      );
      coordinator.attachObservationConsumer();

      cache.notifyListeners();
      coordinator.detachObservationConsumer();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        scan.calls,
        isEmpty,
        reason: 'a detached coordinator must not fire a queued round',
      );
    });

    test(
      'a debounced trigger is absorbed while a round is in flight',
      () async {
        final coordinator = buildCoordinator();
        coordinator.attachObservationConsumer();
        scan.hold = true;

        final round = coordinator.runRound(FollowUpdateTrigger.startup);
        await scan.gate.started.future;

        cache.notifyListeners();
        await Future<void>.delayed(const Duration(milliseconds: 60));

        expect(
          scan.calls,
          hasLength(1),
          reason: 'F1.2: the cache trigger is absorbed, not queued',
        );

        scan.gate.release.complete();
        await round;
      },
    );
  });
}

/// Acquisition that records the due set instead of acquiring.
class _CountingScanService extends ScanDebugService {
  _CountingScanService() : super(repository: InMemoryScanItemStore());

  /// One entry per `startFullScan` call: the due set the coordinator computed.
  ///
  /// Nullable and recorded verbatim, for the same reason as the stub in
  /// `manual_check_test.dart`: the acquisition side reads null as "do not
  /// filter" and an empty map as "nothing is due", so a stub that merges the
  /// two cannot tell a working round from one that scans nothing.
  final List<Map<String, Set<String>>?> calls = [];
  bool hold = false;
  final gate = _Gate();

  @override
  Future<FullScanSummary> startFullScan({
    Map<String, Set<String>>? dueComicIdsBySource,
  }) async {
    calls.add(dueComicIdsBySource);
    if (hold) {
      if (!gate.started.isCompleted) gate.started.complete();
      await gate.release.future;
    }
    return FullScanSummary(
      disposition: FullScanDisposition.completed,
      progress: ScanProgress(phase: ScanProgressPhase.finished),
    );
  }
}

class _Gate {
  final started = Completer<void>();
  final release = Completer<void>();
}
