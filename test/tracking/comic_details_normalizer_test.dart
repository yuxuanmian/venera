import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/tracking/normalizer.dart';

void main() {
  test('normalizes detail time and the first ten chapter IDs', () {
    final details = ComicDetails.fromJson({
      'title': 'Comic',
      'cover': '',
      'tags': <String, List<String>>{},
      'chapters': {
        'chapter-12': 'Twelve',
        'chapter-11': 'Eleven',
        'chapter-10': 'Ten',
        'chapter-09': 'Nine',
        'chapter-08': 'Eight',
        'chapter-07': 'Seven',
        'chapter-06': 'Six',
        'chapter-05': 'Five',
        'chapter-04': 'Four',
        'chapter-03': 'Three',
        'chapter-02': 'Two',
      },
      'sourceKey': 'ordinary-source',
      'comicId': 'comic-1',
      'updateTime': '2026-09-02T16:15:30+08:00',
    });

    final normalized = TrackingNormalizer.fromComicDetails(details);
    expect(normalized.state?.updatedAt, DateTime.utc(2026, 9, 2, 8, 15, 30));
    expect(normalized.state?.latestChapterId, 'chapter-12');
    expect(normalized.state?.chapterCount, 11);
    expect(normalized.state?.recentChapterIds, [
      'chapter-12',
      'chapter-11',
      'chapter-10',
      'chapter-09',
      'chapter-08',
      'chapter-07',
      'chapter-06',
      'chapter-05',
      'chapter-04',
      'chapter-03',
    ]);
  });

  test('drops date-only detail time but keeps chapter evidence', () {
    final details = ComicDetails.fromJson({
      'title': 'Comic',
      'cover': '',
      'tags': <String, List<String>>{},
      'chapters': {'chapter-1': 'One'},
      'sourceKey': 'ordinary-source',
      'comicId': 'comic-1',
      'updateTime': '2026-09-02',
    });

    final normalized = TrackingNormalizer.fromComicDetails(details);
    expect(normalized.state?.updatedAt, isNull);
    expect(normalized.state?.latestChapterId, 'chapter-1');
    expect(normalized.state?.chapterCount, 1);
  });

  test('does not use chapter titles as evidence', () {
    final details = ComicDetails.fromJson({
      'title': 'Comic',
      'cover': '',
      'tags': <String, List<String>>{},
      'chapters': {'chapter-1': '2099-01-01'},
      'sourceKey': 'ordinary-source',
      'comicId': 'comic-1',
    });

    final normalized = TrackingNormalizer.fromComicDetails(details);
    expect(normalized.state?.latestChapterId, 'chapter-1');
    expect(normalized.state?.recentChapterIds, ['chapter-1']);
    expect(normalized.state?.toJson().values, isNot(contains('2099-01-01')));
  });
}
