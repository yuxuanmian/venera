import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/follow_update_schedule.dart';
import 'package:venera/foundation/schedule/schedule_service.dart';
import 'package:venera/foundation/schedule/schedule_state.dart';
import 'package:venera/foundation/schedule/sqlite_schedule_repository.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_event.dart';

/// Contract: `specs/006-local-follow-up-loop/contracts/schedule-v1.md` S6.2
/// (the manual window is a user preference, not derived) and S6.3 (the later
/// deadline wins, via the existing `effectiveHotUntil`).
void main() {
  late SqliteScheduleRepository repository;

  setUp(() {
    repository = SqliteScheduleRepository(databasePath: ':memory:');
  });

  tearDown(() async {
    await repository.close();
  });

  JudgmentRowResult row({
    String comicId = 'c1',
    JudgmentConclusion conclusion = JudgmentConclusion.unchanged,
    required int observedAtMs,
    DateTime? activityAt,
  }) => JudgmentRowResult(
    sourceKey: 'src',
    comicId: comicId,
    conclusion: conclusion,
    observedAtMs: observedAtMs,
    activityAt: activityAt,
  );

  int ms(DateTime value) => value.millisecondsSinceEpoch;

  group('manual hot window is a user preference (S6.2)', () {
    // A comic old enough that the ordinary band is *not* the hot interval, so
    // "the window applied" and "the window did not apply" are distinguishable.
    //
    // The baseline goes through `recomputeSchedule` with no schedule row, which
    // is exactly what the subject does minus the preference: both then consume
    // the one-time jitter the same way, so the only difference left is the hot
    // window.  Comparing against `computeNextSchedule` directly would compare a
    // jittered result with an unjittered one.
    final dormant = DateTime.utc(2022, 1, 1);
    final completed = DateTime.utc(2026, 9, 4);
    final now = completed.millisecondsSinceEpoch;
    ScheduleState baseline({ScheduleState? previous}) => recomputeSchedule(
      row: row(observedAtMs: now, activityAt: dormant),
      previous: previous,
    );

    test('the fixture sits in a band the hot window overrides', () {
      final plain = baseline();
      expect(
        plain.nextAtMs! - now,
        isNot(kFollowUpdateHotInterval.inMilliseconds),
        reason: 'pick a dormant comic, or this file proves nothing',
      );
    });

    test(
      'an active manual window shortens the interval with no conclusion',
      () {
        final manualUntil = DateTime.utc(2026, 12, 1);
        final state = recomputeSchedule(
          row: row(observedAtMs: now, activityAt: dormant),
          previous: ScheduleState(
            sourceKey: 'src',
            comicId: 'c1',
            manualHotEnabled: true,
            manualHotUntilMs: ms(manualUntil),
          ),
        );

        expect(
          state.nextAtMs! - now,
          kFollowUpdateHotInterval.inMilliseconds,
          reason:
              'the preference applies regardless of what the conclusion was',
        );
        expect(state.autoHotUntilMs, isNull);
      },
    );

    test('an expired preference stops applying but is not deleted', () {
      // Deadline already in the past relative to the completion time.
      final expiredUntil = DateTime.utc(2026, 1, 1);
      final previous = ScheduleState(
        sourceKey: 'src',
        comicId: 'c1',
        manualHotEnabled: true,
        manualHotUntilMs: ms(expiredUntil),
      );
      final state = recomputeSchedule(
        row: row(observedAtMs: now, activityAt: dormant),
        previous: previous,
      );

      expect(
        state.nextAtMs,
        baseline(previous: previous).nextAtMs,
        reason: 'an expired window must leave the ordinary schedule untouched',
      );
      expect(
        state.nextAtMs! - now,
        isNot(kFollowUpdateHotInterval.inMilliseconds),
        reason: 'an expired window must no longer shorten the interval',
      );
      expect(
        state.manualHotEnabled,
        isTrue,
        reason:
            're-enabling must produce a fresh window, which requires the '
            'preference (and its old deadline) to still be there',
      );
      expect(state.manualHotUntilMs, ms(expiredUntil));
    });

    test('a disabled preference does not apply even with a deadline set', () {
      final state = recomputeSchedule(
        row: row(observedAtMs: now, activityAt: dormant),
        previous: ScheduleState(
          sourceKey: 'src',
          comicId: 'c1',
          manualHotEnabled: false,
          manualHotUntilMs: ms(DateTime.utc(2026, 12, 1)),
        ),
      );
      expect(state.nextAtMs, baseline().nextAtMs);
      expect(
        state.nextAtMs! - now,
        isNot(kFollowUpdateHotInterval.inMilliseconds),
      );
    });
  });

  group('the later of the two windows wins (S6.3)', () {
    test('manual later than automatic', () {
      final now = DateTime.utc(2026, 9, 4);
      final manualUntil = DateTime.utc(2026, 12, 1);
      final autoUntil = now.add(kFollowUpdateHotWindow); // 2026-09-18

      expect(
        effectiveHotUntil(
          autoHotUntil: autoUntil,
          manualHotUntil: manualUntil,
          manualHotEnabled: true,
          now: now,
        ),
        manualUntil,
      );
    });

    test('automatic later than manual', () {
      final now = DateTime.utc(2026, 9, 4);
      final autoUntil = now.add(kFollowUpdateHotWindow);
      final manualUntil = DateTime.utc(2026, 9, 10);

      expect(
        effectiveHotUntil(
          autoHotUntil: autoUntil,
          manualHotUntil: manualUntil,
          manualHotEnabled: true,
          now: now,
        ),
        autoUntil,
      );
    });

    test('only one of them set', () {
      final now = DateTime.utc(2026, 9, 4);
      final only = DateTime.utc(2026, 10, 1);
      expect(
        effectiveHotUntil(
          autoHotUntil: only,
          manualHotEnabled: false,
          now: now,
        ),
        only,
      );
      expect(
        effectiveHotUntil(
          manualHotUntil: only,
          manualHotEnabled: true,
          now: now,
        ),
        only,
      );
    });

    test('an expired automatic window does not win by being later', () {
      final now = DateTime.utc(2026, 9, 4);
      // Already past: not "active", so it cannot be the effective deadline
      // merely because its raw value is larger than nothing.
      final expiredAuto = DateTime.utc(2026, 8, 1);
      expect(
        effectiveHotUntil(
          autoHotUntil: expiredAuto,
          manualHotEnabled: false,
          now: now,
        ),
        isNull,
      );
    });

    test('the stored automatic deadline the schedule service writes is the '
        'completion plus the hot window', () async {
      final observedAt = DateTime.utc(2026, 9, 10).millisecondsSinceEpoch;
      await repository.ensureOpen();
      await repository.applyBatch([
        recomputeSchedule(
          row: row(
            conclusion: JudgmentConclusion.changed,
            observedAtMs: observedAt,
            activityAt: DateTime.utc(2026, 9, 10),
          ),
          previous: null,
        ),
      ]);
      final stored = (await repository.readAll())['src\u0000c1']!;
      expect(
        stored.autoHotUntilMs,
        DateTime.utc(
          2026,
          9,
          10,
        ).add(kFollowUpdateHotWindow).millisecondsSinceEpoch,
      );
    });
  });
}
