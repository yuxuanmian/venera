import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

String _utf8StringWithBytes(int bytes) {
  final full = bytes ~/ 3;
  final remainder = bytes % 3;
  return '界' * full +
      (remainder == 1
          ? 'a'
          : remainder == 2
          ? 'ab'
          : '');
}

void main() {
  test('accepts state-only, marker-only, and sourceUnread-only hints', () {
    final stateOnly = FavoriteUpdateHint.fromJson({
      'state': {'latestChapterId': 'chapter-1'},
    });
    expect(stateOnly?.state?.latestChapterId, 'chapter-1');
    expect(stateOnly?.marker, isNull);

    final markerOnly = FavoriteUpdateHint.fromJson({'marker': 'opaque-1'});
    expect(markerOnly?.marker, 'opaque-1');
    expect(markerOnly?.state, isNull);

    final unreadOnly = FavoriteUpdateHint.fromJson({'sourceUnread': true});
    expect(unreadOnly?.sourceUnread, isTrue);
    expect(unreadOnly?.state, isNull);
    expect(unreadOnly?.marker, isNull);
  });

  test('adapts legacy aliases and prefers new fields on conflict', () {
    final legacy = FavoriteUpdateHint.fromJson({
      'updateTime': '2026-09-02T08:15:30+00:00',
      'isNew': true,
      'marker': 'legacy-marker',
      'markerScheme': 'legacy-v1',
    });
    expect(legacy?.state?.updatedAt, DateTime.utc(2026, 9, 2, 8, 15, 30));
    expect(legacy?.sourceUnread, isTrue);

    final conflict = FavoriteUpdateHint.fromJson({
      'state': {'latestChapterId': 'new-chapter'},
      'updateTime': '2026-09-01T00:00:00Z',
      'sourceUnread': false,
      'isNew': true,
      'marker': 'new-marker',
    });
    expect(conflict?.state?.latestChapterId, 'new-chapter');
    expect(conflict?.sourceUnread, isFalse);
  });

  test('drops invalid fields without dropping valid evidence', () {
    final hint = FavoriteUpdateHint.fromJson({
      'state': {
        'updatedAt': 'not-a-date',
        'latestChapterId': ' chapter-2 ',
        'chapterCount': -1,
      },
      'sourceUnread': 'invalid',
      'marker': '  opaque-2  ',
    });
    expect(hint?.state?.updatedAt, isNull);
    expect(hint?.state?.latestChapterId, 'chapter-2');
    expect(hint?.state?.chapterCount, isNull);
    expect(hint?.marker, 'opaque-2');
    expect(hint?.sourceUnread, isNull);
  });

  test('enforces marker and metadata UTF-8 byte limits', () {
    final markerAtLimit = _utf8StringWithBytes(4096);
    final markerOverLimit = _utf8StringWithBytes(4097);
    expect(utf8.encode(markerAtLimit), hasLength(4096));
    expect(utf8.encode(markerOverLimit), hasLength(4097));
    expect(
      FavoriteUpdateHint.fromJson({'marker': markerAtLimit})?.marker,
      markerAtLimit,
    );
    expect(
      FavoriteUpdateHint.fromJson({'marker': markerOverLimit})?.marker,
      isNull,
    );

    final metadataAtLimit = <String, dynamic>{
      'value': _utf8StringWithBytes(4084),
    };
    final metadataOverLimit = <String, dynamic>{
      'value': _utf8StringWithBytes(4085),
    };
    expect(
      utf8.encode(jsonEncode(metadataAtLimit)).length,
      lessThanOrEqualTo(4096),
    );
    expect(
      utf8.encode(jsonEncode(metadataOverLimit)).length,
      greaterThan(4096),
    );
    expect(
      FavoriteUpdateHint.fromJson({'metadata': metadataAtLimit})?.metadata,
      metadataAtLimit,
    );
    expect(
      FavoriteUpdateHint.fromJson({'metadata': metadataOverLimit})?.metadata,
      isNull,
    );
  });
}
