import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/image.dart';

import 'app_dio.dart';

enum ImageDownloadPriority { foreground, preload }

/// A small priority-aware permit scheduler for comic image downloads.
///
/// Foreground work is always selected before queued preload work. Preloads
/// have their own cap so a burst of adjacent-page requests cannot consume all
/// network slots before the currently visible page gets a chance to start.
@visibleForTesting
class ImageDownloadScheduler {
  ImageDownloadScheduler({this.maxConcurrent = 3, this.maxPreload = 2}) {
    if (maxConcurrent <= 0) {
      throw ArgumentError.value(maxConcurrent, 'maxConcurrent');
    }
    if (maxPreload < 0 || maxPreload > maxConcurrent) {
      throw ArgumentError.value(maxPreload, 'maxPreload');
    }
  }

  final int maxConcurrent;

  final int maxPreload;

  final List<ImageDownloadTicket> _waiting = [];

  int _active = 0;

  int _activePreload = 0;

  int get activeCount => _active;

  int get activePreloadCount => _activePreload;

  int get waitingCount => _waiting.length;

  ImageDownloadTicket acquire(ImageDownloadPriority priority) {
    final ticket = ImageDownloadTicket._(this, priority);
    _waiting.add(ticket);
    _drain();
    return ticket;
  }

  void release(ImageDownloadTicket ticket) {
    if (ticket._scheduler != this || !ticket._granted || ticket._released) {
      return;
    }
    ticket._released = true;
    _active--;
    if (ticket._countsAsPreload) {
      _activePreload--;
    }
    _drain();
  }

  void _promote(ImageDownloadTicket ticket) {
    if (ticket._scheduler != this ||
        ticket._cancelled ||
        ticket._granted ||
        ticket._priority == ImageDownloadPriority.foreground) {
      return;
    }
    ticket._priority = ImageDownloadPriority.foreground;
    _drain();
  }

  void _cancel(ImageDownloadTicket ticket) {
    if (ticket._scheduler != this || ticket._cancelled) return;
    ticket._cancelled = true;
    if (!ticket._granted) {
      _waiting.remove(ticket);
      ticket._complete();
      _drain();
    }
  }

  void _drain() {
    while (_active < maxConcurrent) {
      ImageDownloadTicket? next;
      for (final ticket in _waiting) {
        if (!ticket._cancelled &&
            ticket._priority == ImageDownloadPriority.foreground) {
          next = ticket;
          break;
        }
      }
      if (next == null && _activePreload < maxPreload) {
        for (final ticket in _waiting) {
          if (!ticket._cancelled &&
              ticket._priority == ImageDownloadPriority.preload) {
            next = ticket;
            break;
          }
        }
      }
      if (next == null) return;
      _waiting.remove(next);
      _active++;
      next._grant();
      if (next._countsAsPreload) {
        _activePreload++;
      }
    }
  }
}

@visibleForTesting
class ImageDownloadTicket {
  ImageDownloadTicket._(this._scheduler, this._priority);

  final ImageDownloadScheduler _scheduler;

  final Completer<void> _completer = Completer<void>();

  ImageDownloadPriority _priority;

  bool _granted = false;

  bool _released = false;

  bool _cancelled = false;

  bool _countsAsPreload = false;

  Future<void> get granted => _completer.future;

  ImageDownloadPriority get priority => _priority;

  bool get isGranted => _granted;

  bool get isCancelled => _cancelled;

  void promote() => _scheduler._promote(this);

  void cancel() => _scheduler._cancel(this);

  void _grant() {
    if (_cancelled || _granted) return;
    _granted = true;
    _countsAsPreload = _priority == ImageDownloadPriority.preload;
    _complete();
  }

  void _complete() {
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }
}

class _ComicImageLoadRequest {
  _ComicImageLoadRequest(this.priority);

  ImageDownloadPriority priority;

  ImageDownloadTicket? _ticket;

  bool cancelled = false;

  void promote() {
    if (priority == ImageDownloadPriority.foreground) return;
    priority = ImageDownloadPriority.foreground;
    _ticket?.promote();
  }

  void attach(ImageDownloadTicket ticket) {
    _ticket = ticket;
    if (cancelled) {
      ticket.cancel();
    } else if (priority == ImageDownloadPriority.foreground) {
      ticket.promote();
    }
  }

  void detach(ImageDownloadTicket ticket) {
    if (identical(_ticket, ticket)) {
      _ticket = null;
    }
  }

  void cancel() {
    cancelled = true;
    _ticket?.cancel();
  }
}

abstract class ImageDownloader {
  /// Limits concurrent comic image downloads so fast scrolling into an
  /// unbuffered region cannot start dozens of downloads at once (memory
  /// spikes, GC pauses and frame drops).
  static final _downloadScheduler = ImageDownloadScheduler();

  /// Builds the disk cache key used by [loadThumbnail].
  ///
  /// Providers must report this key back through `LoadResult.cacheKey` so a
  /// failed decode can purge the exact entry that produced the bytes.
  static String thumbnailCacheKey(
    String url,
    String? sourceKey, [
    String? cid,
  ]) => "$url@$sourceKey${cid != null ? '@$cid' : ''}";

  /// Builds the disk cache key used by [_loadComicImage].
  static String comicImageCacheKey(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) => "$imageKey@$sourceKey@$cid@$eid";

  /// Whether [url] is a placeholder cover that must be resolved through
  /// `loadComicInfo` before it can be downloaded.
  static bool isCoverPlaceholder(String url) =>
      url.startsWith('cover.') || url.startsWith('cover/');

  static Stream<ImageDownloadProgress> loadThumbnail(
    String url,
    String? sourceKey, [
    String? cid,
  ]) async* {
    final cacheKey = thumbnailCacheKey(url, sourceKey, cid);
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

    if (isCoverPlaceholder((configs['url'] as String?) ?? url) &&
        sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      if (comicSource != null && comicSource.loadComicInfo != null) {
        if (cid == null) {
          throw "Error: Cannot resolve a cover placeholder without a comic id.";
        }
        var comicInfo = await comicSource.loadComicInfo!(cid);
        if (comicInfo.error) {
          throw comicInfo.errorMessage ?? "Error: Failed to load comic info.";
        }
        var resolved = comicInfo.data.cover;
        if (isCoverPlaceholder(resolved)) {
          throw "Error: Comic source returned an invalid cover: $resolved";
        }
        // Keep the cid in the recursive call: the resolved URL must share
        // the same cache entry as the display path (url@source@cid), and a
        // second-level placeholder must not be resolved again with a null id.
        yield* loadThumbnail(resolved, sourceKey, cid);
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

  /// Promote an already loading comic image to foreground priority.
  ///
  /// This only consults the in-flight request registry. It never creates a
  /// request or touches the disk/network cache when the image is not loading.
  static bool promoteComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    final cacheKey = comicImageCacheKey(imageKey, sourceKey, cid, eid);
    final existing = _loadingImages[cacheKey];
    if (existing == null) {
      return false;
    }
    existing.promote();
    return true;
  }

  /// Load a comic image from the network or cache.
  /// The function will prevent multiple requests for the same image.
  static Stream<ImageDownloadProgress> loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    ImageDownloadPriority priority = ImageDownloadPriority.foreground,
  }) {
    final cacheKey = comicImageCacheKey(imageKey, sourceKey, cid, eid);
    final existing = _loadingImages[cacheKey];
    if (existing != null) {
      if (priority == ImageDownloadPriority.foreground) {
        existing.promote();
      }
      return existing.stream;
    }
    final cancelToken = CancelToken();
    final request = _ComicImageLoadRequest(priority);
    final stream = _StreamWrapper<ImageDownloadProgress>(
      _loadComicImage(imageKey, sourceKey, cid, eid, cancelToken, request),
      (wrapper) {
        _loadingImages.remove(cacheKey);
      },
      onPromote: request.promote,
      onCancel: () {
        request.cancel();
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
    String eid, {
    ImageDownloadPriority priority = ImageDownloadPriority.foreground,
  }) {
    return _loadComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
      CancelToken(),
      _ComicImageLoadRequest(priority),
    );
  }

  static Stream<ImageDownloadProgress> _loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
    CancelToken cancelToken,
    _ComicImageLoadRequest request,
  ) async* {
    final cacheKey = comicImageCacheKey(imageKey, sourceKey, cid, eid);
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
    if (request.cancelled) return;

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
      if (request.cancelled) return;
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
        final ticket = ImageDownloader._downloadScheduler.acquire(
          request.priority,
        );
        request.attach(ticket);
        try {
          await ticket.granted;
          if (request.cancelled || ticket.isCancelled) return;
          queueWatch.stop();
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
            // so concurrent downloads stay greppable. queue = waiting for a
            // download slot, connect =
            // TCP/TLS + first byte, download = body transfer, total =
            // everything incl. retries and the cache write.
            Log.info(
              "Image",
              "sourceKey=$sourceKey comicId=$cid epId=$eid "
                  "priority=${request.priority.name} "
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
          ImageDownloader._downloadScheduler.release(ticket);
          request.detach(ticket);
        }
        return;
      } catch (e) {
        if (request.cancelled) return;
        if (e is DioException && e.type == DioExceptionType.cancel) {
          // A cancelled image must not be retried through onLoadFailed.
          rethrow;
        }
        if (retryLimit < 0 || onLoadFailed == null) {
          rethrow;
        }
        var newConfig = await onLoadFailed();
        if (request.cancelled) return;
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

  /// Called when a foreground subscriber takes over a queued preload.
  final void Function()? onPromote;

  bool isClosed = false;

  _StreamWrapper(this._stream, this.onClosed, {this.onCancel, this.onPromote}) {
    _listen();
  }

  void promote() => onPromote?.call();

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
