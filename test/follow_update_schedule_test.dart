import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/follow_update_schedule.dart';

void main() {
  final now = DateTime(2026, 8, 22, 12);

  group('normal follow-up schedule bands', () {
    final cases = <(int, Duration)>[
      (183, const Duration(hours: 24)),
      (184, const Duration(days: 2)),
      (365, const Duration(days: 2)),
      (366, const Duration(days: 3)),
      (487, const Duration(days: 3)),
      (488, const Duration(days: 4)),
      (609, const Duration(days: 4)),
      (610, const Duration(days: 5)),
      (730, const Duration(days: 5)),
      (731, const Duration(days: 7)),
      (1000, const Duration(days: 7)),
      (1460, const Duration(days: 7)),
      (1461, const Duration(days: 14)),
    ];

    for (final (days, expected) in cases) {
      test('$days days', () {
        expect(
          normalIntervalFor(
            now: now,
            effectiveActivityAt: now.subtract(Duration(days: days)),
          ),
          expected,
        );
      });
    }
  });

  test('ordinary schedule changes only at the complete age boundary', () {
    final boundaries = <(int days, Duration before, Duration at)>[
      (184, const Duration(hours: 24), const Duration(days: 2)),
      (366, const Duration(days: 2), const Duration(days: 3)),
      (488, const Duration(days: 3), const Duration(days: 4)),
      (610, const Duration(days: 4), const Duration(days: 5)),
      (731, const Duration(days: 5), const Duration(days: 7)),
      (1461, const Duration(days: 7), const Duration(days: 14)),
    ];
    for (final (days, before, at) in boundaries) {
      expect(
        normalIntervalFor(
          now: now,
          effectiveActivityAt: now
              .subtract(Duration(days: days))
              .add(const Duration(milliseconds: 1)),
        ),
        before,
        reason: '$days days minus one millisecond',
      );
      expect(
        normalIntervalFor(
          now: now,
          effectiveActivityAt: now.subtract(Duration(days: days)),
        ),
        at,
        reason: '$days days exactly',
      );
    }
  });

  test('hot window wins over every ordinary band', () {
    final decision = computeNextSchedule(
      completedAt: now,
      effectiveActivityAt: now.subtract(const Duration(days: 3000)),
      autoHotUntil: now.add(const Duration(days: 14)),
      manualHotEnabled: false,
      oldScheduleJitterApplied: false,
      sourceKey: 'source',
      comicId: 'comic',
    );
    expect(decision.hotActive, isTrue);
    expect(decision.interval, kFollowUpdateHotInterval);
    expect(decision.nextCheckAt, now.add(kFollowUpdateHotInterval));
  });

  test('missed windows schedule once from actual completion', () {
    final completed = now.add(const Duration(days: 3));
    final decision = computeNextSchedule(
      completedAt: completed,
      effectiveActivityAt: now.subtract(const Duration(days: 5)),
      autoHotUntil: now.add(const Duration(days: 14)),
      manualHotEnabled: false,
      oldScheduleJitterApplied: false,
      sourceKey: 'source',
      comicId: 'comic',
    );
    expect(decision.nextCheckAt, completed.add(kFollowUpdateHotInterval));
  });

  test('hot state expiry distinguishes automatic and manual windows', () {
    final autoUntil = now.add(const Duration(hours: 1));
    final manualUntil = now.subtract(const Duration(hours: 1));
    expect(
      isHotActive(
        now: now,
        autoHotUntil: autoUntil,
        manualHotEnabled: true,
        manualHotUntil: manualUntil,
      ),
      isTrue,
    );
    expect(
      effectiveHotUntil(
        now: now,
        autoHotUntil: autoUntil,
        manualHotUntil: manualUntil,
      ),
      autoUntil,
    );
    expect(
      isManualHotActive(
        now: now,
        manualHotEnabled: true,
        manualHotUntil: manualUntil,
      ),
      isFalse,
    );
  });

  test('old schedule jitter is stable, bounded and applied once', () {
    final beforeThreshold = computeNextSchedule(
      completedAt: now,
      effectiveActivityAt: now.subtract(const Duration(days: 730)),
      manualHotEnabled: false,
      oldScheduleJitterApplied: false,
      sourceKey: 'source',
      comicId: 'before',
    );
    expect(beforeThreshold.appliedOldScheduleJitter, isFalse);
    final atThreshold = computeNextSchedule(
      completedAt: now,
      effectiveActivityAt: now.subtract(kFollowUpdateOldScheduleJitterAge),
      manualHotEnabled: false,
      oldScheduleJitterApplied: false,
      sourceKey: 'source',
      comicId: 'at',
    );
    expect(atThreshold.appliedOldScheduleJitter, isTrue);
    expect(
      atThreshold.nextCheckAt.difference(now).inDays,
      inInclusiveRange(5, 9),
    );

    final first = computeNextSchedule(
      completedAt: now,
      effectiveActivityAt: now.subtract(const Duration(days: 2000)),
      manualHotEnabled: false,
      oldScheduleJitterApplied: false,
      sourceKey: 'source',
      comicId: 'comic',
    );
    final second = computeNextSchedule(
      completedAt: now,
      effectiveActivityAt: now.subtract(const Duration(days: 2000)),
      manualHotEnabled: false,
      oldScheduleJitterApplied: false,
      sourceKey: 'source',
      comicId: 'comic',
    );
    expect(first.appliedOldScheduleJitter, isTrue);
    expect(first.nextCheckAt, second.nextCheckAt);
    expect(first.nextCheckAt.difference(now).inDays, inInclusiveRange(12, 16));
    final later = computeNextSchedule(
      completedAt: now,
      effectiveActivityAt: now.subtract(const Duration(days: 2000)),
      manualHotEnabled: false,
      oldScheduleJitterApplied: true,
      sourceKey: 'source',
      comicId: 'comic',
    );
    expect(later.nextCheckAt, now.add(const Duration(days: 14)));
  });

  group('source activity parsing', () {
    test('supports seconds, milliseconds, ISO and date-only values', () {
      final expected = DateTime(2026, 8, 20);
      expect(
        parseFollowUpdateActivityTime(
          '${expected.millisecondsSinceEpoch ~/ 1000}',
          now: now,
        ),
        expected,
      );
      expect(
        parseFollowUpdateActivityTime(
          '${expected.millisecondsSinceEpoch}',
          now: now,
        ),
        expected,
      );
      expect(
        parseFollowUpdateActivityTime('2026-08-20T00:00:00', now: now),
        expected,
      );
      expect(parseFollowUpdateActivityTime('2026-8-20', now: now), expected);
    });

    test('rejects old, too-far future and malformed values', () {
      expect(parseFollowUpdateActivityTime('1999-12-31', now: now), isNull);
      expect(parseFollowUpdateActivityTime('2026-08-24', now: now), isNull);
      expect(parseFollowUpdateActivityTime('not-a-date', now: now), isNull);
      expect(
        parseFollowUpdateActivityTime('999999999999999999999999', now: now),
        isNull,
      );
      expect(
        parseFollowUpdateActivityTime('-999999999999999999999999', now: now),
        isNull,
      );
      expect(parseFollowUpdateActivityTime('2026-02-29', now: now), isNull);
      expect(parseFollowUpdateActivityTime('2026-02-31', now: now), isNull);
      expect(parseFollowUpdateActivityTime('2026-13-01', now: now), isNull);
      expect(
        parseFollowUpdateActivityTime('2024-02-29', now: now),
        DateTime(2024, 2, 29),
      );
    });

    test('validates the original calendar date before parsing ISO time', () {
      for (final value in <String>[
        '2026-02-31T12:00:00',
        '2026-02-31T12:00:00+08:00',
        '2026-13-01T00:00:00Z',
        '2026-04-31 23:59:59',
      ]) {
        expect(parseFollowUpdateActivityTime(value, now: now), isNull);
      }
      expect(
        parseFollowUpdateActivityTime(
          '2024-02-29T12:00:00Z',
          now: now,
        )!.toUtc(),
        DateTime.utc(2024, 2, 29, 12),
      );
      expect(
        parseFollowUpdateActivityTime(
          '2026-08-20T12:30:45+08:00',
          now: now,
        )!.toUtc(),
        DateTime.utc(2026, 8, 20, 4, 30, 45),
      );
    });

    test('update wins and invalid update falls back to upload', () {
      expect(
        chooseFollowUpdateActivityTime(
          updateTime: '2026-08-21',
          uploadTime: '2026-08-20',
          now: now,
        ),
        DateTime(2026, 8, 21),
      );
      expect(
        chooseFollowUpdateActivityTime(
          updateTime: '2026-02-31T12:00:00+08:00',
          uploadTime: '2026-08-20',
          now: now,
        ),
        DateTime(2026, 8, 20),
      );
    });
  });
}
