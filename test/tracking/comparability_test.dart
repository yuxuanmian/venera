import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tracking/comparability.dart';

void main() {
  group('ComparableLabel.validate (Contract C6)', () {
    test('accepts each known field name', () {
      for (final field in comparableLabelKnownFields) {
        final declaration = <String, String>{field: 'source.field'};
        expect(
          ComparableLabel.validate(declaration).isValid,
          isTrue,
          reason: field,
        );
      }
    });

    test('rejects an unknown field name, including a mis-cased spelling', () {
      for (final key in const [
        'updatedat',
        'LatestChapterId',
        'chapter_count',
        'source_unread',
        'marker',
      ]) {
        final result = ComparableLabel.validate(<String, String>{
          key: 'source.field',
        });
        expect(result.isValid, isFalse, reason: key);
        expect(result.reason, contains('unknown field'));
      }
    });

    test('rejects a granularity marker on a non-time field', () {
      final result = ComparableLabel.validate(<String, String>{
        'latestChapterId': 'last_chapter.id@day',
      });
      expect(result.isValid, isFalse);
      expect(result.reason, contains('only updatedAt'));
    });

    test('accepts both granularities on updatedAt', () {
      for (final granularity in const ['day', 'instant']) {
        expect(
          ComparableLabel.validate(<String, String>{
            'updatedAt': 'updated_at@$granularity',
          }).isValid,
          isTrue,
          reason: granularity,
        );
      }
    });

    test('rejects an unknown granularity', () {
      expect(
        ComparableLabel.validate(<String, String>{
          'updatedAt': 'updated_at@week',
        }).isValid,
        isFalse,
      );
    });

    test('rejects an empty declaration', () {
      final result = ComparableLabel.validate(<String, String>{});
      expect(result.isValid, isFalse);
      expect(result.reason, contains('at least one field'));
    });

    test('rejects non-object declarations', () {
      expect(ComparableLabel.validate(null).isValid, isFalse);
      expect(ComparableLabel.validate(<Object?>[]).isValid, isFalse);
      expect(ComparableLabel.validate('comic').isValid, isFalse);
    });

    test('rejects a non-string value', () {
      final result = ComparableLabel.validate(<Object?, Object?>{
        'latestChapterId': 42,
      });
      expect(result.isValid, isFalse);
      expect(result.reason, contains('must map to a string'));
    });
  });

  group('ComparableLabel.of (Contract C5)', () {
    test('is order independent', () {
      final first = ComparableLabel.of(const {
        'latestChapterId': 'last_chapter.id',
        'sourceUnread': 'is_new|full_is_new',
      });
      final second = ComparableLabel.of(const {
        'sourceUnread': 'is_new|full_is_new',
        'latestChapterId': 'last_chapter.id',
      });
      expect(first, second);
    });

    test('normalizes case and surrounding whitespace', () {
      expect(
        ComparableLabel.of(const {'latestChapterId': '  Last_Chapter.ID  '}),
        ComparableLabel.of(const {'latestChapterId': 'last_chapter.id'}),
      );
    });

    test('does not fold separators', () {
      expect(
        ComparableLabel.of(const {'latestChapterId': 'last_chapter.id'}),
        isNot(ComparableLabel.of(const {'latestChapterId': 'last-chapter-id'})),
      );
    });

    test('two identical declarations yield one label', () {
      const declaration = {
        'updatedAt': 'updated_at@day',
        'latestChapterId': 'last_chapter.id',
      };
      expect(
        ComparableLabel.of(declaration),
        ComparableLabel.of(Map<String, String>.from(declaration)),
      );
    });

    test('different declarations yield different labels', () {
      expect(
        ComparableLabel.of(const {'updatedAt': 'updated_at@day'}),
        isNot(ComparableLabel.of(const {'updatedAt': 'updated_at@instant'})),
      );
    });
  });

  group('ComparableLabel.matches (Contract C7)', () {
    test('a missing recorded label never matches', () {
      expect(ComparableLabel.matches(null, labelOf()), isFalse);
    });

    test('matches only the identical label', () {
      final current = labelOf();
      expect(ComparableLabel.matches(current, current), isTrue);
      expect(ComparableLabel.matches('{"other":"x"}', current), isFalse);
    });
  });
}

String labelOf() =>
    ComparableLabel.of(const {'latestChapterId': 'last_chapter.id'});
