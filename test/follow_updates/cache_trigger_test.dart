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
    Set<String> sources = const {'src'},
  }) => FollowUpdateCoordinator(
    followUpdatesEnabledReader: () => true,
    judgmentService: judgment,
    scanService: scan,
    scheduleService: schedule,
    scanRepository: scanItems,
    favoriteCache: cache,
    criterionSourceKeys: () => sources,
    completeSourceKeys: () => sources,
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

  group('the round is scoped to the source that changed (F1.4)', () {
    test('a marked change puts only that source in scope', () async {
      final coordinator = buildCoordinator(sources: const {'src', 'other'});
      coordinator.attachObservationConsumer();

      // A real cache write, attributed to its own source.
      cache.replaceComicMembership('other', 'c1', const ['f']);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(scan.calls, hasLength(1));
      expect(
        scan.scopes.single,
        {'other'},
        reason:
            'one source writing its cache must not put another source in '
            'scope: a collection-type work item carries no comic id, so the '
            'due rule can never drop it',
      );
      expect(scan.labels.single, FollowUpdateTrigger.cacheChanged.name);
    });

    test(
      'an unattributed notification keeps the conservative answer',
      () async {
        final coordinator = buildCoordinator(sources: const {'src', 'other'});
        coordinator.attachObservationConsumer();

        cache.notifyListeners();
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(scan.calls, hasLength(1));
        expect(
          scan.scopes.single,
          isNull,
          reason:
              'a change nobody attributed could have been any source, and the '
              'safe direction is to check rather than to skip',
        );
      },
    );

    test(
      'a changed source outside the criterion set starts no round',
      () async {
        final coordinator = buildCoordinator(sources: const {'src'});
        coordinator.attachObservationConsumer();

        cache.replaceComicMembership('switched-off', 'c1', const ['f']);
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(
          scan.calls,
          isEmpty,
          reason: 'a source that is not tracked cannot be scanned by a change',
        );
        expect(
          cache.hasChangedSourceKeys,
          isFalse,
          reason:
              'the mark is consumed, not left behind to be owed by every later '
              'round',
        );
      },
    );

    test('marks consumed by another reader start no round', () async {
      final coordinator = buildCoordinator();
      coordinator.attachObservationConsumer();

      cache.replaceComicMembership('src', 'c1', const ['f']);
      cache.takeChangedSourceKeys();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(
        scan.calls,
        isEmpty,
        reason: 'the marks are the evidence a round is owed, and they are gone',
      );
    });
  });

  group('a source the running round does not cover is picked up afterwards '
      '(F1.2)', () {
    test('one coalesced follow-up round covers it', () async {
      final coordinator = buildCoordinator(
        sources: const {'src', 'other'},
        debounce: const Duration(milliseconds: 20),
      );
      coordinator.attachObservationConsumer();
      scan.hold = true;

      cache.replaceComicMembership('src', 'c1', const ['f']);
      await scan.gate.started.future;
      expect(scan.scopes, [
        {'src'},
      ]);

      // A second source changes while the first source's round is in flight.
      // Its own debounced trigger is absorbed (F1.2) — but the mark survives,
      // so the work is not lost the way a dropped request would lose it.
      cache.replaceComicMembership('other', 'c2', const ['f']);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(
        scan.scopes,
        hasLength(1),
        reason: 'the in-flight round still absorbs the second trigger',
      );

      scan.hold = false;
      scan.gate.release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(
        scan.scopes,
        [
          {'src'},
          {'other'},
        ],
        reason:
            'exactly one coalesced follow-up round, carrying only the source '
            'the first round could not cover',
      );
    });

    test('a change the running round already covers owes nothing', () async {
      final coordinator = buildCoordinator(sources: const {'src', 'other'});
      coordinator.attachObservationConsumer();
      scan.hold = true;

      // A round covering every source, as startup and manual do.
      final round = coordinator.runRound(FollowUpdateTrigger.startup);
      await scan.gate.started.future;

      cache.replaceComicMembership('other', 'c2', const ['f']);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      scan.hold = false;
      scan.gate.release.complete();
      await round;
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(
        scan.scopes,
        [isNull],
        reason:
            'an unrestricted round covers every source, so a change during it '
            'is not a second round — the startup and manual paths stay at one '
            'round per request',
      );
    });

    test('cancel stops the whole request, not only the round in flight '
        '(F1.3)', () async {
      final coordinator = buildCoordinator(sources: const {'src', 'other'});
      coordinator.attachObservationConsumer();
      scan.hold = true;

      final round = coordinator.runRound(
        FollowUpdateTrigger.manual,
        scopeSourceKeys: const {'src'},
      );
      await scan.gate.started.future;

      // A second source changes, then the user cancels: the owed follow-up
      // round MUST NOT start after the cancel.
      cache.replaceComicMembership('other', 'c2', const ['f']);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      coordinator.cancel();

      scan.hold = false;
      scan.gate.release.complete();
      await round;
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(
        scan.scopes,
        [
          {'src'},
        ],
        reason:
            'cancel means stop: a coalesced follow-up that starts right after '
            'the user asked to stop is the one outcome a cancel must not have',
      );
      expect(scan.cancelCalls, 1);
    });
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

  /// One entry per `startFullScan` call: the sources the round was allowed to
  /// visit (`null` = every source), recorded so a test can prove one source's
  /// cache write does not put another source in scope (Contract F1.4).
  final List<Set<String>?> scopes = [];

  /// One entry per `startFullScan` call: the trigger name the round carried.
  final List<String?> labels = [];

  /// How many times the coordinator asked acquisition to stop (F1.3).
  int cancelCalls = 0;

  bool hold = false;
  final gate = _Gate();

  @override
  Future<FullScanSummary> startFullScan({
    Map<String, Set<String>>? dueComicIdsBySource,
    Set<String>? scopeSourceKeys,
    String? roundLabel,
  }) async {
    calls.add(dueComicIdsBySource);
    scopes.add(scopeSourceKeys);
    labels.add(roundLabel);
    if (hold) {
      if (!gate.started.isCompleted) gate.started.complete();
      await gate.release.future;
    }
    return FullScanSummary(
      disposition: FullScanDisposition.completed,
      progress: ScanProgress(phase: ScanProgressPhase.finished),
    );
  }

  @override
  void cancel([ScanControlReason reason = ScanControlReason.userCanceled]) {
    cancelCalls++;
  }
}

class _Gate {
  final started = Completer<void>();
  final release = Completer<void>();
}
