import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_log.dart';

/// Contract L (007): the label pure functions.
///
/// These are the only place the prefix's shape, length, cleaning and fallback
/// are decided, so they are tested directly — no store, no network, no log sink.
void main() {
  group('sanitizeLabel (L5)', () {
    test('removes newlines and control characters instead of copying them', () {
      expect(sanitizeLabel('a\nb'), 'a b');
      expect(sanitizeLabel('a\r\nb'), 'a b');
      expect(sanitizeLabel('a\tb'), 'a b');
      expect(sanitizeLabel('a\u0000b'), 'ab');
      expect(sanitizeLabel('a\u0007b'), 'ab');
      expect(sanitizeLabel('a\u001Fb'), 'ab');
      expect(sanitizeLabel('a\u007Fb'), 'ab');
      // Unicode line/paragraph separators and bidi overrides are control
      // characters that merely happen to be printable.
      expect(sanitizeLabel('a\u2028b'), 'ab');
      expect(sanitizeLabel('a\u2029b'), 'ab');
      expect(sanitizeLabel('a\u202Eb'), 'ab');
      expect(sanitizeLabel('a\u2066b'), 'ab');
    });

    test('collapses whitespace and trims', () {
      expect(sanitizeLabel('  a   b  '), 'a b');
      expect(sanitizeLabel('\n\n'), '');
      expect(sanitizeLabel('   '), '');
      expect(sanitizeLabel(null), '');
      expect(sanitizeLabel(''), '');
    });

    test('truncates by character, so a Chinese name is never cut in half', () {
      const chinese = '一二三四五六七八九十十一十二';
      final truncated = sanitizeLabel(chinese);
      expect(truncated, '一二三四五六七八九十');
      expect(truncated.runes.length, kScanLogLabelMaxChars);

      // Byte-truncation would produce invalid UTF-8 here; character truncation
      // is what makes the value safe to write into a log line.
      expect(truncated, isNot(contains('\uFFFD')));
      expect(sanitizeLabel('abc'), 'abc');
      expect(sanitizeLabel('abcdefghijk'), 'abcdefghij');
    });

    test('honours an explicit cap and rejects a non-positive one', () {
      expect(sanitizeLabel('abcdefghij', maxChars: 4), 'abcd');
      expect(sanitizeLabel('abcd', maxChars: 0), '');
      expect(sanitizeLabel('abcd', maxChars: -1), '');
    });

    test('surrogate pairs survive truncation intact', () {
      // A 4-byte character (an emoji) is one code point; taking 1 must not split
      // it into lone surrogates.
      final truncated = sanitizeLabel('😀😀😀', maxChars: 2);
      expect(truncated.runes.length, 2);
      expect(truncated, '😀😀');
    });
  });

  group('comicLabel (L4)', () {
    test('is the source key plus the first 10 characters of the name', () {
      expect(comicLabel('manwa', 'One Piece', 'c1'), 'manwa One Piece');
      expect(comicLabel('manwa', '一二三四五六七八九十十一', 'c1'), 'manwa 一二三四五六七八九十');
    });

    test('falls back to the identity prefix when the name is unusable', () {
      expect(
        comicLabel('manwa', null, 'comic-abcdefghijkl'),
        'manwa comic-abcd',
      );
      expect(comicLabel('manwa', '', 'comic-abcdefghijkl'), 'manwa comic-abcd');
      expect(
        comicLabel('manwa', '   ', 'comic-1234567890abc'),
        'manwa comic-1234',
      );
      // A name that sanitization must drop also falls back.
      expect(
        comicLabel('manwa', 'https://example.com/x', 'comic-1234567890'),
        'manwa comic-1234',
      );
    });

    test('caps the identity hint, not the source key', () {
      // L4's ten-character limit is on the name (or the identity that replaces
      // it).  The source key is the other half and is host-owned configuration:
      // truncating it to ten would make two long-keyed sources indistinguishable
      // in the log, which is the opposite of the contract's purpose.
      final label = comicLabel(
        'source-key-that-is-long',
        'a-very-long-comic-name-indeed',
        'comic-id',
      );
      expect(label, startsWith('source-key-that-is-long '));
      expect(label.split(' ').last.runes.length, kScanLogLabelMaxChars);
      expect(
        pageLabel('source-key-that-is-long', 2),
        'source-key-that-is-long p2',
      );
    });

    test('still cleans the source key half', () {
      // Not a security boundary, but a multi-line key must not be able to
      // restructure a log line either.
      expect(comicLabel('a\nb', 'x', 'c1'), 'a b x');
    });
  });

  group('pageLabel (L4)', () {
    test('is the page ordinal from 1', () {
      expect(pageLabel('manwa', 1), 'manwa p1');
      expect(pageLabel('manwa', 3), 'manwa p3');
    });

    test('clamps a nonsensical ordinal instead of emitting p0 or p-1', () {
      expect(pageLabel('manwa', 0), 'manwa p1');
      expect(pageLabel('manwa', -5), 'manwa p1');
    });

    test('a consistency re-check is distinguishable from the data page', () {
      final data = pageLabel('manwa', 3);
      final verify = pageLabel('manwa', 3, verify: true);
      expect(verify, isNot(data));
      expect(verify, contains('p3'));
      expect(verify, contains('verify'));
      expect(data, isNot(contains('verify')));
    });
  });

  group('the plan overview (L1/L3/L8)', () {
    List<String> build() => formatPlanOverview(
      perSource: const [
        ScanPlanSourceLine(
          sourceKey: 'manwa',
          unit: 'collection',
          workCount: 1,
        ),
        ScanPlanSourceLine(sourceKey: 'picacg', unit: 'comic', workCount: 20),
      ],
      worksBeforeNarrowing: 300,
      worksAfterNarrowing: 21,
      skippedByReason: {
        ScanSourceSkipReason.absent: ['ghost'],
        ScanSourceSkipReason.notLoggedIn: ['baozimh', 'copymanga'],
      },
    );

    test('stays at two lines no matter how much work is in scope', () {
      expect(build(), hasLength(2));
    });

    test('reports sources, units, and the narrowing before/after', () {
      final line = build().first;
      expect(line, contains('sources=2'));
      expect(line, contains('works=21/300'));
      expect(line, contains('manwa collection x1'));
      expect(line, contains('picacg comic x20'));
    });

    test('classifies skipped sources by reason instead of one total (L3)', () {
      final line = build().last;
      expect(line, contains('total=3'));
      expect(line, contains('absent=1'));
      expect(line, contains('invalid=0'));
      expect(line, contains('disabled=0'));
      expect(line, contains('notLoggedIn=2'));
      expect(line, contains('absent: ghost'));
      expect(line, contains('notLoggedIn: baozimh,copymanga'));
    });

    test('never lists a comic name', () {
      final text = build().join('\n');
      expect(text, isNot(contains('comic-1')));
    });

    test('names the trigger and the round scope when the caller supplies them '
        '(F1.4)', () {
      final line = formatPlanOverview(
        perSource: const [
          ScanPlanSourceLine(
            sourceKey: 'manwa',
            unit: 'collection',
            workCount: 1,
          ),
        ],
        worksBeforeNarrowing: 141,
        worksAfterNarrowing: 1,
        skippedByReason: const {},
        trigger: 'cacheChanged',
        scopeSourceKeys: const {'picacg'},
      ).first;

      expect(line, contains('works=1/141'));
      expect(line, contains('trigger=cacheChanged'));
      expect(
        line,
        contains('scope=picacg'),
        reason:
            'works=1/141 alone cannot say whether the round was one collection '
            'or a hundred dropped per-comic works',
      );
    });

    test('says "all" for an unrestricted round and stays unchanged without a '
        'trigger', () {
      final unrestricted = formatPlanOverview(
        perSource: const [],
        worksBeforeNarrowing: 0,
        worksAfterNarrowing: 0,
        skippedByReason: const {},
        trigger: 'manual',
        scopeSourceKeys: null,
      ).first;
      expect(unrestricted, contains('trigger=manual scope=all'));

      // The Debug entry point names no trigger, so its line shape is the one
      // 007 shipped (L8): no attribution segment at all.
      expect(build().first, isNot(contains('trigger=')));
      expect(build().first, isNot(contains('scope=')));
    });

    test('sorts the scope so the line is stable across runs', () {
      final line = formatPlanOverview(
        perSource: const [],
        worksBeforeNarrowing: 0,
        worksAfterNarrowing: 0,
        skippedByReason: const {},
        trigger: 'cacheChanged',
        scopeSourceKeys: const {'manwa', 'picacg', 'ehentai'},
      ).first;
      expect(line, contains('scope=ehentai,manwa,picacg'));
    });
  });

  group('the settlement overview (L2/L8)', () {
    test('is one line with every counter and the wall-clock time', () {
      final lines = formatSettlementOverview(
        progress: ScanProgress(
          discoveredWorks: 300,
          activeWorks: 0,
          succeededWorks: 250,
          failedWorks: 3,
          canceledWorks: 47,
          persistedItems: 250,
        ),
        elapsedMs: 65432,
        disposition: 'completed',
      );
      expect(lines, hasLength(1));
      final line = lines.single;
      expect(line, contains('discovered=300'));
      expect(line, contains('succeeded=250'));
      expect(line, contains('failed=3'));
      expect(line, contains('canceled=47'));
      expect(line, contains('persisted=250'));
      expect(line, contains('elapsed=65432ms'));
      expect(line, contains('disposition=completed'));
    });

    test('omits the disposition when the caller has none', () {
      final line = formatSettlementOverview(
        progress: ScanProgress(
          discoveredWorks: 0,
          activeWorks: 0,
          succeededWorks: 0,
          failedWorks: 0,
          canceledWorks: 0,
        ),
        elapsedMs: 1,
      ).single;
      expect(line, isNot(contains('disposition')));
    });
  });

  group('the label never carries forbidden content (L7)', () {
    test('a URL, a hostname or a credential is refused outright', () {
      for (final hostile in const [
        'https://example.com/comic',
        'http://10.0.0.1/x',
        'ftp://files.example.org',
        'www.example.com',
        'example.com',
        'sub.example.co.uk',
        'cookie=sessionid',
        'Cookie: sessionid',
        'authorization: Bearer abc',
        'token=abc123',
        'api_key=abc123',
        'password=hunter2',
      ]) {
        expect(
          sanitizeLabel(hostile),
          '',
          reason: '"$hostile" must not survive sanitization',
        );
      }
    });

    test('ordinary names are untouched', () {
      for (final safe in const [
        'One Piece',
        '一二三',
        'Vol.2 Chapter 5',
        'a-b_c',
      ]) {
        expect(sanitizeLabel(safe), isNotEmpty, reason: safe);
      }
    });

    test('a hostile name falls back to the identity instead of leaking', () {
      final label = comicLabel('manwa', 'https://evil.example/x', 'comic-1');
      expect(label, 'manwa comic-1');
      expect(label, isNot(contains('http')));
    });
  });
}
