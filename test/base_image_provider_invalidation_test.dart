import 'dart:async';
import 'dart:convert';
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
    return LoadResult(bytes: bytes, cacheKey: cacheKey);
  }

  @override
  Future<_PoisonedProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => 'poisoned-test-provider';
}

final Uint8List _validImageBytes = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  ),
);

class _DecodeReloadProvider extends BaseImageProvider<_DecodeReloadProvider> {
  _DecodeReloadProvider(this.reloadBytes);

  final Uint8List reloadBytes;
  var loadCalls = 0;
  var exactReloadCalls = 0;
  var onDecodeSuccessCalls = 0;

  LoadResult _result(Uint8List bytes, {required bool canReload}) {
    return LoadResult(
      bytes: bytes,
      cacheKey: 'decode-reload-test-cache',
      onDecodeSuccess: () => onDecodeSuccessCalls++,
      reloadAfterDecodeFailure: canReload
          ? () async {
              exactReloadCalls++;
              return _result(reloadBytes, canReload: false);
            }
          : null,
    );
  }

  @override
  Future<LoadResult> load(chunkEvents, checkStop) async {
    loadCalls++;
    return _result(Uint8List.fromList([1, 2, 3]), canReload: true);
  }

  @override
  Future<_DecodeReloadProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => 'decode-reload-test-provider-${reloadBytes.length}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late CacheManager manager;

  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    tempDir = Directory.systemTemp.createTempSync('venera_invalidation_test');
    manager = CacheManager.test(
      cachePath: '${tempDir.path}/cache',
      dbPath: '${tempDir.path}/cache.db',
    );
    // BaseImageProvider goes through the CacheManager() singleton.
    CacheManager.instance = manager;
  });

  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
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
    ImageProvider provider,
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

  testWidgets(
    'decode failure reloads the exact result without calling provider.load',
    (tester) async {
      final provider = _DecodeReloadProvider(_validImageBytes);

      await tester.runAsync(() async {
        final stream = provider.resolve(ImageConfiguration.empty);
        final done = Completer<void>();
        stream.addListener(
          ImageStreamListener(
            (ImageInfo image, bool synchronousCall) {
              if (!done.isCompleted) {
                done.complete();
              }
            },
            onError: (Object error, StackTrace? stackTrace) {
              if (!done.isCompleted) {
                done.completeError(error, stackTrace);
              }
            },
          ),
        );
        await done.future.timeout(const Duration(seconds: 10));
      });

      expect(provider.loadCalls, 1);
      expect(provider.exactReloadCalls, 1);
      expect(provider.onDecodeSuccessCalls, 1);
    },
  );

  testWidgets('two decode failures never call onDecodeSuccess', (tester) async {
    final provider = _DecodeReloadProvider(Uint8List.fromList([1, 2, 3]));

    await expectImageError(tester, provider);

    expect(provider.loadCalls, 1);
    expect(provider.exactReloadCalls, 1);
    expect(provider.onDecodeSuccessCalls, 0);
  });
}
