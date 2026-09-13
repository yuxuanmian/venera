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
    expect(page.items.map((item) => item.observation.sourceUnread), [
      false,
      true,
    ]);
    expect(page.items.every((item) => item.observation.update == null), isTrue);
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
}
