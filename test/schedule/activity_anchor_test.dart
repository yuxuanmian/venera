import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/follow_update_schedule.dart';
import 'package:venera/foundation/schedule/schedule_service.dart';
import 'package:venera/foundation/schedule/schedule_state.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_event.dart';

/// Contract: `specs/006-local-follow-up-loop/contracts/schedule-v1.md` S5
/// (three-tier anchor) and S6 (hot windows).
void main() {
  JudgmentRowResult row({
    String sourceKey = 'src',
    String comicId = 'c1',
    JudgmentConclusion conclusion = JudgmentConclusion.unchanged,
    required int observedAtMs,
    DateTime? activityAt,
  }) => JudgmentRowResult(
    sourceKey: sourceKey,
    comicId: comicId,
    conclusion: conclusion,
    observedAtMs: observedAtMs,
    activityAt: activityAt,
  );

  group('activity anchor three-tier fallback (S5)', () {
    test('tier 1: the content time the source itself declared', () {
      final contentTime = DateTime.utc(2026, 9, 1);
      final state = recomputeSchedule(
        row: row(
          observedAtMs: DateTime.utc(2026, 9, 10).millisecondsSinceEpoch,
          activityAt: contentTime,
        ),
        previous: null,
      );
      expect(state.activityAtMs, contentTime.millisecondsSinceEpoch);
    });

    test(
      'tier 3: the first observation time when the source declares none',
      () {
        final observedAt = DateTime.utc(2026, 9, 10).millisecondsSinceEpoch;
        final state = recomputeSchedule(
          row: row(observedAtMs: observedAt),
          previous: null,
        );
        expect(state.activityAtMs, observedAt);
      },
    );

    test('tier 2: the recorded anchor once one exists', () {
      final recorded = DateTime.utc(2026, 1, 1).millisecondsSinceEpoch;
      final state = recomputeSchedule(
        row: row(
          observedAtMs: DateTime.utc(2026, 9, 10).millisecondsSinceEpoch,
        ),
        previous: ScheduleState(
          sourceKey: 'src',
          comicId: 'c1',
          activityAtMs: recorded,
        ),
      );
      expect(state.activityAtMs, recorded);
    });

    test(
      'using the last check time as the anchor fails this test (S5 MUST NOT)',
      () {
        // A source with no time field, observed twice a year apart.  A naive
        // implementation that anchors on "when we last looked" produces a
        // one-year-younger comic and therefore a faster band — the exact
        // feedback loop S5 forbids.
        final firstObservation = DateTime.utc(
          2026,
          1,
          1,
        ).millisecondsSinceEpoch;
        final first = recomputeSchedule(
          row: row(observedAtMs: firstObservation),
          previous: null,
        );

        final secondObservation = DateTime.utc(
          2026,
          9,
          10,
        ).millisecondsSinceEpoch;
        final second = recomputeSchedule(
          row: row(observedAtMs: secondObservation),
          previous: first,
        );

        expect(
          second.activityAtMs,
          firstObservation,
          reason: 'the anchor MUST NOT move to the later check time',
        );
        expect(
          second.activityAtMs,
          isNot(secondObservation),
          reason: 'anchoring on the check time is the forbidden behaviour',
        );
      },
    );

    test('the anchor does not move forward on later observations', () {
      var state = recomputeSchedule(
        row: row(observedAtMs: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch),
        previous: null,
      );
      final anchor = state.activityAtMs;
      for (var month = 2; month <= 6; month++) {
        state = recomputeSchedule(
          row: row(
            observedAtMs: DateTime.utc(2026, month, 1).millisecondsSinceEpoch,
          ),
          previous: state,
        );
        expect(state.activityAtMs, anchor);
      }
    });

    test('a declared content time does move the anchor', () {
      // Tier 1 is the escape hatch from tier 3's frozen anchor: the source
      // declaring a time field is the documented correct answer, so a real
      // content time must be adopted.
      var state = recomputeSchedule(
        row: row(observedAtMs: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch),
        previous: null,
      );
      expect(
        state.activityAtMs,
        DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
      );

      state = recomputeSchedule(
        row: row(
          observedAtMs: DateTime.utc(2026, 6, 1).millisecondsSinceEpoch,
          activityAt: DateTime.utc(2026, 5, 30),
        ),
        previous: state,
      );
      expect(
        state.activityAtMs,
        DateTime.utc(2026, 5, 30).millisecondsSinceEpoch,
      );
    });

    test('a fresher declared time wins over a recorded anchor', () {
      final state = recomputeSchedule(
        row: row(
          observedAtMs: DateTime.utc(2026, 9, 10).millisecondsSinceEpoch,
          activityAt: DateTime.utc(2026, 9, 9),
        ),
        previous: ScheduleState(
          sourceKey: 'src',
          comicId: 'c1',
          activityAtMs: DateTime.utc(2020, 1, 1).millisecondsSinceEpoch,
        ),
      );
      expect(
        state.activityAtMs,
        DateTime.utc(2026, 9, 9).millisecondsSinceEpoch,
      );
    });
  });

  group('automatic hot window (S6.1)', () {
    test('a "content changed" conclusion sets a 14-day window', () {
      final observedAt = DateTime.utc(2026, 9, 10).millisecondsSinceEpoch;
      final state = recomputeSchedule(
        row: row(
          conclusion: JudgmentConclusion.changed,
          observedAtMs: observedAt,
          activityAt: DateTime.utc(2026, 9, 10),
        ),
        previous: null,
      );
      expect(
        state.autoHotUntilMs,
        DateTime.utc(
          2026,
          9,
          10,
        ).add(kFollowUpdateHotWindow).millisecondsSinceEpoch,
      );
    });

    test('"content unchanged" neither sets nor extends it', () {
      final observedAt = DateTime.utc(2026, 9, 10).millisecondsSinceEpoch;
      final unchanged = recomputeSchedule(
        row: row(
          conclusion: JudgmentConclusion.unchanged,
          observedAtMs: observedAt,
        ),
        previous: null,
      );
      expect(
        unchanged.autoHotUntilMs,
        isNull,
        reason:
            'the window means "this content is active", not "we looked at '
            'it recently"',
      );

      // And a second unchanged observation does not push an existing window out.
      final seeded = recomputeSchedule(
        row: row(
          conclusion: JudgmentConclusion.changed,
          observedAtMs: observedAt,
          activityAt: DateTime.utc(2026, 9, 10),
        ),
        previous: null,
      );
      final later = recomputeSchedule(
        row: row(
          conclusion: JudgmentConclusion.unchanged,
          observedAtMs: DateTime.utc(2026, 9, 20).millisecondsSinceEpoch,
        ),
        previous: seeded,
      );
      expect(
        later.autoHotUntilMs,
        seeded.autoHotUntilMs,
        reason: '"unchanged" MUST NOT extend an existing window either',
      );
    });

    test('rebaseline and unknown do not set it', () {
      for (final conclusion in [
        JudgmentConclusion.rebaseline,
        JudgmentConclusion.unknown,
      ]) {
        final state = recomputeSchedule(
          row: row(
            conclusion: conclusion,
            observedAtMs: DateTime.utc(2026, 9, 10).millisecondsSinceEpoch,
          ),
          previous: null,
        );
        expect(state.autoHotUntilMs, isNull, reason: 'for $conclusion');
      }
    });
  });

  group('effective hot window (S6.3)', () {
    test('the later of the automatic and manual deadlines wins', () {
      final observedAt = DateTime.utc(2026, 9, 10).millisecondsSinceEpoch;
      final manualUntil = DateTime.utc(2026, 12, 1);
      final state = recomputeSchedule(
        row: row(
          conclusion: JudgmentConclusion.changed,
          observedAtMs: observedAt,
          activityAt: DateTime.utc(2026, 9, 10),
        ),
        previous: ScheduleState(
          sourceKey: 'src',
          comicId: 'c1',
          manualHotEnabled: true,
          manualHotUntilMs: manualUntil.millisecondsSinceEpoch,
        ),
      );

      final autoUntil = DateTime.fromMillisecondsSinceEpoch(
        state.autoHotUntilMs!,
        isUtc: true,
      );
      final effective = effectiveHotUntil(
        autoHotUntil: autoUntil,
        manualHotUntil: manualUntil,
        manualHotEnabled: true,
        now: DateTime.utc(2026, 9, 10),
      );
      expect(effective, manualUntil, reason: 'the later deadline is manual');

      // With a manual deadline earlier than the automatic one, the automatic
      // one wins instead.
      final earlierManual = DateTime.utc(2026, 9, 11);
      expect(
        effectiveHotUntil(
          autoHotUntil: autoUntil,
          manualHotUntil: earlierManual,
          manualHotEnabled: true,
          now: DateTime.utc(2026, 9, 10),
        ),
        autoUntil,
      );
    });

    test('a hot window shortens the interval to the hot interval', () {
      final observedAt = DateTime.utc(2026, 9, 10).millisecondsSinceEpoch;
      final hot = recomputeSchedule(
        row: row(
          conclusion: JudgmentConclusion.changed,
          observedAtMs: observedAt,
          activityAt: DateTime.utc(2026, 9, 10),
        ),
        previous: null,
      );
      final cold = recomputeSchedule(
        row: row(
          conclusion: JudgmentConclusion.unchanged,
          observedAtMs: observedAt,
          activityAt: DateTime.utc(2026, 9, 10),
        ),
        previous: null,
      );
      final hotInterval = hot.nextAtMs! - observedAt;
      final coldInterval = cold.nextAtMs! - observedAt;
      expect(hotInterval, kFollowUpdateHotInterval.inMilliseconds);
      expect(coldInterval, greaterThan(hotInterval));
    });
  });

  group('recompute is driven by the event and by nothing else (S3)', () {
    test('next_at is computed from the observation landing time', () {
      final observedAt = DateTime.utc(2026, 9, 10).millisecondsSinceEpoch;
      final state = recomputeSchedule(
        row: row(
          observedAtMs: observedAt,
          activityAt: DateTime.utc(2026, 9, 10),
        ),
        previous: null,
      );
      final decision = computeNextSchedule(
        completedAt: DateTime.utc(2026, 9, 10),
        effectiveActivityAt: DateTime.utc(2026, 9, 10),
        manualHotEnabled: false,
        oldScheduleJitterApplied: false,
        sourceKey: 'src',
        comicId: 'c1',
      );
      expect(state.nextAtMs, decision.nextCheckAt.millisecondsSinceEpoch);
    });

    test('the jitter marker is carried until the algorithm consumes it', () {
      // A very old comic: the age gate makes the algorithm apply the one-time
      // offset and report it back.
      final observedAt = DateTime.utc(2026, 9, 10).millisecondsSinceEpoch;
      final state = recomputeSchedule(
        row: row(
          observedAtMs: observedAt,
          activityAt: DateTime.utc(2000, 1, 1),
        ),
        previous: null,
      );
      expect(state.oldScheduleJitterApplied, isTrue);
      expect(
        state.oldScheduleJitterApplied,
        computeNextSchedule(
          completedAt: DateTime.utc(2026, 9, 10),
          effectiveActivityAt: DateTime.utc(2000, 1, 1),
          manualHotEnabled: false,
          oldScheduleJitterApplied: false,
          sourceKey: 'src',
          comicId: 'c1',
        ).appliedOldScheduleJitter,
      );
    });

    test('manual preference is carried verbatim, never re-derived', () {
      final state = recomputeSchedule(
        row: row(
          observedAtMs: DateTime.utc(2026, 9, 10).millisecondsSinceEpoch,
        ),
        previous: ScheduleState(
          sourceKey: 'src',
          comicId: 'c1',
          manualHotEnabled: true,
          manualHotUntilMs: DateTime.utc(2030, 1, 1).millisecondsSinceEpoch,
        ),
      );
      expect(state.manualHotEnabled, isTrue);
      expect(
        state.manualHotUntilMs,
        DateTime.utc(2030, 1, 1).millisecondsSinceEpoch,
      );
    });
  });
}
