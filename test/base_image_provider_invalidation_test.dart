import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_provider/base_image_provider.dart';

/// A provider that always returns fixed bytes plus the disk cache key they
/// came from, so the decode-failure invalidation path can be exercised
/// without a real network or a comic source.
class _PoisonedProvider extends BaseImageProvider<_PoisonedProvider> {
  _PoisonedProvider(this.cacheKey, this.bytes);

  final String? cacheKey;
  final Uint8List bytes;

  @override
  Future<LoadResult> load(chunkEvents, checkStop) async {
    return (bytes: bytes, cacheKey: cacheKey);
  }

  @override
  Future<_PoisonedProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => 'poisoned-test-provider';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late CacheManager manager;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('venera_invalidation_test');
    manager = CacheManager.test(
      cachePath: '${tempDir.path}/cache',
      dbPath: '${tempDir.path}/cache.db',
    );
    // BaseImageProvider goes through the CacheManager() singleton.
    CacheManager.instance = manager;
  });

  tearDown(() {
    CacheManager.instance = null;
    manager.dispose();
    tempDir.deleteSync(recursive: true);
  });

  /// Resolves [provider] and waits until the image stream reports an error.
  ///
  /// Everything runs inside [WidgetTester.runAsync]: resolving an image
  /// involves real engine calls (ImmutableBuffer, codec), which never
  /// complete under the test's fake-async zone.
  Future<void> expectImageError(
    WidgetTester tester,
    _PoisonedProvider provider,
  ) async {
    await tester.runAsync(() async {
      final stream = provider.resolve(ImageConfiguration.empty);
      final done = Completer<void>();
      stream.addListener(
        ImageStreamListener(
          (ImageInfo image, bool synchronousCall) {},
          onError: (Object error, StackTrace? stackTrace) {
            if (!done.isCompleted) {
              done.complete();
            }
          },
        ),
      );
      await done.future.timeout(const Duration(seconds: 10));
    });
  }

  testWidgets('a poisoned cache entry is purged when decoding fails', (
    tester,
  ) async {
    const cacheKey = 'https://x/cover.jpg@src@cid1';
    final provider = _PoisonedProvider(cacheKey, Uint8List.fromList([1, 2, 3]));

    await tester.runAsync(() async {
      await CacheManager().writeCache(cacheKey, [1, 2, 3]);
      expect(await CacheManager().findCache(cacheKey), isNotNull);
    });

    await expectImageError(tester, provider);

    expect(
      await tester.runAsync(() => CacheManager().findCache(cacheKey)),
      isNull,
      reason: 'the poisoned entry must be deleted on decode failure',
    );
  });

  testWidgets('bytes without a cache key do not purge unrelated entries', (
    tester,
  ) async {
    const cacheKey = 'https://x/cover.jpg@src@cid1';
    await tester.runAsync(() async {
      await CacheManager().writeCache(cacheKey, [1, 2, 3]);
    });

    // cacheKey == null: local files and other non-cached bytes must not
    // trigger any cache deletion.
    final provider = _PoisonedProvider(null, Uint8List.fromList([1, 2, 3]));
    await expectImageError(tester, provider);

    expect(
      await tester.runAsync(() => CacheManager().findCache(cacheKey)),
      isNotNull,
      reason: 'unrelated cache entries must survive',
    );
  });
}
