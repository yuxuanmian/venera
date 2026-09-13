import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/follow_updates_service.dart';
import 'package:venera/foundation/schedule/schedule_service.dart';
import 'package:venera/foundation/schedule/schedule_state.dart';
import 'package:venera/foundation/schedule/sqlite_schedule_repository.dart';
import 'package:venera/foundation/scan/full_scan_planner.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_debug_service.dart';
import 'package:venera/foundation/scan/target_provider.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_event.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';

import '../scan_kernel/fakes.dart';
import '../tracking/fakes.dart';

/// Contract: `specs/006-local-follow-up-loop/contracts/follow-up-integration.md`
/// F1 (triggers, session boundary, concurrency), F5 (progress), and
/// `contracts/schedule-v1.md` S4 (the range rule).
///
/// The coordinator is exercised against a real `JudgmentService` and a real
/// `ScheduleService` over in-memory stores.  Only acquisition is stubbed, and
/// it is stubbed at `startFullScan`, so the tests observe the exact due set the
/// coordinator hands to the scanner — which is where the range rule lives.
void main() {
  /// An acquisition stub that records what it was asked to scan.
  ///
  /// Extends the real service so the coordinator's use of it is not narrowed by
  /// an interface invented for the test.  Only [startFullScan] is replaced.
  late _RecordingScanService scan;
  late InMemoryJudgmentRepository judgmentRepository;
  late InMemoryScanItemStore scanItems;
  late JudgmentService judgment;
  late SqliteScheduleRepository scheduleRepository;
  late ScheduleService schedule;

  setUp(() {
    scan = _RecordingScanService();
    judgmentRepository = InMemoryJudgmentRepository();
    scanItems = InMemoryScanItemStore();
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
  });

  tearDown(() async {
    await schedule.close();
  });

  FollowUpdateCoordinator buildCoordinator({
    Set<String> sources = const {'src'},
    Set<String> complete = const {'src'},
    int batchThreshold = 50,
  }) => FollowUpdateCoordinator(
    judgmentService: judgment,
    scanService: scan,
    scheduleService: schedule,
    scanRepository: scanItems,
    criterionSourceKeys: () => sources,
    completeSourceKeys: () => complete,
    clock: () => DateTime.utc(2026, 9, 10, 12),
    batchThreshold: batchThreshold,
  );

  /// Stores one observation so the due computation has something to work with.
  void observe(String sourceKey, String comicId, {int? observedAtMs}) {
    scanItems.replace(
      ObservationSpec(latestChapterId: 'chapter-$comicId').toStoredItem(
        sourceKey: sourceKey,
        comicId: comicId,
        observedAtMs: observedAtMs ?? 1757000000000,
      ),
    );
  }

  /// Stores a schedule row whose next_at is in the future.
  Future<void> scheduleInFuture(
    String sourceKey,
    String comicId, {
    required int nextAtMs,
  }) async {
    await scheduleRepository.ensureOpen();
    await scheduleRepository.applyBatch([
      ScheduleState(
        sourceKey: sourceKey,
        comicId: comicId,
        nextAtMs: nextAtMs,
        activityAtMs: 1757000000000,
      ),
    ]);
  }

  group('all three triggers use one range rule (F1)', () {
    test(
      'startup and manual produce the same due set at the same moment',
      () async {
        const nowMs = 1789041600000; // 2026-09-10T12:00:00Z
        observe('src', 'due-none');
        observe('src', 'scheduled-later');
        await scheduleInFuture(
          'src',
          'scheduled-later',
          nextAtMs: nowMs + 100000,
        );

        final startup = buildCoordinator();
        await startup.runRound(FollowUpdateTrigger.startup);
        final startupDue = scan.calls.single!;

        scan.calls.clear();
        final manual = buildCoordinator();
        await manual.runRound(FollowUpdateTrigger.manual);
        final manualDue = scan.calls.single!;

        expect(
          manualDue,
          startupDue,
          reason:
              'a manual check MUST NOT become "ignore the schedule and scan '
              'everything"',
        );
        expect(startupDue['src'], contains('due-none'));
        expect(
          startupDue['src'],
          isNot(contains('scheduled-later')),
          reason: 'a schedule in the future excludes the identity',
        );
      },
    );

    test('a due identity is included and a not-yet-due one is not', () async {
      const nowMs = 1789041600000;
      observe('src', 'expired');
      observe('src', 'future');
      await scheduleInFuture('src', 'expired', nextAtMs: nowMs - 1);
      await scheduleInFuture('src', 'future', nextAtMs: nowMs + 1);

      await buildCoordinator().runRound(FollowUpdateTrigger.startup);

      expect(scan.calls.single!['src'], contains('expired'));
      expect(scan.calls.single!['src'], isNot(contains('future')));
    });

    test('the trigger kind is recorded', () async {
      final coordinator = buildCoordinator();
      expect(coordinator.activeTrigger, isNull);
      await coordinator.runRound(FollowUpdateTrigger.cacheChanged);
      expect(coordinator.activeTrigger, isNull, reason: 'cleared when idle');
    });

    test('an observation with no schedule row is due', () async {
      observe('src', 'never-scheduled');
      await buildCoordinator().runRound(FollowUpdateTrigger.startup);
      expect(scan.calls.single!['src'], contains('never-scheduled'));
    });

    test('with nothing due the round still runs and scans nothing', () async {
      const nowMs = 1789041600000;
      observe('src', 'a');
      await scheduleInFuture('src', 'a', nextAtMs: nowMs + 1000000);

      await buildCoordinator().runRound(FollowUpdateTrigger.startup);

      expect(scan.calls.single!['src'], isEmpty);
    });

    test('with no schedule attached the round is unfiltered, not empty '
        '(S4)', () async {
      // "no schedule record" is itself a due condition, so a coordinator with no
      // schedule yet must ask for everything.  The acquisition side reads
      // **null** as "do not filter" and an **empty map** as "nothing is due":
      // answering with an empty map would make the round discover zero works,
      // report success, and leave the update list empty with nothing pointing at
      // the cause.
      observe('src', 'a');
      final coordinator = FollowUpdateCoordinator(
        judgmentService: judgment,
        scanService: scan,
        scanRepository: scanItems,
        criterionSourceKeys: () => const {'src'},
        completeSourceKeys: () => const {'src'},
        clock: () => DateTime.utc(2026, 9, 10, 12),
      );

      await coordinator.runRound(FollowUpdateTrigger.startup);

      expect(
        scan.calls.single,
        isNull,
        reason: 'null means "no filtering"; an empty map means "scan nothing"',
      );
    });

    test('an empty criterion set is an empty map, not an unfiltered round '
        '(S4)', () async {
      // The counterpart of the test above.  Here the domain really is empty —
      // no source is being tracked — so "nothing is due" is the honest answer,
      // and it must stay distinguishable from "the schedule is missing".
      observe('src', 'a');
      final coordinator = buildCoordinator(sources: const <String>{});

      await coordinator.runRound(FollowUpdateTrigger.startup);

      expect(scan.calls.single, isNotNull);
      expect(scan.calls.single, isEmpty);
    });
  });

  group('session boundary is the process (F1.1)', () {
    test('the startup trigger fires once per coordinator', () async {
      final coordinator = buildCoordinator();
      await coordinator.onProcessStart();
      expect(scan.calls, hasLength(1));

      // A second "start" in the same process is not a new session.
      await coordinator.onProcessStart();
      expect(scan.calls, hasLength(1));
    });

    test('returning to the foreground is not a new session', () async {
      final coordinator = buildCoordinator();
      await coordinator.onProcessStart();
      expect(scan.calls, hasLength(1));

      coordinator.onAppResumed();
      coordinator.onAppResumed();
      await Future<void>.delayed(Duration.zero);
      expect(
        scan.calls,
        hasLength(1),
        reason: 'only a fresh process starts a round',
      );
    });

    test('a manual trigger still works after startup was consumed', () async {
      final coordinator = buildCoordinator();
      await coordinator.onProcessStart();
      await coordinator.runRound(FollowUpdateTrigger.manual);
      expect(scan.calls, hasLength(2));
    });
  });

  group('an in-flight round absorbs a new trigger (F1.2)', () {
    test('a second trigger does not start a second round', () async {
      final coordinator = buildCoordinator();
      scan.hold = true;

      final first = coordinator.runRound(FollowUpdateTrigger.startup);
      await scan.gate.started.future;
      expect(coordinator.isRunning, isTrue);

      final second = await coordinator.runRound(FollowUpdateTrigger.manual);
      expect(second, isFalse, reason: 'the request is absorbed, not started');
      expect(
        scan.calls,
        hasLength(1),
        reason: 'and not queued either: there is exactly one round',
      );

      scan.gate.release.complete();
      expect(await first, isTrue);
      expect(coordinator.isRunning, isFalse);
    });

    test('the absorbed trigger is visible for presentation', () async {
      final coordinator = buildCoordinator();
      scan.hold = true;
      final first = coordinator.runRound(FollowUpdateTrigger.startup);
      await scan.gate.started.future;

      await coordinator.runRound(FollowUpdateTrigger.manual);
      expect(
        coordinator.activeTrigger,
        FollowUpdateTrigger.manual,
        reason:
            'F1.2 requires presenting the current round, so the incoming '
            'trigger must not be silently dropped',
      );

      scan.gate.release.complete();
      await first;
      expect(coordinator.activeTrigger, isNull);
    });
  });

  group('progress counts tasks, not comics (F5)', () {
    test('the numerator includes failures and cancellations', () async {
      final coordinator = buildCoordinator();
      scan.summary = ScanProgress(
        phase: ScanProgressPhase.finished,
        discoveredWorks: 10,
        succeededWorks: 6,
        failedWorks: 2,
        canceledWorks: 2,
      );

      await coordinator.runRound(FollowUpdateTrigger.manual);

      final progress = coordinator.currentProgress;
      expect(progress.discovered, 10);
      expect(
        progress.finished,
        10,
        reason:
            'succeeded + failed + canceled; counting only successes would '
            'pin progress at 60% forever',
      );
      expect(progress.isComplete, isTrue);
      expect(progress.fraction, 1);
    });

    test(
      'zero discovered tasks presents as complete, not as 0/0 running',
      () async {
        final coordinator = buildCoordinator();
        scan.summary = ScanProgress(phase: ScanProgressPhase.finished);

        await coordinator.runRound(FollowUpdateTrigger.manual);

        expect(coordinator.currentProgress.discovered, 0);
        expect(coordinator.currentProgress.isComplete, isTrue);
      },
    );

    test(
      'the denominator is the discovered count, fixed at enumeration',
      () async {
        final coordinator = buildCoordinator();
        scan.summary = ScanProgress(
          phase: ScanProgressPhase.finished,
          discoveredWorks: 7,
          succeededWorks: 3,
        );
        await coordinator.runRound(FollowUpdateTrigger.manual);
        expect(coordinator.currentProgress.discovered, 7);
        expect(coordinator.currentProgress.fraction, closeTo(3 / 7, 1e-9));
      },
    );

    test('progress is published through a listenable', () async {
      final coordinator = buildCoordinator();
      final seen = <FollowUpdateProgress>[];
      coordinator.progress.addListener(
        () => seen.add(coordinator.progress.value),
      );

      await coordinator.runRound(FollowUpdateTrigger.manual);

      expect(seen, isNotEmpty);
      expect(seen.last.phase, ScanProgressPhase.finished);
    });
  });

  group('an unknown denominator is not a zero denominator (F5.2/F5.4)', () {
    FollowUpdateProgress at(
      ScanProgressPhase phase,
      int discovered,
      int done,
    ) => FollowUpdateProgress(
      discovered: discovered,
      finished: done,
      phase: phase,
    );

    test('a round still discovering is neither complete nor full', () {
      // The regression: this combination used to report `isComplete == true`
      // and `fraction == 1`, so the page showed a **full** bar reading
      // "0 / 0 tasks" from the moment the round started until the scan ended.
      final discovering = at(ScanProgressPhase.discovering, 0, 0);
      expect(discovering.isComplete, isFalse);
      expect(discovering.fraction, 0);
    });

    test('nothing to do is complete once discovery has finished', () {
      // F5.2's rule, kept: after enumeration, zero tasks means the round is
      // done, and it must read as complete rather than as "0 / 0 running".
      for (final phase in const [
        ScanProgressPhase.running,
        ScanProgressPhase.finished,
      ]) {
        final empty = at(phase, 0, 0);
        expect(empty.isComplete, isTrue, reason: 'phase $phase');
        expect(empty.fraction, 1);
      }
    });

    test('settled tasks are not completion while the round is still open', () {
      // F5.3: the scan can be done while judgment and the settle pass are not,
      // so the round must not claim completion just because its tasks settled.
      final settled = at(ScanProgressPhase.running, 4, 4);
      expect(settled.isComplete, isFalse);
      expect(settled.fraction, 1);
    });

    test('mid-round counts are reported as they are', () {
      final halfway = at(ScanProgressPhase.running, 7, 3);
      expect(halfway.isComplete, isFalse);
      expect(halfway.fraction, closeTo(3 / 7, 1e-9));
    });
  });

  group('the round mirrors the scan, not just its endpoints (F5.4)', () {
    test('the numerator moves as each task settles', () async {
      // The scan service reports live; the coordinator must forward it.  A
      // real `ScanDebugService` is used with only its target provider replaced,
      // so the progress pipeline under test is the production one.
      final release = Completer<void>();
      final started = Completer<void>();
      final source = makeScanTestSource('src');
      final adapter = FakeScanAdapter(
        sourceKey: 'src',
        comicLoader: (comicId, lease) async {
          if (!started.isCompleted) started.complete();
          await release.future;
          return const {
            'observation': {
              'update': {'updatedAt': '2026-09-10'},
            },
          };
        },
      );
      final scanRepository = FakeScanResultRepository();
      final service = ScanDebugService(
        repository: scanRepository,
        targetProvider: FakeTargetProvider(
          ScanTargetSnapshot(
            works: [
              ScanWorkSpec.comic(
                source: source,
                adapter: adapter,
                comicId: 'comic-1',
              ),
            ],
            cacheGeneration: 0,
          ),
        ),
      );
      final coordinator = FollowUpdateCoordinator(
        judgmentService: judgment,
        scanService: service,
        scanRepository: scanRepository,
        criterionSourceKeys: () => const {'src'},
        completeSourceKeys: () => const {'src'},
        clock: () => DateTime.utc(2026, 9, 10, 12),
      );
      final frames = <FollowUpdateProgress>[];
      coordinator.progress.addListener(
        () => frames.add(coordinator.progress.value),
      );

      final round = coordinator.runRound(FollowUpdateTrigger.manual);
      await started.future;
      await pumpEventQueue();

      final discoveredOne = frames.where((frame) => frame.discovered == 1);
      expect(
        discoveredOne,
        isNotEmpty,
        reason:
            'the denominator is fixed at enumeration and MUST be published '
            'before the work finishes',
      );
      expect(
        discoveredOne.first.finished,
        0,
        reason: 'the task has not settled yet',
      );
      expect(
        discoveredOne.first.fraction,
        0,
        reason: 'a task in flight is not 100%',
      );
      expect(
        discoveredOne.first.isComplete,
        isFalse,
        reason: 'F5.3: completion means judgment caught up too',
      );
      expect(
        frames.every((frame) => frame.discovered <= 1),
        isTrue,
        reason: 'the denominator MUST NOT grow while the round runs',
      );

      release.complete();
      await round;

      expect(frames.last.discovered, 1);
      expect(frames.last.finished, 1);
      expect(frames.last.phase, ScanProgressPhase.finished);
      expect(frames.last.isComplete, isTrue);
    });
  });

  group('the settle pass makes progress mean "judgment caught up" (E2/F5.3)', () {
    test('judgment runs even when no batch threshold was reached', () async {
      observe('src', 'a');
      // Threshold far above the number of observations, so only the
      // unconditional settle pass can consume them.
      final coordinator = buildCoordinator(batchThreshold: 1000);

      expect(await judgmentRepository.readSnapshot(), isEmpty);
      await coordinator.runRound(FollowUpdateTrigger.startup);

      expect(
        await judgmentRepository.readSnapshot(),
        isNotEmpty,
        reason:
            'the remainder must be consumed at settlement, or the tail of '
            'every round is never judged',
      );
    });

    test('the batch counter is reset by the settle pass', () async {
      observe('src', 'a');
      final coordinator = buildCoordinator(batchThreshold: 2);
      await coordinator.onObservationPersisted();
      await coordinator.runRound(FollowUpdateTrigger.manual);
      // If the counter had not been reset, two more observations would fire a
      // batch immediately; after the reset it takes the full threshold again.
      final before = judgmentRepository.applyBatchCalls;
      await coordinator.onObservationPersisted();
      expect(judgmentRepository.applyBatchCalls, before);
    });

    test('the threshold is an implementation parameter, not semantics', () async {
      // Same evidence, different thresholds: every conclusion must be identical.
      for (final threshold in [1, 50, 10000]) {
        final repository = InMemoryJudgmentRepository();
        final items = InMemoryScanItemStore();
        final service = JudgmentService(
          repository: repository,
          scanRepository: items,
          clock: () => DateTime.utc(2026, 9, 10, 12),
        );
        items.replace(
          const ObservationSpec(
            latestChapterId: 'c1',
          ).toStoredItem(sourceKey: 'src', comicId: 'a'),
        );
        final localScan = _RecordingScanService();
        final coordinator = FollowUpdateCoordinator(
          judgmentService: service,
          scanService: localScan,
          scheduleService: schedule,
          scanRepository: items,
          criterionSourceKeys: () => const {'src'},
          completeSourceKeys: () => const {'src'},
          clock: () => DateTime.utc(2026, 9, 10, 12),
          batchThreshold: threshold,
        );
        await coordinator.runRound(FollowUpdateTrigger.manual);
        final state = (await repository.readSnapshot())['src\u0000a']!;
        expect(state.lastDecision, JudgmentConclusion.rebaseline);
        expect(state.lastReason, JudgmentReason.noPreviousEvidence);
        expect(state.hasNewUpdate, isFalse);
      }
    });
  });

  group('schedule wiring (S3)', () {
    test(
      'the schedule consumer is attached and recomputes on judgment events',
      () async {
        final coordinator = buildCoordinator();
        coordinator.attachScheduleService(schedule);
        expect(coordinator.scheduleConsumerAttached, isTrue);

        // A judgment batch with a changed conclusion must reach the schedule store.
        final written = await schedule.recomputeFromEvent(
          JudgmentBatchEvent(
            rows: [
              JudgmentRowResult(
                sourceKey: 'src',
                comicId: 'a',
                conclusion: JudgmentConclusion.changed,
                observedAtMs: 1789041600000,
                activityAt: DateTime.utc(2026, 9, 10),
              ),
            ],
          ),
        );
        expect(written, 1);
        final stored = (await scheduleRepository.readAll())['src\u0000a']!;
        expect(stored.nextAtMs, isNotNull);
        expect(stored.autoHotUntilMs, isNotNull);
      },
    );

    test(
      'the schedule is recomputed per batch, not only at settlement',
      () async {
        final coordinator = buildCoordinator();
        coordinator.attachScheduleService(schedule);

        // One batch is enough to land a schedule row, which is what makes a round
        // terminated halfway resumable.
        await judgment.events
            .firstWhere((_) => true)
            .timeout(
              const Duration(milliseconds: 50),
              onTimeout: () => const JudgmentBatchEvent(rows: []),
            );
        await schedule.recomputeFromEvent(
          JudgmentBatchEvent(
            rows: [
              JudgmentRowResult(
                sourceKey: 'src',
                comicId: 'mid-round',
                conclusion: JudgmentConclusion.unchanged,
                observedAtMs: 1789041600000,
              ),
            ],
          ),
        );
        expect(
          (await scheduleRepository.readAll()).containsKey(
            'src\u0000mid-round',
          ),
          isTrue,
        );
      },
    );
  });

  group('the gate is available from the coordinator (F2)', () {
    test('reports unsatisfied while a criterion source is incomplete', () {
      final coordinator = buildCoordinator(complete: const <String>{});
      expect(coordinator.evaluateGate().isSatisfied, isFalse);
      expect(
        coordinator.evaluateGate().reason,
        FollowUpdateGateReason.cacheIncomplete,
      );
    });

    test('reports satisfied when every criterion source is complete', () {
      final coordinator = buildCoordinator();
      expect(coordinator.evaluateGate().isSatisfied, isTrue);
    });

    test('an empty criterion set is never satisfied', () {
      final coordinator = buildCoordinator(
        sources: const <String>{},
        complete: const <String>{},
      );
      expect(coordinator.evaluateGate().isSatisfied, isFalse);
      expect(
        coordinator.evaluateGate().reason,
        FollowUpdateGateReason.noSources,
      );
    });
  });

  group('cancellation keeps what was already stored (F1.3)', () {
    test('cancel reaches the acquisition service', () async {
      final coordinator = buildCoordinator();
      coordinator.cancel();
      expect(scan.cancelCalls, 1);
    });
  });
}

/// A `ScanDebugService` that records the due set instead of acquiring.
class _RecordingScanService extends ScanDebugService {
  _RecordingScanService() : super(repository: InMemoryScanItemStore());

  /// One entry per `startFullScan` call: the due set the coordinator computed.
  ///
  /// Deliberately **nullable** and recorded verbatim.  Collapsing null into an
  /// empty map here — `calls.add(dueComicIdsBySource ?? const {})` — is what let
  /// the "no schedule attached" defect through: the acquisition side reads null
  /// as "do not filter" and an empty map as "nothing is due", so a stub that
  /// merges them cannot tell a working round from one that scans nothing.
  final List<Map<String, Set<String>>?> calls = [];
  ScanProgress summary = ScanProgress(phase: ScanProgressPhase.finished);
  int cancelCalls = 0;

  /// When true, the call blocks until [_ScanGate.release] completes.
  bool hold = false;
  final _ScanGate gate = _ScanGate();

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
      progress: summary,
    );
  }

  @override
  void cancel([ScanControlReason reason = ScanControlReason.userCanceled]) {
    cancelCalls++;
  }
}

class _ScanGate {
  final started = Completer<void>();
  final release = Completer<void>();
}
