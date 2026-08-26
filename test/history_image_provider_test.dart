import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/base_image_provider.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/image_provider/cover_recovery.dart';
import 'package:venera/foundation/image_provider/history_image_provider.dart';

History _historyWithCover(String cover, {int type = 7, String id = 'comic-1'}) {
  return History.fromMap({
    'type': type,
    'time': 0,
    'title': 'History test',
    'subtitle': '',
    'cover': cover,
    'ep': 1,
    'page': 1,
    'id': id,
    'readEpisode': <String>[],
    'max_page': null,
  });
}

final Uint8List _historyValidImageBytes = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  ),
);

DioException _historyStatusError(int statusCode) {
  final requestOptions = RequestOptions(path: 'https://example.com/cover');
  return DioException(
    requestOptions: requestOptions,
    response: Response(requestOptions: requestOptions, statusCode: statusCode),
  );
}

Future<void> _awaitImage(
  WidgetTester tester,
  ImageProvider provider, {
  required bool expectSuccess,
}) async {
  await tester.runAsync(() async {
    final stream = provider.resolve(ImageConfiguration.empty);
    final done = Completer<void>();
    stream.addListener(
      ImageStreamListener(
        (ImageInfo image, bool synchronousCall) {
          if (!done.isCompleted) {
            if (expectSuccess) {
              done.complete();
            } else {
              done.completeError(StateError('unexpected image success'));
            }
          }
        },
        onError: (Object error, StackTrace? stackTrace) {
          if (!done.isCompleted) {
            if (expectSuccess) {
              done.completeError(error, stackTrace);
            } else {
              done.complete();
            }
          }
        },
      ),
    );
    await done.future.timeout(const Duration(seconds: 10));
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late CacheManager cacheManager;

  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    tempDir = Directory.systemTemp.createTempSync('venera_history_provider_');
    cacheManager = CacheManager.test(
      cachePath: '${tempDir.path}/cache',
      dbPath: '${tempDir.path}/cache.db',
    );
    CacheManager.instance = cacheManager;
  });

  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    CacheManager.instance = null;
    cacheManager.dispose();
    tempDir.deleteSync(recursive: true);
  });

  test('history image provider key snapshots the cover URL', () {
    final history = _historyWithCover('https://example.com/old.jpg');
    final provider = HistoryImageProvider(history);
    final originalKey = provider.key;

    history.cover = 'https://example.com/new.jpg';

    expect(provider.key, originalKey);

    final updatedProvider = HistoryImageProvider(history);
    expect(updatedProvider.key, isNot(originalKey));
    expect(updatedProvider.key, contains('7'));
    expect(updatedProvider.key, contains('comic-1'));
    expect(updatedProvider.key, contains('https://example.com/new.jpg'));

    final firstAmbiguousProvider = HistoryImageProvider(
      _historyWithCover('cover', type: 1, id: '23'),
    );
    final secondAmbiguousProvider = HistoryImageProvider(
      _historyWithCover('cover', type: 12, id: '3'),
    );
    expect(firstAmbiguousProvider.key, isNot(secondAmbiguousProvider.key));
  });

  test('history image provider snapshots request identity fields', () {
    final history = _historyWithCover('https://example.com/old.jpg');
    final provider = HistoryImageProvider(history);
    final originalKey = provider.key;
    final originalRequest = provider.requestSnapshot;

    history.cover = 'https://example.com/new.jpg';
    history.id = 'changed-id';
    history.type = const ComicType(8);

    expect(provider.key, originalKey);
    expect(provider.requestSnapshot, originalRequest);

    final updatedProvider = HistoryImageProvider(history);
    expect(updatedProvider.key, isNot(originalKey));
    expect(
      updatedProvider.requestSnapshot.cover,
      'https://example.com/new.jpg',
    );
    expect(updatedProvider.requestSnapshot.id, 'changed-id');
    expect(updatedProvider.requestSnapshot.type, const ComicType(8));
  });

  test('cover persistence is limited to successful replacement URLs', () {
    expect(
      shouldPersistCoverUpdate(
        wasPlaceholder: false,
        refreshed: true,
        resolvedUrl: 'https://example.com/new.jpg',
        currentCover: 'https://example.com/old.jpg',
      ),
      isTrue,
    );
    expect(
      shouldPersistCoverUpdate(
        wasPlaceholder: false,
        refreshed: true,
        resolvedUrl: 'https://example.com/old.jpg',
        currentCover: 'https://example.com/old.jpg',
      ),
      isFalse,
    );
    expect(
      shouldPersistCoverUpdate(
        wasPlaceholder: false,
        refreshed: false,
        resolvedUrl: 'https://example.com/new.jpg',
        currentCover: 'https://example.com/old.jpg',
      ),
      isFalse,
    );
  });

  test('cached image provider key keeps field boundaries unambiguous', () {
    final first = CachedImageProvider('ab', sourceKey: 'c', cid: 'd');
    final second = CachedImageProvider('a', sourceKey: 'bc', cid: 'd');

    expect(first.key, isNot(second.key));
  });

  test(
    'a failed replacement cannot reach the cover persistence boundary',
    () async {
      var loadCalls = 0;
      CoverRecoveryResult<void>? result;

      try {
        result = await recoverCover<void>(
          initialUrl: 'https://example.com/old.jpg',
          load: (_) async {
            loadCalls++;
            if (loadCalls == 1) {
              throw Exception('Invalid Status Code: 404');
            }
            throw StateError('replacement failed');
          },
          refreshUrl: () async => 'https://example.com/new.jpg',
        );
      } catch (_) {
        // A failed replacement has no successful result to persist.
      }

      var commitCalls = 0;
      if (result != null &&
          shouldPersistCoverUpdate(
            wasPlaceholder: false,
            refreshed: result.refreshed,
            resolvedUrl: result.url,
            currentCover: 'https://example.com/old.jpg',
          )) {
        commitCalls++;
      }

      expect(loadCalls, 2);
      expect(commitCalls, 0);
    },
  );

  testWidgets(
    'decode reload does not refresh metadata again and writes once after success',
    (tester) async {
      const oldUrl = 'https://example.com/old.jpg';
      const newUrl = 'https://example.com/new.jpg';
      final history = _historyWithCover(oldUrl, id: 'decode-success');
      final requestedUrls = <String>[];
      var metadataRefreshes = 0;
      var exactReloads = 0;
      var updateCalls = 0;
      String? updatedId;
      HistoryType? updatedType;
      String? updatedExpectedCover;
      String? updatedNewCover;

      final provider = HistoryImageProvider(
        history,
        loadComicCover: () async {
          metadataRefreshes++;
          return newUrl;
        },
        loadUrl: (url, chunkEvents, checkStop, onDecodeSuccess) async {
          checkStop();
          requestedUrls.add(url);
          if (url == oldUrl) {
            throw _historyStatusError(404);
          }
          return LoadResult(
            bytes: Uint8List.fromList([1, 2, 3]),
            cacheKey: 'history-decode-success-cache',
            onDecodeSuccess: onDecodeSuccess,
            reloadAfterDecodeFailure: () async {
              exactReloads++;
              requestedUrls.add(url);
              return LoadResult(
                bytes: _historyValidImageBytes,
                cacheKey: 'history-decode-success-cache',
                onDecodeSuccess: onDecodeSuccess,
              );
            },
          );
        },
        updateCoverIfUnchanged:
            ({
              required id,
              required type,
              required expectedCover,
              required newCover,
            }) {
              updateCalls++;
              updatedId = id;
              updatedType = type;
              updatedExpectedCover = expectedCover;
              updatedNewCover = newCover;
              return true;
            },
      );

      await _awaitImage(tester, provider, expectSuccess: true);

      expect(requestedUrls, [oldUrl, newUrl, newUrl]);
      expect(metadataRefreshes, 1);
      expect(exactReloads, 1);
      expect(updateCalls, 1);
      expect(updatedId, 'decode-success');
      expect(updatedType, const ComicType(7));
      expect(updatedExpectedCover, oldUrl);
      expect(updatedNewCover, newUrl);
      expect(history.cover, newUrl);
    },
  );

  testWidgets('two decode failures do not write the refreshed cover', (
    tester,
  ) async {
    const oldUrl = 'https://example.com/old-failed.jpg';
    const newUrl = 'https://example.com/new-failed.jpg';
    final history = _historyWithCover(oldUrl, id: 'decode-failed');
    var metadataRefreshes = 0;
    var exactReloads = 0;
    var updateCalls = 0;

    final provider = HistoryImageProvider(
      history,
      loadComicCover: () async {
        metadataRefreshes++;
        return newUrl;
      },
      loadUrl: (url, chunkEvents, checkStop, onDecodeSuccess) async {
        checkStop();
        if (url == oldUrl) {
          throw _historyStatusError(410);
        }
        return LoadResult(
          bytes: Uint8List.fromList([1, 2, 3]),
          cacheKey: 'history-decode-failed-cache',
          onDecodeSuccess: onDecodeSuccess,
          reloadAfterDecodeFailure: () async {
            exactReloads++;
            return LoadResult(
              bytes: Uint8List.fromList([1, 2, 3]),
              cacheKey: 'history-decode-failed-cache',
              onDecodeSuccess: onDecodeSuccess,
            );
          },
        );
      },
      updateCoverIfUnchanged:
          ({
            required id,
            required type,
            required expectedCover,
            required newCover,
          }) {
            updateCalls++;
            return true;
          },
    );

    await _awaitImage(tester, provider, expectSuccess: false);

    expect(metadataRefreshes, 1);
    expect(exactReloads, 1);
    expect(updateCalls, 0);
    expect(history.cover, oldUrl);
  });

  testWidgets(
    'a rejected conditional update does not overwrite a newer cover',
    (tester) async {
      const oldUrl = 'https://example.com/old-race.jpg';
      const newUrl = 'https://example.com/new-race.jpg';
      const newerUrl = 'https://example.com/newer-race.jpg';
      final history = _historyWithCover(oldUrl, id: 'decode-race');
      var updateCalls = 0;
      String? updatedId;
      HistoryType? updatedType;
      String? updatedExpectedCover;
      String? updatedNewCover;

      final provider = HistoryImageProvider(
        history,
        loadComicCover: () async => newUrl,
        loadUrl: (url, chunkEvents, checkStop, onDecodeSuccess) async {
          checkStop();
          if (url == oldUrl) {
            throw _historyStatusError(404);
          }
          history.cover = newerUrl;
          return LoadResult(
            bytes: _historyValidImageBytes,
            cacheKey: 'history-decode-race-cache',
            onDecodeSuccess: onDecodeSuccess,
          );
        },
        updateCoverIfUnchanged:
            ({
              required id,
              required type,
              required expectedCover,
              required newCover,
            }) {
              updateCalls++;
              updatedId = id;
              updatedType = type;
              updatedExpectedCover = expectedCover;
              updatedNewCover = newCover;
              return false;
            },
      );

      await _awaitImage(tester, provider, expectSuccess: true);

      expect(updateCalls, 1);
      expect(updatedId, 'decode-race');
      expect(updatedType, const ComicType(7));
      expect(updatedExpectedCover, oldUrl);
      expect(updatedNewCover, newUrl);
      expect(history.cover, newerUrl);
    },
  );
}
