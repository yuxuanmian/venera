import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';
import 'package:venera/network/images.dart';

void main() {
  group('ImageDownloader cache keys', () {
    test('thumbnailCacheKey includes the cid when present', () {
      expect(
        ImageDownloader.thumbnailCacheKey('https://x/c.jpg', 'src', 'cid1'),
        'https://x/c.jpg@src@cid1',
      );
    });

    test('thumbnailCacheKey omits the cid when absent', () {
      expect(
        ImageDownloader.thumbnailCacheKey('https://x/c.jpg', 'src'),
        'https://x/c.jpg@src',
      );
      expect(
        ImageDownloader.thumbnailCacheKey('https://x/c.jpg', null),
        'https://x/c.jpg@null',
      );
    });

    test('comicImageCacheKey matches the reader disk cache key format', () {
      expect(
        ImageDownloader.comicImageCacheKey(
          'https://x/p.jpg',
          'src',
          'cid1',
          'eid1',
        ),
        'https://x/p.jpg@src@cid1@eid1',
      );
    });

    test('reader provider identity does not include download priority', () {
      const foreground = ReaderImageProvider(
        'https://x/p.jpg',
        'src',
        'cid1',
        'eid1',
        1,
      );
      const preload = ReaderImageProvider(
        'https://x/p.jpg',
        'src',
        'cid1',
        'eid1',
        1,
        priority: ImageDownloadPriority.preload,
      );

      expect(foreground.key, preload.key);
      expect(foreground, preload);
      expect(foreground.hashCode, preload.hashCode);
      expect(
        ImageDownloader.comicImageCacheKey(
          foreground.imageKey,
          foreground.sourceKey,
          foreground.cid,
          foreground.eid,
        ),
        isNot(contains('preload')),
      );
    });

    test('isCoverPlaceholder recognizes placeholder covers', () {
      expect(ImageDownloader.isCoverPlaceholder('cover.xxx'), isTrue);
      expect(ImageDownloader.isCoverPlaceholder('cover.jpg'), isTrue);
      expect(ImageDownloader.isCoverPlaceholder('cover/thumb'), isTrue);
      expect(ImageDownloader.isCoverPlaceholder('cover.jpg?size=1'), isTrue);
      expect(
        ImageDownloader.isCoverPlaceholder('https://x/cover.jpg'),
        isFalse,
      );
      expect(ImageDownloader.isCoverPlaceholder('thumbnail'), isFalse);
    });
  });
}
