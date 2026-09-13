import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/scan/observation_codec.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_limits.dart';

void main() {
  const codec = ObservationCodec();

  test('normalizes optional facts independently and keeps false/zero', () {
    final observation = codec.normalizeObservation({
      'update': {
        'updatedAt': 'not-a-date',
        'latestChapterId': '  chapter-7  ',
        'chapterCount': 0,
        'recentChapterIds': [' a ', 'a', '', 1, 'b', 'c', 'd', 'e', 'f'],
        // An unrecognized key is ignored, not an error.
        'unknownField': 'ignored',
      },
      'sourceUnread': false,
      'hasNewUpdate': true,
    });

    expect(observation.sourceUnread, isFalse);
    expect(observation.update!.updatedAt, isNull);
    expect(observation.update!.latestChapterId, 'chapter-7');
    expect(observation.update!.chapterCount, 0);
    expect(observation.update!.recentChapterIds, ['a', 'b', 'c', 'd', 'e']);
    expect(observation.toJson().containsKey('hasNewUpdate'), isFalse);
  });

  test('drops malformed optional update while preserving sourceUnread', () {
    for (final invalidUpdate in <Object?>['bad', <Object?>[], 42, null]) {
      final observation = codec.normalizeObservation({
        'update': invalidUpdate,
        'sourceUnread': false,
      });
      expect(observation.update, isNull);
      expect(observation.sourceUnread, isFalse);
    }
    expect(
      () => codec.normalizeObservation({'update': 'bad'}),
      throwsA(isA<ScanCodecException>()),
    );
  });

  test('accepts strict date-only and explicit timezone timestamps only', () {
    expect(
      codec
          .normalizeObservation({
            'update': {'updatedAt': '2024-02-29'},
          })
          .update!
          .updatedAt,
      '2024-02-29',
    );
    expect(
      codec
          .normalizeObservation({
            'update': {'updatedAt': '2026-09-10T12:30:45.123+08:00'},
          })
          .update!
          .updatedAt,
      '2026-09-10T12:30:45.123+08:00',
    );
    expect(
      codec
          .normalizeObservation({
            'update': {
              'updatedAt': '2026-09-10T12:30:45',
              'latestChapterId': 'fallback',
            },
          })
          .update!
          .toJson(),
      {'latestChapterId': 'fallback'},
    );
  });

  test('rejects empty observations and conflicting envelopes', () {
    expect(
      () => codec.normalizeObservation({'update': {}, 'sourceUnread': null}),
      throwsA(isA<ScanCodecException>()),
    );
    expect(
      () => codec.decodeComicEnvelope({
        'observation': {'sourceUnread': false},
        'failure': {'message': 'bad'},
      }),
      throwsA(isA<ScanCodecException>()),
    );
    expect(
      () => codec.decodeCollectionPage({
        'items': [],
        'next': null,
        'failure': {},
      }),
      throwsA(isA<ScanCodecException>()),
    );
  });

  test('decodes safe collection failures without creating items', () {
    final failure = codec.decodeCollectionFailure({
      'failure': {'httpStatus': 403, 'message': 'permission denied'},
    });
    expect(failure!.httpStatus, 403);
    expect(failure.message, 'permission denied');
    expect(codec.decodeCollectionFailure({'items': [], 'next': null}), isNull);
  });

  test('preflight rejects unsafe JSON and canonicalizes object key order', () {
    final cyclic = <String, dynamic>{};
    cyclic['self'] = cyclic;
    expect(
      () => codec.preflightJson(cyclic, label: 'cursor'),
      throwsA(isA<ScanCodecException>()),
    );
    expect(
      () => codec.preflightJson(double.infinity, label: 'cursor'),
      throwsA(isA<ScanCodecException>()),
    );
    expect(
      codec.canonicalJson({
        'b': 1,
        'a': [false, 0],
      }),
      '{"a":[false,0],"b":1}',
    );
  });

  test('applies independent page and cursor limits', () {
    const limits = ScanLimits(maxPageItems: 1, maxCursorJsonBytes: 4);
    const limited = ObservationCodec(limits: limits);
    expect(
      () => limited.decodeCollectionPage({
        'items': [
          {
            'comicId': 'a',
            'observation': {'sourceUnread': false},
          },
          {
            'comicId': 'b',
            'observation': {'sourceUnread': false},
          },
        ],
        'next': null,
      }),
      throwsA(isA<ScanCodecException>()),
    );
    expect(
      () => limited.canonicalJson({'long': true}),
      throwsA(isA<ScanCodecException>()),
    );
  });

  test('fixture remains valid JSON', () {
    final fixture = jsonDecode(
      // Keep the test self-contained; the file is also shipped as an audit
      // fixture for the source and review tasks.
      '[{"update":{"latestChapterId":"fixture"}}]',
    );
    expect(fixture, isA<List<dynamic>>());
  });

  test('rejects an identifier containing U+0000', () {
    // Observation identity is built by joining with U+0000, so an identifier
    // carrying that character would make the join ambiguous (FR-030).
    for (final identifier in const ['bad\u0000id', '\u0000', 'prefix\u0000']) {
      final observation = codec.normalizeObservation({
        'update': {'latestChapterId': identifier, 'chapterCount': 3},
      });
      // The identifier is dropped; its valid sibling survives untouched.
      expect(observation.update!.latestChapterId, isNull, reason: identifier);
      expect(observation.update!.chapterCount, 3, reason: identifier);
    }
    final recent = codec.normalizeObservation({
      'update': {
        'recentChapterIds': ['ok-1', 'bad\u0000id', 'ok-2'],
      },
    });
    expect(recent.update!.recentChapterIds, ['ok-1', 'ok-2']);
  });

  test('rejects a collection comicId containing U+0000', () {
    expect(
      () => codec.decodeCollectionPage({
        'items': [
          {
            'comicId': 'bad\u0000id',
            'observation': {'sourceUnread': false},
          },
        ],
        'next': null,
      }),
      throwsA(isA<ScanCodecException>()),
    );
  });

  test('scan item JSON round-trips both observation and failure payloads', () {
    final observed = ScanItemResult.observed(
      attemptId: 'attempt',
      scopeAttemptId: 'scope',
      sourceKey: 'source',
      comicId: 'comic',
      producer: ScanProducer.comic,
      definitionRevision: 'rev',
      observedAt: '2026-09-10T00:00:00.000Z',
      evidenceSchema: '{"latestchapterid":"last_chapter.id"}',
      observation: ScanObservation(
        update: UpdateDescriptor(
          updatedAt: '2026-09-10',
          latestChapterId: 'chapter',
          chapterCount: 0,
          recentChapterIds: ['a', 'b'],
        ),
        sourceUnread: false,
      ),
    );
    final failed = ScanItemResult.failed(
      attemptId: 'attempt-2',
      scopeAttemptId: 'scope-2',
      sourceKey: 'source',
      comicId: 'comic',
      producer: ScanProducer.comic,
      definitionRevision: 'rev',
      observedAt: '2026-09-10T00:00:00.000Z',
      evidenceSchema: '{"latestchapterid":"last_chapter.id"}',
      failure: const ScanFailure(httpStatus: 503, message: 'unavailable'),
    );

    expect(ScanItemResult.fromJson(observed.toJson()), observed);
    expect(ScanItemResult.fromJson(failed.toJson()), failed);
    // The comparable label rides beside definitionRevision and never enters
    // the observation payload (Contract C5).
    expect(observed.toJson().containsKey('evidenceSchema'), isTrue);
    expect(
      observed.observation!.toJson().containsKey('evidenceSchema'),
      isFalse,
    );
  });

  test('scan item JSON round-trips a null comparable label', () {
    final observed = ScanItemResult.observed(
      attemptId: 'attempt',
      scopeAttemptId: 'scope',
      sourceKey: 'source',
      comicId: 'comic',
      producer: ScanProducer.comic,
      definitionRevision: 'rev',
      observedAt: '2026-09-10T00:00:00.000Z',
      observation: ScanObservation(
        update: UpdateDescriptor(latestChapterId: 'chapter'),
      ),
    );
    expect(observed.evidenceSchema, isNull);
    expect(observed.toJson().containsKey('evidenceSchema'), isFalse);
    expect(ScanItemResult.fromJson(observed.toJson()).evidenceSchema, isNull);
  });
}
