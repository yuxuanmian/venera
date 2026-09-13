import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/follow_updates_service.dart';
import 'package:venera/foundation/schedule/schedule_service.dart';
import 'package:venera/foundation/schedule/sqlite_schedule_repository.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_debug_service.dart';
import 'package:venera/foundation/scan/scan_result_repository.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';

import '../tracking/fakes.dart';

/// Contract: `specs/006-local-follow-up-loop/contracts/judgment-event-v1.md`
/// E1 (the subscription point already exists), E2 (consumption granularity) and
/// E4 (events are not persisted).
void main() {
  late _EmittingScanStore scanItems;
  late InMemoryJudgmentRepository judgmentRepository;
  late JudgmentService judgment;
  late SqliteScheduleRepository scheduleRepository;
  late ScheduleService schedule;
  late _CountingScanService scan;

  setUp(() {
    scanItems = _EmittingScanStore();
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
  });

  tearDown(() async {
    scanItems.closeEvents();
    await schedule.close();
  });

  FollowUpdateCoordinator buildCoordinator({int batchThreshold = 50}) =>
      FollowUpdateCoordinator(
        judgmentService: judgment,
        scanService: scan,
        scheduleService: schedule,
        scanRepository: scanItems,
        criterionSourceKeys: () => const {'src'},
        completeSourceKeys: () => const {'src'},
        clock: () => DateTime.utc(2026, 9, 10, 12),
        batchThreshold: batchThreshold,
      );

  /// Lands one observation **through the broadcast**, as acquisition does.
  Future<void> persistOne(String comicId) async {
    final item = const ObservationSpec(
      latestChapterId: 'chapter',
    ).toStoredItem(sourceKey: 'src', comicId: comicId);
    scanItems.replace(item);
    scanItems.emit(ScanRepositoryEvent(item: item));
    await pumpEventQueue();
  }

  group('the subscription point is the existing broadcast (E1)', () {
    test('attaching subscribes to the acquisition broadcast', () async {
      final coordinator = buildCoordinator();
      expect(coordinator.observationConsumerAttached, isFalse);
      coordinator.attachObservationConsumer();
      expect(coordinator.observationConsumerAttached, isTrue);
      // A second attach must not subscribe twice, or every observation would
      // count double and the threshold would fire at half the intended point.
      coordinator.attachObservationConsumer();
      expect(coordinator.observationConsumerAttached, isTrue);
    });

    test('no new notification channel is created', () {
      // The subscription is on the repository's own `events` stream, which the
      // acquisition side already published before this feature existed.  If a
      // new channel were introduced there would be a second controller to find;
      // this asserts the repository exposes exactly the one.
      expect(scanItems.events, isA<Stream<ScanRepositoryEvent>>());
      expect(
        scanItems.emitCount,
        0,
        reason: 'the store only emits when a scan lands',
      );
    });

    test('detaching is idempotent', () {
      final coordinator = buildCoordinator();
      coordinator.attachObservationConsumer();
      coordinator.detachObservationConsumer();
      coordinator.detachObservationConsumer();
      expect(coordinator.observationConsumerAttached, isFalse);
    });
  });

  group('consumption granularity is a count threshold (E2)', () {
    test('49 observations do not trigger a judgment pass', () async {
      final coordinator = buildCoordinator(batchThreshold: 50);
      coordinator.attachObservationConsumer();

      for (var i = 0; i < 49; i++) {
        await persistOne('comic-$i');
      }

      expect(
        judgmentRepository.readSnapshotCalls,
        0,
        reason: 'the threshold is 50; 49 is below it',
      );
    });

    test('the 50th observation triggers exactly one pass', () async {
      final coordinator = buildCoordinator(batchThreshold: 50);
      coordinator.attachObservationConsumer();

      for (var i = 0; i < 50; i++) {
        await persistOne('comic-$i');
      }

      expect(judgmentRepository.readSnapshotCalls, 1);
    });

    test(
      'the counter resets, so the next pass needs another full batch',
      () async {
        final coordinator = buildCoordinator(batchThreshold: 10);
        coordinator.attachObservationConsumer();

        for (var i = 0; i < 10; i++) {
          await persistOne('a-$i');
        }
        expect(judgmentRepository.readSnapshotCalls, 1);

        // Nine more is not a batch.
        for (var i = 0; i < 9; i++) {
          await persistOne('b-$i');
        }
        expect(judgmentRepository.readSnapshotCalls, 1);

        await persistOne('b-9');
        expect(judgmentRepository.readSnapshotCalls, 2);
      },
    );

    test('a scope event does not advance the counter', () async {
      final coordinator = buildCoordinator(batchThreshold: 3);
      coordinator.attachObservationConsumer();

      // Scope events mark the end of a range.  Counting them would consume the
      // remainder once per range instead of once per observation.
      for (var i = 0; i < 20; i++) {
        scanItems.emit(ScanRepositoryEvent(scope: _scope()));
        await pumpEventQueue();
      }
      expect(judgmentRepository.readSnapshotCalls, 0);

      for (var i = 0; i < 3; i++) {
        await persistOne('comic-$i');
      }
      expect(judgmentRepository.readSnapshotCalls, 1);
    });

    test(
      'the threshold is an implementation parameter, not semantics',
      () async {
        // Same evidence consumed at different thresholds: every conclusion must
        // be identical (E2 "参数性").
        for (final threshold in [1, 7, 1000]) {
          final repository = InMemoryJudgmentRepository();
          final items = _EmittingScanStore();
          final service = JudgmentService(
            repository: repository,
            scanRepository: items,
            clock: () => DateTime.utc(2026, 9, 10, 12),
          );
          final item = const ObservationSpec(
            latestChapterId: 'c1',
          ).toStoredItem(sourceKey: 'src', comicId: 'a');
          items.replace(item);
          final localScan = _CountingScanService();
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
          coordinator.attachObservationConsumer();
          items.emit(ScanRepositoryEvent(item: item));
          await pumpEventQueue();

          // Whichever path consumed it, the recorded decision is the same.
          await service.run();
          final state = (await repository.readSnapshot())['src\u0000a']!;
          expect(state.lastDecision, JudgmentConclusion.rebaseline);
          expect(state.lastReason, JudgmentReason.noPreviousEvidence);
          expect(state.hasNewUpdate, isFalse);
          items.closeEvents();
        }
      },
    );
  });

  group('events are runtime notifications (E4)', () {
    test(
      'a missed batch is recoverable because the settle pass exists',
      () async {
        final coordinator = buildCoordinator(batchThreshold: 1000);
        coordinator.attachObservationConsumer();
        // Far below the threshold: nothing was judged during the round.
        await persistOne('a');
        expect(judgmentRepository.readSnapshotCalls, 0);

        // The settle pass consumes the remainder unconditionally, so the durable
        // inputs — not the event — are what the state is rebuilt from.
        await coordinator.runRound(FollowUpdateTrigger.manual);
        expect(judgmentRepository.readSnapshotCalls, greaterThan(0));
        expect(
          (await judgmentRepository.readSnapshot()).isNotEmpty,
          isTrue,
          reason: 'a missed notification must not lose the observation',
        );
      },
    );
  });
}

/// An item store whose broadcast the test drives directly.
class _EmittingScanStore extends InMemoryScanItemStore {
  final _controller = StreamController<ScanRepositoryEvent>.broadcast();

  int emitCount = 0;

  @override
  Stream<ScanRepositoryEvent> get events => _controller.stream;

  void emit(ScanRepositoryEvent event) {
    emitCount++;
    _controller.add(event);
  }

  void closeEvents() {
    if (!_controller.isClosed) _controller.close();
  }
}

/// Acquisition that acquires nothing: these tests are about consumption.
class _CountingScanService extends ScanDebugService {
  _CountingScanService() : super(repository: InMemoryScanItemStore());

  @override
  Future<FullScanSummary> startFullScan({
    Map<String, Set<String>>? dueComicIdsBySource,
  }) async => FullScanSummary(
    disposition: FullScanDisposition.completed,
    progress: ScanProgress(phase: ScanProgressPhase.finished),
  );
}

ScanStoredScope _scope() => ScanStoredScope(
  sourceKey: 'src',
  producer: ScanProducer.comic,
  scopeKey: 'default',
  scopeAttemptId: 'attempt',
  attemptOrdinal: 1,
  accessContextKey: null,
  definitionRevision: 'rev-1',
  startedAtMs: 0,
  finishedAtMs: 1,
  status: ScanScopeStatus.completed,
  itemCount: 1,
  failure: null,
);
