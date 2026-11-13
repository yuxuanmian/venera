import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/scan/observation_codec.dart';

void main() {
  const codec = ObservationCodec();

  test(
    'a bad item rejects the whole page without mutating prior identities',
    () {
      final seen = <String>{'already-committed'};

      expect(
        () => codec.decodeCollectionPage({
          'items': [
            {
              'comicId': 'valid',
              'observation': {'sourceUnread': false},
            },
            {
              'comicId': 42,
              'observation': {'sourceUnread': true},
            },
          ],
          'next': 'page-2',
        }, seenComicIds: seen),
        throwsA(isA<ScanCodecException>()),
      );
      expect(seen, {'already-committed'});
    },
  );

  test(
    'false, zero, and empty-string cursors are explicit continuation values',
    () {
      for (final cursor in <Object?>[false, 0, '']) {
        final page = codec.decodeCollectionPage({'items': [], 'next': cursor});
        expect(page.isTerminal, isFalse);
        expect(page.next, cursor);
      }
    },
  );

  test('missing next and duplicate identities are collection failures', () {
    expect(
      () => codec.decodeCollectionPage({'items': []}),
      throwsA(isA<ScanCodecException>()),
    );
    expect(
      () => codec.decodeCollectionPage({
        'items': [
          {
            'comicId': 'same',
            'observation': {'sourceUnread': true},
          },
          {
            'comicId': 'same',
            'observation': {'sourceUnread': false},
          },
        ],
        'next': null,
      }),
      throwsA(isA<ScanCodecException>()),
    );
  });

  test('malformed update does not discard a valid unread fact', () {
    final page = codec.decodeCollectionPage({
      'items': [
        {
          'comicId': 'bad-update-false',
          'observation': {'update': 42, 'sourceUnread': false},
        },
        {
          'comicId': 'bad-update-true',
          'observation': {'update': 'bad', 'sourceUnread': true},
        },
      ],
      'next': null,
    });
    expect(page.items.map((item) => item.observation!.sourceUnread), [
      false,
      true,
    ]);
    expect(
      page.items.every((item) => item.observation!.update == null),
      isTrue,
    );
  });

  test('an observation with no valid facts is still rejected', () {
    expect(
      () => codec.decodeCollectionPage({
        'items': [
          {
            'comicId': 'empty',
            'observation': {'update': [], 'sourceUnread': 'not-bool'},
          },
        ],
        'next': null,
      }),
      throwsA(isA<ScanCodecException>()),
    );
  });

  test('item failures require explicit capability support', () {
    const raw = {
      'items': [
        {
          'comicId': 'failed',
          'failure': {
            'sourceCode': 'ERR_CHAPTER_COUNT',
            'message': 'Chapter count is invalid',
          },
        },
      ],
      'next': null,
    };

    expect(
      () => codec.decodeCollectionPage(raw),
      throwsA(isA<ScanCodecException>()),
    );

    final page = codec.decodeCollectionPage(raw, allowItemFailures: true);
    expect(page.items.single.isSuccess, isFalse);
    expect(page.items.single.failure!.sourceCode, 'ERR_CHAPTER_COUNT');
  });

  test('item failure payloads remain XOR and participate in ID checks', () {
    expect(
      () => codec.decodeCollectionPage({
        'items': [
          {
            'comicId': 'same',
            'observation': {'sourceUnread': true},
            'failure': {'message': 'ambiguous'},
          },
        ],
        'next': null,
      }, allowItemFailures: true),
      throwsA(isA<ScanCodecException>()),
    );
    expect(
      () => codec.decodeCollectionPage({
        'items': [
          {
            'comicId': 'same',
            'failure': {'message': 'first'},
          },
          {
            'comicId': 'same',
            'observation': {'sourceUnread': false},
          },
        ],
        'next': null,
      }, allowItemFailures: true),
      throwsA(isA<ScanCodecException>()),
    );
    expect(
      () => codec.decodeCollectionPage(
        {
          'items': [
            {
              'comicId': 'already-seen',
              'failure': {'message': 'known failure'},
            },
          ],
          'next': null,
        },
        seenComicIds: {'already-seen'},
        allowItemFailures: true,
      ),
      throwsA(isA<ScanCodecException>()),
    );
  });
}
