import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/image.dart';

import 'app_dio.dart';

abstract class ImageDownloader {
  /// Limits concurrent comic image downloads so fast scrolling into an
  /// unbuffered region cannot start dozens of downloads at once (memory
  /// spikes, GC pauses and frame drops).
  static final _downloadSemaphore = _DownloadSemaphore(3);

  static Stream<ImageDownloadProgress> loadThumbnail(
    String url,
    String? sourceKey, [
    String? cid,
  ]) async* {
    final cacheKey = "$url@$sourceKey${cid != null ? '@$cid' : ''}";
    final cache = await CacheManager().findCache(cacheKey);

    if (cache != null) {
      var data = await cache.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
      // Without this return the generator falls through to the network path,
      // and consumers that drain the stream (e.g. the pre-download wrapper)
      // would re-download already cached images.
      return;
    }

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs = comicSource?.getThumbnailLoadingConfig?.call(url) ?? {};
    }
    configs['headers'] ??= {};
    if (configs['headers']['user-agent'] == null &&
        configs['headers']['User-Agent'] == null) {
      configs['headers']['user-agent'] = webUA;
    }

    if (((configs['url'] as String?) ?? url).startsWith('cover.') &&
        sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      if (comicSource != null) {
        var comicInfo = await comicSource.loadComicInfo!(cid!);
        yield* loadThumbnail(comicInfo.data.cover, sourceKey);
        return;
      }
    }

    var dio = AppDio(
      BaseOptions(
        headers: Map<String, dynamic>.from(configs['headers']),
        method: configs['method'] ?? 'GET',
        responseType: ResponseType.stream,
        extra: {'veneraImage': true},
      ),
    );

    String requestUrl = configs['url'] ?? url;
    if (requestUrl.startsWith('//')) {
      requestUrl = 'https:$requestUrl';
    }
    var req = await dio.request<ResponseBody>(
      requestUrl,
      data: configs['data'],
    );
    var stream = req.data?.stream ?? (throw "Error: Empty response body.");
    int? expectedBytes = req.data!.contentLength;
    if (expectedBytes == -1) {
      expectedBytes = null;
    }
    var buffer = <int>[];
    await for (var data in stream) {
      buffer.addAll(data);
      if (expectedBytes != null) {
        yield ImageDownloadProgress(
          currentBytes: buffer.length,
          totalBytes: expectedBytes,
        );
      }
    }

    if (configs['onResponse'] is JSInvokable) {
      final uint8List = Uint8List.fromList(buffer);
      buffer = (configs['onResponse'] as JSInvokable)([uint8List]);
      (configs['onResponse'] as JSInvokable).free();
    }

    await CacheManager().writeCache(cacheKey, buffer);
    yield ImageDownloadProgress(
      currentBytes: buffer.length,
      totalBytes: buffer.length,
      imageBytes: Uint8List.fromList(buffer),
    );
  }

  static final _loadingImages =
      <String, _StreamWrapper<ImageDownloadProgress>>{};

  /// Cancel all loading images.
  static void cancelAllLoadingImages() {
    for (var wrapper in _loadingImages.values) {
      wrapper.cancel();
    }
    _loadingImages.clear();
  }

  /// Load a comic image from the network or cache.
  /// The function will prevent multiple requests for the same image.
  static Stream<ImageDownloadProgress> loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    if (_loadingImages.containsKey(cacheKey)) {
      return _loadingImages[cacheKey]!.stream;
    }
    final cancelToken = CancelToken();
    final stream = _StreamWrapper<ImageDownloadProgress>(
      _loadComicImage(imageKey, sourceKey, cid, eid, cancelToken),
      (wrapper) {
        _loadingImages.remove(cacheKey);
      },
      onCancel: () {
        // The Dio cancel token completes the adapter's cancelFuture, which
        // aborts the underlying rhttp request instead of leaving it running
        // in the background.
        cancelToken.cancel();
      },
    );
    _loadingImages[cacheKey] = stream;
    return stream.stream;
  }

  static Stream<ImageDownloadProgress> loadComicImageUnwrapped(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    return _loadComicImage(imageKey, sourceKey, cid, eid, CancelToken());
  }

  static Stream<ImageDownloadProgress> _loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
    CancelToken cancelToken,
  ) async* {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    final cache = await CacheManager().findCache(cacheKey);

    if (cache != null) {
      var data = await cache.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
      // Without this return the generator falls through to the network path,
      // and consumers that drain the stream (e.g. the pre-download wrapper)
      // would re-download already cached images.
      return;
    }

    // Total load time including queue wait and retries; only the network
    // download path reaches this point.
    final totalWatch = Stopwatch()..start();

    Future<Map<String, dynamic>?> Function()? onLoadFailed;

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs =
          (await comicSource!.getImageLoadingConfig?.call(
            imageKey,
            cid,
            eid,
          )) ??
          {};
    }
    var retryLimit = 5;
    while (true) {
      try {
        configs['headers'] ??= {'user-agent': webUA};

        if (configs['onLoadFailed'] is JSInvokable) {
          onLoadFailed = () async {
            dynamic result = (configs['onLoadFailed'] as JSInvokable)([]);
            if (result is Future) {
              result = await result;
            }
            if (result is! Map<String, dynamic>) return null;
            return result;
          };
        }

        var dio = AppDio(
          BaseOptions(
            headers: configs['headers'],
            method: configs['method'] ?? 'GET',
            responseType: ResponseType.stream,
            extra: {'veneraImage': true},
          ),
        );

        final queueWatch = Stopwatch()..start();
        await _downloadSemaphore.acquire();
        queueWatch.stop();
        try {
          // The request future completes when the response headers arrive,
          // so this measures connection + TLS + time to first byte.
          final connectWatch = Stopwatch()..start();
          var req = await dio.request<ResponseBody>(
            configs['url'] ?? imageKey,
            data: configs['data'],
            cancelToken: cancelToken,
          );
          connectWatch.stop();
          var stream =
              req.data?.stream ?? (throw "Error: Empty response body.");
          int? expectedBytes = req.data!.contentLength;
          if (expectedBytes == -1) {
            expectedBytes = null;
          }
          // Accumulate chunks without repeated copying.
          final downloadWatch = Stopwatch()..start();
          final builder = BytesBuilder(copy: false);
          await for (var data in stream) {
            builder.add(data);
            yield ImageDownloadProgress(
              currentBytes: builder.length,
              totalBytes: expectedBytes,
            );
          }
          downloadWatch.stop();

          Uint8List data;
          if (configs['onResponse'] is JSInvokable) {
            dynamic result = (configs['onResponse'] as JSInvokable)([
              builder.takeBytes(),
            ]);
            if (result is Future) {
              result = await result;
            }
            if (result is List<int>) {
              data = result is Uint8List ? result : Uint8List.fromList(result);
            } else {
              throw "Error: Invalid onResponse result.";
            }
            (configs['onResponse'] as JSInvokable).free();
          } else {
            data = builder.takeBytes();
          }

          if (configs['modifyImage'] != null) {
            var newData = await modifyImageWithScript(
              data,
              configs['modifyImage'],
            );
            data = newData;
          }

          await CacheManager().writeCache(cacheKey, data);
          if (kDebugMode) {
            // Debug-only timing breakdown: one self-contained line per image
            // (actual request URL first) so concurrent downloads stay
            // greppable. queue = waiting for a download slot, connect =
            // TCP/TLS + first byte, download = body transfer, total =
            // everything incl. retries and the cache write.
            final requestUrl = (configs['url'] as String?) ?? imageKey;
            Log.info(
              "Image",
              "$requestUrl${requestUrl != imageKey ? ' (key=$imageKey)' : ''} -> "
                  "queue=${queueWatch.elapsedMilliseconds}ms "
                  "connect=${connectWatch.elapsedMilliseconds}ms "
                  "download=${downloadWatch.elapsedMilliseconds}ms "
                  "total=${totalWatch.elapsedMilliseconds}ms "
                  "size=${(data.length / 1024).toStringAsFixed(1)}KB",
            );
          }
          yield ImageDownloadProgress(
            currentBytes: data.length,
            totalBytes: data.length,
            imageBytes: data,
          );
        } finally {
          _downloadSemaphore.release();
        }
        return;
      } catch (e) {
        if (e is DioException && e.type == DioExceptionType.cancel) {
          // A cancelled image must not be retried through onLoadFailed.
          rethrow;
        }
        if (retryLimit < 0 || onLoadFailed == null) {
          rethrow;
        }
        var newConfig = await onLoadFailed();
        (configs['onLoadFailed'] as JSInvokable).free();
        onLoadFailed = null;
        if (newConfig == null) {
          rethrow;
        }
        configs = newConfig;
        retryLimit--;
      } finally {
        if (onLoadFailed != null) {
          (configs['onLoadFailed'] as JSInvokable).free();
        }
      }
    }
  }
}

/// A wrapper class for a stream that
/// allows multiple listeners to listen to the same stream.
class _StreamWrapper<T> {
  final Stream<T> _stream;

  final List<StreamController> controllers = [];

  final void Function(_StreamWrapper<T> wrapper) onClosed;

  /// Called when [cancel] is invoked, so the underlying transfer can be
  /// aborted instead of continuing in the background.
  final void Function()? onCancel;

  bool isClosed = false;

  _StreamWrapper(this._stream, this.onClosed, {this.onCancel}) {
    _listen();
  }

  void _listen() async {
    try {
      await for (var data in _stream) {
        if (isClosed) {
          break;
        }
        for (var controller in controllers) {
          if (!controller.isClosed) {
            controller.add(data);
          }
        }
      }
    } catch (e) {
      for (var controller in controllers) {
        if (!controller.isClosed) {
          controller.addError(e);
        }
      }
    } finally {
      for (var controller in controllers) {
        if (!controller.isClosed) {
          controller.close();
        }
      }
    }
    controllers.clear();
    isClosed = true;
    onClosed(this);
  }

  Stream<T> get stream {
    if (isClosed) {
      throw Exception('Stream is closed');
    }
    var controller = StreamController<T>();
    controllers.add(controller);
    controller.onCancel = () {
      controllers.remove(controller);
    };
    return controller.stream;
  }

  void cancel() {
    for (var controller in controllers) {
      controller.close();
    }
    controllers.clear();
    isClosed = true;
    onCancel?.call();
  }
}

class ImageDownloadProgress {
  final int currentBytes;

  final int? totalBytes;

  final Uint8List? imageBytes;

  const ImageDownloadProgress({
    required this.currentBytes,
    required this.totalBytes,
    this.imageBytes,
  });
}

/// A simple counting semaphore limiting concurrent image downloads.
class _DownloadSemaphore {
  final int max;

  int _count = 0;

  final List<Completer<void>> _waiters = [];

  _DownloadSemaphore(this.max);

  Future<void> acquire() async {
    if (_count < max) {
      _count++;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _count--;
    }
  }
}
