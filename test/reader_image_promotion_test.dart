import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';
import 'package:venera/network/images.dart';

class _FakeImageStreamCompleter extends ImageStreamCompleter {}

void main() {
  testWidgets(
    'foreground resolve promotes before reusing the preload completer',
    (tester) async {
      final cache = PaintingBinding.instance.imageCache;
      cache.clear();

      var cacheLoaderCalls = 0;
      var promotionCalls = 0;
      final preload = const ReaderImageProvider(
        'https://x/p.jpg',
        'src',
        'cid1',
        'eid1',
        1,
        priority: ImageDownloadPriority.preload,
      );
      final foreground = ReaderImageProvider(
        'https://x/p.jpg',
        'src',
        'cid1',
        'eid1',
        1,
        onForegroundPromotion: () => promotionCalls++,
      );

      try {
        expect(foreground, preload);
        expect(foreground.key, preload.key);

        final preloadCompleter = cache.putIfAbsent(preload, () {
          cacheLoaderCalls++;
          return _FakeImageStreamCompleter();
        });
        expect(preloadCompleter, isNotNull);

        final preloadStream = preload.resolve(ImageConfiguration.empty);
        await tester.pump();
        expect(preloadStream.completer, same(preloadCompleter));
        expect(promotionCalls, 0);

        // The equal foreground provider finds the pending completer, so its
        // loadImage callback is not run. obtainKey still runs first and must
        // promote the in-flight downloader request.
        final foregroundStream = foreground.resolve(ImageConfiguration.empty);
        await tester.pump();
        expect(foregroundStream.completer, same(preloadCompleter));
        expect(cacheLoaderCalls, 1);
        expect(promotionCalls, 1);

        final repeatedForegroundStream = foreground.resolve(
          ImageConfiguration.empty,
        );
        await tester.pump();
        expect(repeatedForegroundStream.completer, same(preloadCompleter));
        expect(cacheLoaderCalls, 1);
        expect(promotionCalls, 2);
      } finally {
        cache.clear();
      }
    },
  );

  test('preload and local file resolve do not promote', () async {
    var promotionCalls = 0;
    const preload = ReaderImageProvider(
      'https://x/p.jpg',
      'src',
      'cid1',
      'eid1',
      1,
      priority: ImageDownloadPriority.preload,
    );
    final local = ReaderImageProvider(
      'file://reader-page',
      null,
      'cid1',
      'eid1',
      1,
      onForegroundPromotion: () => promotionCalls++,
    );

    await preload.obtainKey(ImageConfiguration.empty);
    await local.obtainKey(ImageConfiguration.empty);

    expect(promotionCalls, 0);
  });

  test('promotion without an in-flight wrapper is a no-op', () {
    expect(
      ImageDownloader.promoteComicImage(
        'https://x/not-loading.jpg',
        'src',
        'cid1',
        'eid1',
      ),
      isFalse,
    );
  });

  test('promotion of an in-flight wrapper is idempotent', () {
    ImageDownloader.cancelAllLoadingImages();
    try {
      ImageDownloader.loadComicImage(
        'https://x/queued.jpg',
        'src',
        'cid1',
        'eid1',
        priority: ImageDownloadPriority.preload,
      );

      expect(
        ImageDownloader.promoteComicImage(
          'https://x/queued.jpg',
          'src',
          'cid1',
          'eid1',
        ),
        isTrue,
      );
      expect(
        ImageDownloader.promoteComicImage(
          'https://x/queued.jpg',
          'src',
          'cid1',
          'eid1',
        ),
        isTrue,
      );
    } finally {
      ImageDownloader.cancelAllLoadingImages();
    }

    expect(
      ImageDownloader.promoteComicImage(
        'https://x/queued.jpg',
        'src',
        'cid1',
        'eid1',
      ),
      isFalse,
    );
  });
}
