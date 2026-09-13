import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_event.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';

import 'fakes.dart';

/// Contract: `specs/006-local-follow-up-loop/contracts/judgment-event-v1.md`
/// E2 (granularity), E3 (shape), E4 (payload constraints), E7 (single publisher).
void main() {
  const sourceKey = 'src';
  late InMemoryJudgmentRepository repository;
  late InMemoryScanItemStore scans;
  late FixedClock clock;

  setUp(() {
    repository = InMemoryJudgmentRepository();
    scans = InMemoryScanItemStore();
    clock = FixedClock(DateTime.utc(2026, 9, 10, 12));
  });

  JudgmentService buildService() => JudgmentService(
    repository: repository,
    scanRepository: scans,
    clock: clock.call,
  );

  void addItem(
    String comicId, {
    required ObservationSpec spec,
    String? evidenceSchema,
    int observedAtMs = 1757000000000,
  }) {
    scans.replace(
      spec.toStoredItem(
        sourceKey: sourceKey,
        comicId: comicId,
        evidenceSchema: evidenceSchema,
        observedAtMs: observedAtMs,
      ),
    );
  }

  test(
    'publishes one event per run, with one row per judged identity',
    () async {
      final service = buildService();
      final received = <JudgmentBatchEvent>[];
      final subscription = service.events.listen(received.add);
      addTearDown(subscription.cancel);

      addItem('a', spec: const ObservationSpec(latestChapterId: 'c1'));
      addItem('b', spec: const ObservationSpec(latestChapterId: 'c2'));
      addItem('c', spec: const ObservationSpec(latestChapterId: 'c3'));

      await service.run();
      await Future<void>.delayed(Duration.zero);

      // Batch-level granularity: three identities, ONE event.  A per-row event
      // would be indistinguishable from row-by-row consumption (E2).
      expect(received, hasLength(1));
      expect(received.single.rows, hasLength(3));
      expect(received.single.rows.map((r) => r.comicId).toSet(), {
        'a',
        'b',
        'c',
      });
    },
  );

  test('the payload carries the fields the schedule domain needs', () async {
    final service = buildService();
    final received = <JudgmentBatchEvent>[];
    final subscription = service.events.listen(received.add);
    addTearDown(subscription.cancel);

    const observedAtMs = 1757000123456;
    addItem(
      'a',
      spec: const ObservationSpec(updatedAt: '2026-09-01T00:00:00Z'),
      evidenceSchema: labelB,
      observedAtMs: observedAtMs,
    );

    await service.run();
    await Future<void>.delayed(Duration.zero);

    final row = received.single.rows.single;
    expect(row.sourceKey, sourceKey);
    expect(row.comicId, 'a');
    expect(row.conclusion, JudgmentConclusion.rebaseline);
    expect(row.observedAtMs, observedAtMs);
    expect(row.activityAt, DateTime.utc(2026, 9, 1));
    expect(row.identity, 'src\u0000a');
  });

  test(
    'observedAtMs and activityAt are two different fields and never stand in '
    'for each other',
    () async {
      final service = buildService();
      final received = <JudgmentBatchEvent>[];
      final subscription = service.events.listen(received.add);
      addTearDown(subscription.cancel);

      // The content moved on 2026-09-01; we looked at it on 2026-09-10.
      addItem(
        'a',
        spec: const ObservationSpec(updatedAt: '2026-09-01T00:00:00Z'),
        evidenceSchema: labelB,
        observedAtMs: DateTime.utc(2026, 9, 10).millisecondsSinceEpoch,
      );

      await service.run();
      await Future<void>.delayed(Duration.zero);

      final row = received.single.rows.single;
      expect(
        row.observedAtMs,
        DateTime.utc(2026, 9, 10).millisecondsSinceEpoch,
      );
      expect(row.activityAt, DateTime.utc(2026, 9, 1));
      expect(
        row.observedAtMs,
        isNot(row.activityAt!.millisecondsSinceEpoch),
        reason: 'a single conflated timestamp cannot answer both questions',
      );
    },
  );

  test('activityAt is null when the source declares no time field', () async {
    final service = buildService();
    final received = <JudgmentBatchEvent>[];
    final subscription = service.events.listen(received.add);
    addTearDown(subscription.cancel);

    addItem('a', spec: const ObservationSpec(latestChapterId: 'c1'));

    await service.run();
    await Future<void>.delayed(Duration.zero);

    final row = received.single.rows.single;
    expect(
      row.activityAt,
      isNull,
      reason:
          'null means "the source declares no time field"; filling it with '
          'a clock would hide that and silently change the cold-start cost',
    );
    expect(row.observedAtMs, isNotNull);
  });

  test('no pending observation means no event at all', () async {
    final service = buildService();
    final received = <JudgmentBatchEvent>[];
    final subscription = service.events.listen(received.add);
    addTearDown(subscription.cancel);

    // Nothing stored: an empty run must not publish an empty notification.
    final first = await service.run();
    expect(first.writtenRows, 0);
    await Future<void>.delayed(Duration.zero);
    expect(received, isEmpty);

    // A second run over already-processed evidence is also silent.
    addItem('a', spec: const ObservationSpec(latestChapterId: 'c1'));
    await service.run();
    await Future<void>.delayed(Duration.zero);
    expect(received, hasLength(1));

    final second = await service.run();
    expect(second.writtenRows, 0);
    await Future<void>.delayed(Duration.zero);
    expect(
      received,
      hasLength(1),
      reason:
          'nothing was written, so nothing '
          'is announced',
    );
  });

  test('a failed observation is not published', () async {
    final service = buildService();
    final received = <JudgmentBatchEvent>[];
    final subscription = service.events.listen(received.add);
    addTearDown(subscription.cancel);

    scans.replace(
      ObservationSpec.failureItem(sourceKey: sourceKey, comicId: 'broken'),
    );
    addItem('a', spec: const ObservationSpec(latestChapterId: 'c1'));

    final summary = await service.run();
    await Future<void>.delayed(Duration.zero);

    expect(summary.failed, 1);
    expect(received.single.rows.map((r) => r.comicId), ['a']);
  });

  test('a stale identity is not published', () async {
    final service = buildService();
    final received = <JudgmentBatchEvent>[];
    final subscription = service.events.listen(received.add);
    addTearDown(subscription.cancel);

    addItem('a', spec: const ObservationSpec(latestChapterId: 'c1'));
    addItem('b', spec: const ObservationSpec(latestChapterId: 'c2'));
    // Land a newer observation for `b` between the read and write phases.
    scans.onAfterReadAllItems = () {
      scans.onAfterReadAllItems = null;
      scans.replace(
        const ObservationSpec(
          latestChapterId: 'c2-newer',
        ).toStoredItem(sourceKey: sourceKey, comicId: 'b', attemptId: 'newer'),
      );
    };

    final summary = await service.run();
    await Future<void>.delayed(Duration.zero);

    expect(summary.skippedStale, 1);
    expect(
      received.single.rows.map((r) => r.comicId),
      ['a'],
      reason:
          'a consumer must never be told about a judgment that is not in '
          'the store',
    );
  });

  test('events are not persisted and have no replay', () async {
    final service = buildService();
    addItem('a', spec: const ObservationSpec(latestChapterId: 'c1'));
    await service.run();
    await Future<void>.delayed(Duration.zero);

    // A late subscriber on a broadcast stream sees nothing: this is a runtime
    // notification, not a durable log (E4).  Recomputing is always possible
    // from the durable inputs, so a missed batch is not an unrecoverable state.
    final late = <JudgmentBatchEvent>[];
    final subscription = service.events.listen(late.add);
    addTearDown(subscription.cancel);
    await Future<void>.delayed(Duration.zero);
    expect(late, isEmpty);

    // The judgment state itself did persist.
    expect(await repository.readSnapshot(), hasLength(1));
  });

  test('the event payload carries no observation payload, credentials or '
      'source-private data', () async {
    final service = buildService();
    final received = <JudgmentBatchEvent>[];
    final subscription = service.events.listen(received.add);
    addTearDown(subscription.cancel);

    addItem(
      'a',
      spec: const ObservationSpec(
        updatedAt: '2026-09-01T00:00:00Z',
        latestChapterId: 'secret-chapter',
        chapterCount: 12,
      ),
      evidenceSchema: labelB,
    );

    await service.run();
    await Future<void>.delayed(Duration.zero);

    final row = received.single.rows.single;
    // Only identity, conclusion and the two times cross the boundary (E4).
    expect(row.toString(), isNot(contains('secret-chapter')));
    expect(row.comicId, 'a');
  });
}
