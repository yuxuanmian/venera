import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/scan/observation_codec.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';

import 'fakes.dart';

/// A fixed "now" injected into the engine, so every conclusion below is a pure
/// function of its inputs (research R-08).
final DateTime testNow = DateTime.utc(2026, 9, 10, 12);

JudgmentOutcome decideAt({
  ObservationSpec? previous,
  ObservationSpec current = const ObservationSpec(),
  int decidedAtMs = 0,
}) => decide(
  previousFactJson: previous?.json,
  recordedLabel: previous == null ? null : labelA,
  currentObservationJson: current.json,
  currentLabel: labelA,
  currentObservedAtMs: testNow.millisecondsSinceEpoch,
  decidedAtMs: decidedAtMs == 0 ? testNow.millisecondsSinceEpoch : decidedAtMs,
  previousHasNewUpdate: false,
  previousNoCommonStreak: 0,
);

void main() {
  group('SC-003: date-only timestamps are accepted and compared', () {
    test('a date-only value is usable evidence', () {
      final outcome = decideAt(
        current: const ObservationSpec(updatedAt: '2026-09-01'),
      );
      expect(outcome.reason, JudgmentReason.noPreviousEvidence);
      expect(outcome.factJson, contains('2026-09-01'));
    });

    test('a later date-only value is a change', () {
      final outcome = decideAt(
        previous: const ObservationSpec(updatedAt: '2026-09-01'),
        current: const ObservationSpec(updatedAt: '2026-09-02'),
      );
      expect(outcome.selectedEvidence, JudgmentEvidence.updatedAt);
      expect(outcome.conclusion, JudgmentConclusion.changed);
      expect(outcome.reason, JudgmentReason.later);
    });

    test('an earlier date-only value is a regression', () {
      final outcome = decideAt(
        previous: const ObservationSpec(updatedAt: '2026-09-02'),
        current: const ObservationSpec(updatedAt: '2026-09-01'),
      );
      expect(outcome.conclusion, JudgmentConclusion.rebaseline);
      expect(outcome.reason, JudgmentReason.regressed);
    });

    test('the same date-only value is unchanged', () {
      final outcome = decideAt(
        previous: const ObservationSpec(updatedAt: '2026-09-01'),
        current: const ObservationSpec(updatedAt: '2026-09-01'),
      );
      expect(outcome.conclusion, JudgmentConclusion.unchanged);
      expect(outcome.reason, JudgmentReason.equal);
    });

    test('a date-only value on the guard floor is accepted', () {
      // The whole represented day must sit inside the window, which is what
      // lets a date-only value mean "that day" rather than "some instant".
      final outcome = decideAt(
        previous: const ObservationSpec(updatedAt: '2000-01-01'),
        current: const ObservationSpec(updatedAt: '2000-01-02'),
      );
      expect(outcome.selectedEvidence, JudgmentEvidence.updatedAt);
      expect(outcome.conclusion, JudgmentConclusion.changed);
    });

    test('a date-only value from 1999 is dropped', () {
      final outcome = decideAt(
        previous: const ObservationSpec(
          updatedAt: '2026-09-01',
          latestChapterId: 'chapter-0',
        ),
        current: const ObservationSpec(
          updatedAt: '1999-12-31',
          latestChapterId: 'chapter-1',
        ),
      );
      // Only the timestamp drops; the sibling field still compares.
      expect(outcome.selectedEvidence, JudgmentEvidence.latestChapterId);
      expect(outcome.conclusion, JudgmentConclusion.changed);
    });

    test('a date-only value beyond the ceiling is dropped', () {
      final outcome = decideAt(
        previous: const ObservationSpec(
          updatedAt: '2026-09-01',
          latestChapterId: 'chapter-0',
        ),
        current: const ObservationSpec(
          updatedAt: '2030-01-01',
          latestChapterId: 'chapter-1',
        ),
      );
      expect(outcome.selectedEvidence, JudgmentEvidence.latestChapterId);
      expect(outcome.conclusion, JudgmentConclusion.changed);
    });
  });

  group('SC-003: equivalent offsets denoting one instant compare equal', () {
    test('Z and a positive offset for the same moment', () {
      final outcome = decideAt(
        previous: const ObservationSpec(updatedAt: '2026-09-01T00:00:00Z'),
        current: const ObservationSpec(updatedAt: '2026-09-01T08:00:00+08:00'),
      );
      expect(outcome.selectedEvidence, JudgmentEvidence.updatedAt);
      expect(outcome.conclusion, JudgmentConclusion.unchanged);
      expect(outcome.reason, JudgmentReason.equal);
    });

    test('Z and a negative offset for the same moment', () {
      final outcome = decideAt(
        previous: const ObservationSpec(updatedAt: '2026-09-01T00:00:00Z'),
        current: const ObservationSpec(updatedAt: '2026-08-31T19:00:00-05:00'),
      );
      expect(outcome.conclusion, JudgmentConclusion.unchanged);
    });

    test('fractional seconds do not create a difference', () {
      final outcome = decideAt(
        previous: const ObservationSpec(updatedAt: '2026-09-01T00:00:00.000Z'),
        current: const ObservationSpec(
          updatedAt: '2026-09-01T08:00:00.000+08:00',
        ),
      );
      expect(outcome.conclusion, JudgmentConclusion.unchanged);
    });
  });

  group('SC-003: invalid values drop only their own field', () {
    /// The invalid timestamp is dropped, and the shared `latestChapterId` tier
    /// proves the sibling field survived.  Both sides must carry the sibling
    /// so that a shared tier remains after the drop.
    void expectTimestampDropped(String invalid, {required String reason}) {
      final outcome = decideAt(
        previous: const ObservationSpec(
          updatedAt: '2026-09-01',
          latestChapterId: 'chapter-0',
        ),
        current: ObservationSpec(
          updatedAt: invalid,
          latestChapterId: 'chapter-1',
        ),
      );
      expect(
        outcome.selectedEvidence,
        JudgmentEvidence.latestChapterId,
        reason: reason,
      );
      expect(outcome.conclusion, JudgmentConclusion.changed, reason: reason);
      expect(outcome.reason, JudgmentReason.different, reason: reason);
    }

    test('an impossible calendar date is dropped', () {
      for (final invalid in const [
        '2026-02-30',
        '2026-13-01',
        '2026-00-10',
        '2026-09-31',
        '2025-02-29',
      ]) {
        expectTimestampDropped(invalid, reason: invalid);
      }
    });

    test('a leap day in a leap year is accepted', () {
      final outcome = decideAt(
        previous: const ObservationSpec(updatedAt: '2024-02-28'),
        current: const ObservationSpec(updatedAt: '2024-02-29'),
      );
      expect(outcome.selectedEvidence, JudgmentEvidence.updatedAt);
      expect(outcome.conclusion, JudgmentConclusion.changed);
    });

    test('a time without an explicit timezone is dropped', () {
      expectTimestampDropped(
        '2026-09-02T10:00:00',
        reason: 'timezone is required',
      );
    });

    test('an out-of-range clock component is dropped', () {
      for (final invalid in const [
        '2026-09-01T24:00:00Z',
        '2026-09-01T10:60:00Z',
        '2026-09-01T10:00:60Z',
      ]) {
        expectTimestampDropped(invalid, reason: invalid);
      }
    });
  });

  group('SC-003: the raw representation is never rewritten', () {
    test('the engine reports the input string verbatim', () {
      const original = '2026-09-01T08:15:30.123+08:00';
      final outcome = decideAt(
        previous: const ObservationSpec(updatedAt: '2026-08-01T00:00:00Z'),
        current: const ObservationSpec(updatedAt: original),
      );
      expect(outcome.currentValue, original);
      expect(outcome.previousValue, '2026-08-01T00:00:00Z');
    });

    test('a date-only input is not reported as midnight', () {
      final outcome = decideAt(
        previous: const ObservationSpec(updatedAt: '2026-08-01'),
        current: const ObservationSpec(updatedAt: '2026-09-01'),
      );
      expect(outcome.currentValue, '2026-09-01');
      expect(outcome.currentValue, isNot(contains('T00:00')));
      expect(outcome.previousValue, '2026-08-01');
    });

    test('the fact survives a database round trip byte for byte', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'venera-judgment-time-',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));
      final repository = SqliteJudgmentRepository(
        databasePath: '${tempDirectory.path}${Platform.pathSeparator}state.db',
      );
      addTearDown(repository.close);

      final scans = InMemoryScanItemStore(
        items: [
          const ObservationSpec(updatedAt: '2026-09-01').toStoredItem(
            sourceKey: 'src',
            comicId: 'date-only',
            evidenceSchema: labelA,
          ),
          const ObservationSpec(
            updatedAt: '2026-09-01T08:15:30.123+08:00',
          ).toStoredItem(
            sourceKey: 'src',
            comicId: 'offset',
            evidenceSchema: labelA,
          ),
        ],
      );
      await JudgmentService(
        repository: repository,
        scanRepository: scans,
        clock: FixedClock(testNow).call,
      ).run();

      final dateOnly = await repository.readFor('src', 'date-only');
      expect(dateOnly!.factJson, contains('"updatedAt":"2026-09-01"'));
      expect(dateOnly.factJson, isNot(contains('2026-09-01T')));
      expect(dateOnly.lastCurrentValue, isNull);

      final offset = await repository.readFor('src', 'offset');
      expect(
        offset!.factJson,
        contains('"updatedAt":"2026-09-01T08:15:30.123+08:00"'),
      );
      expect(offset.factJson, isNot(contains('2026-09-01T00:15:30')));
      // The stored JSON is exactly the observed payload, not a re-encoding.
      expect(
        offset.factJson,
        jsonEncode(
          const ObservationSpec(
            updatedAt: '2026-09-01T08:15:30.123+08:00',
          ).observation.toJson(),
        ),
      );
    });
  });

  group('the scan side already preserves both forms (T033)', () {
    const codec = ObservationCodec();

    test(
      'date-only and fractional-offset values both round trip unrewritten',
      () {
        for (final value in const [
          '2024-02-29',
          '2026-09-10T12:30:45.123+08:00',
          '2026-09-10T12:30:45Z',
        ]) {
          final observation = codec.normalizeObservation({
            'update': {'updatedAt': value},
          });
          expect(
            observation.update!.updatedAt,
            value,
            reason: '$value must not be rewritten',
          );
        }
      },
    );

    test('the guard is not applied on the scan side', () {
      // Date-only evidence from 1999 is preserved by the scan codec; judgment
      // is the layer that decides it is implausible.
      final observation = codec.normalizeObservation({
        'update': {'updatedAt': '1999-12-31'},
      });
      expect(observation.update!.updatedAt, '1999-12-31');
    });
  });
}
