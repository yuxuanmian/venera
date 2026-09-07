import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:venera/foundation/app.dart';
import 'package:venera/network/app_dio.dart';

import 'models.dart';
import 'store.dart';

const catalogAuthorityTimeout = Duration(seconds: 3);
const catalogNormalPrepareBudget = Duration(seconds: 30);
const catalogBootstrapPrepareBudget = Duration(seconds: 120);
const catalogFileRequestTimeout = Duration(seconds: 15);
const catalogMaxAuthorityBytes = 64 << 10;
const catalogMaxConcurrentDownloads = 4;

class CatalogHttpException implements Exception {
  const CatalogHttpException(this.code, this.message, [this.cause]);

  final String code;
  final String message;
  final Object? cause;

  @override
  String toString() =>
      cause == null ? '$code: $message' : '$code: $message: $cause';
}

class CatalogServerUrl {
  const CatalogServerUrl._(this.uri);

  final Uri uri;

  factory CatalogServerUrl.parse(String input) {
    final trimmed = input.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.pathSegments.contains('api') &&
            uri.pathSegments.contains('catalog') ||
        uri.host == 'raw.githubusercontent.com') {
      throw const CatalogHttpException(
        'invalid_server_url',
        '请输入 Venera Server 基础地址',
      );
    }
    if (uri.pathSegments.any((segment) => segment == '..' || segment == '.')) {
      throw const CatalogHttpException('invalid_server_url', 'Server 地址路径无效');
    }
    return CatalogServerUrl._(uri.replace(path: _basePath(uri.path)));
  }

  String get normalized => uri.toString();

  Uri get authorityUri => uri.replace(path: '${uri.path}api/catalog/authority');

  @override
  String toString() => normalized;
}

class CatalogBytesResponse {
  const CatalogBytesResponse(this.statusCode, this.bytes, {this.contentType});

  final int statusCode;
  final List<int> bytes;
  final String? contentType;
}

abstract interface class CatalogTransport {
  Future<CatalogBytesResponse> getBytes(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    CatalogCancellationToken? cancellation,
  });
}

class IoCatalogTransport implements CatalogTransport {
  const IoCatalogTransport();

  @override
  Future<CatalogBytesResponse> getBytes(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    CatalogCancellationToken? cancellation,
  }) async {
    if (cancellation?.isCancelled == true) {
      throw const CatalogHttpException('cancelled', '请求已取消');
    }
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.followRedirects = false;
      final response = await request.close().timeout(timeout);
      if (response.isRedirect) {
        throw const CatalogHttpException(
          'untrusted_redirect',
          'Catalog 请求不允许重定向',
        );
      }
      final bytes = await _readLimited(response, maxBytes).timeout(timeout);
      return CatalogBytesResponse(
        response.statusCode,
        bytes,
        contentType: response.headers.contentType?.mimeType,
      );
    } on TimeoutException catch (error) {
      throw CatalogHttpException('timeout', 'Catalog 请求超时', error);
    } on SocketException catch (error) {
      throw CatalogHttpException('connection_failed', 'Catalog 连接失败', error);
    } on HandshakeException catch (error) {
      throw CatalogHttpException(
        'connection_failed',
        'Catalog TLS 连接失败',
        error,
      );
    } on HttpException catch (error) {
      throw CatalogHttpException(
        'connection_failed',
        'Catalog HTTP 连接失败',
        error,
      );
    } finally {
      client.close(force: true);
    }
  }
}

/// Production Catalog transport. It deliberately goes through AppDio so the
/// shared rhttp adapter supplies the app's proxy, DNS overrides, TLS policy,
/// cookie boundary and cancellation path.
class AppDioCatalogTransport implements CatalogTransport {
  AppDioCatalogTransport({AppDio? dio})
    : _dio =
          dio ??
          AppDio(
            BaseOptions(
              responseType: ResponseType.bytes,
              validateStatus: (status) => true,
            ),
          );

  final AppDio _dio;

  @override
  Future<CatalogBytesResponse> getBytes(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    CatalogCancellationToken? cancellation,
  }) async {
    if (cancellation?.isCancelled == true) {
      throw const CatalogHttpException('cancelled', '请求已取消');
    }
    final cancelToken = CancelToken();
    final removeCancellation = cancellation?.onCancel(
      () => cancelToken.cancel('Catalog request cancelled'),
    );
    try {
      final response = await _dio
          .get<List<int>>(
            uri.toString(),
            cancelToken: cancelToken,
            options: Options(
              responseType: ResponseType.bytes,
              followRedirects: false,
              maxRedirects: 0,
              sendTimeout: timeout,
              receiveTimeout: timeout,
              headers: const {'Cache-Control': 'no-cache'},
              extra: {
                // RHttpAdapter consumes these before Dio buffers a body. The
                // ordinary AppDio path keeps its existing redirect policy.
                'catalogNoRedirect': true,
                'catalogMaxBytes': maxBytes,
              },
            ),
          )
          .timeout(timeout);
      if (response.isRedirect ||
          response.statusCode != null &&
              response.statusCode! >= 300 &&
              response.statusCode! < 400) {
        throw const CatalogHttpException(
          'untrusted_redirect',
          'Catalog 请求不允许重定向',
        );
      }
      final body = response.data ?? const <int>[];
      if (body.length > maxBytes) {
        throw const CatalogHttpException('response_too_large', '响应过大');
      }
      return CatalogBytesResponse(
        response.statusCode ?? 0,
        List<int>.from(body),
        contentType: response.headers.value('content-type'),
      );
    } on TimeoutException catch (error) {
      // Future.timeout only abandons the Dart future. Explicitly cancel the
      // Dio/rhttp request as well so a timed-out Catalog transfer cannot keep
      // receiving bytes in the background.
      cancelToken.cancel('Catalog request timed out');
      throw CatalogHttpException('timeout', 'Catalog 请求超时', error);
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        throw const CatalogHttpException('cancelled', '请求已取消');
      }
      if (error.error is ResponseSizeLimitException) {
        throw const CatalogHttpException('response_too_large', '响应过大');
      }
      if (error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        cancelToken.cancel('Catalog request timed out');
        throw CatalogHttpException('timeout', 'Catalog 请求超时', error);
      }
      throw CatalogHttpException('connection_failed', 'Catalog 连接失败', error);
    } finally {
      removeCancellation?.call();
    }
  }
}

class CatalogCancellationToken {
  bool _cancelled = false;
  final _listeners = <void Function()>[];
  Completer<void>? _cancelledCompleter;

  bool get isCancelled => _cancelled;

  Future<void> get whenCancelled {
    if (_cancelled) return Future<void>.value();
    return (_cancelledCompleter ??= Completer<void>()).future;
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelledCompleter?.complete();
    for (final listener in List<void Function()>.from(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  void Function() onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

enum CatalogAttemptPhase { preparing, closed, committing, finished }

class CatalogAttempt {
  CatalogAttempt({
    required this.id,
    required this.deadline,
    this.allowLocalFallback = false,
  });

  final String id;
  final DateTime deadline;
  final bool allowLocalFallback;
  final CatalogCancellationToken cancellation = CatalogCancellationToken();
  CatalogAttemptPhase phase = CatalogAttemptPhase.preparing;

  bool get isOpen =>
      phase == CatalogAttemptPhase.preparing &&
      DateTime.now().isBefore(deadline);

  Duration get remaining {
    final value = deadline.difference(DateTime.now());
    return value.isNegative ? Duration.zero : value;
  }

  void close() {
    if (phase != CatalogAttemptPhase.preparing) return;
    phase = CatalogAttemptPhase.closed;
    cancellation.cancel();
  }

  /// Runs one asynchronous preparation operation under this attempt's
  /// deadline and cancellation boundary. Dart cannot interrupt an arbitrary
  /// Future, so a late successful value is handed to [onLate] for disposal and
  /// late errors are consumed. This lets the controller move to a healthy
  /// local choice without allowing a timed-out worker to publish state.
  Future<T> waitFor<T>(
    Future<T> Function() operation, {
    FutureOr<void> Function(T value)? onLate,
  }) async {
    if (!isOpen) {
      close();
      throw const CatalogHttpException('cancelled', 'Catalog 准备已取消');
    }

    late Future<T> future;
    try {
      future = operation();
    } catch (_) {
      rethrow;
    }

    final result = Completer<T>();
    Timer? timer;
    void Function()? removeCancellation;
    var settled = false;
    var abandoned = false;

    void disposeLateValue(T value) {
      final cleanup = onLate;
      if (cleanup == null) return;
      unawaited(Future<void>.sync(() => cleanup(value)).catchError((_) {}));
    }

    void completeValue(T value) {
      if (settled) {
        if (abandoned) disposeLateValue(value);
        return;
      }
      settled = true;
      timer?.cancel();
      removeCancellation?.call();
      result.complete(value);
    }

    void completeError(Object error, StackTrace stack) {
      if (settled) return;
      settled = true;
      timer?.cancel();
      removeCancellation?.call();
      result.completeError(error, stack);
    }

    future.then(completeValue, onError: completeError);
    removeCancellation = cancellation.onCancel(() {
      if (settled) return;
      abandoned = true;
      settled = true;
      timer?.cancel();
      result.completeError(
        const CatalogHttpException('cancelled', 'Catalog 准备已取消'),
      );
    });
    timer = Timer(remaining, () {
      if (settled) return;
      abandoned = true;
      settled = true;
      removeCancellation?.call();
      result.completeError(
        const CatalogHttpException('timeout', 'Catalog 准备超时'),
      );
      close();
    });
    if (settled) timer.cancel();
    return result.future;
  }

  bool beginCommit() {
    if (!isOpen) {
      close();
      return false;
    }
    phase = CatalogAttemptPhase.committing;
    return true;
  }

  void finish() {
    if (phase != CatalogAttemptPhase.finished) {
      phase = CatalogAttemptPhase.finished;
    }
  }
}

class CatalogHttpClient {
  CatalogHttpClient({CatalogTransport? transport})
    : transport =
          transport ??
          (App.isInitialized
              ? AppDioCatalogTransport()
              : const IoCatalogTransport());

  final CatalogTransport transport;

  Future<CatalogPointer> getAuthority(
    String serverBaseUrl, {
    CatalogAttempt? attempt,
  }) async {
    final base = CatalogServerUrl.parse(serverBaseUrl);
    final remaining = attempt?.remaining;
    if (remaining != null && remaining <= Duration.zero) {
      throw const CatalogHttpException('timeout', 'Catalog 准备超时');
    }
    final timeout = remaining == null || remaining > catalogAuthorityTimeout
        ? catalogAuthorityTimeout
        : remaining;
    final response = await transport
        .getBytes(
          base.authorityUri,
          timeout: timeout,
          maxBytes: catalogMaxAuthorityBytes,
          cancellation: attempt?.cancellation,
        )
        .timeout(timeout)
        .catchError((error) {
          throw _normalizeTransportError(error);
        });
    if (response.bytes.length > catalogMaxAuthorityBytes) {
      throw const CatalogHttpException('response_too_large', 'Server 响应过大');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String? serverCode;
      try {
        final body = jsonDecode(utf8.decode(response.bytes));
        final error = body is Map ? body['error'] : null;
        final code = error is Map ? error['code'] : null;
        if (code is String &&
            RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(code) &&
            error['message'] is String) {
          serverCode = code;
        }
      } on FormatException {
        // HTML and malformed error bodies are classified by HTTP status.
      }
      throw CatalogHttpException(
        serverCode ??
            (const [502, 503, 504].contains(response.statusCode)
                ? 'connection_failed'
                : response.statusCode == 404
                ? 'not_found'
                : 'authority_failed'),
        'Authority HTTP ${response.statusCode}',
      );
    }
    try {
      final value = jsonDecode(utf8.decode(response.bytes));
      if (value is! Map) throw const FormatException('object expected');
      return CatalogPointer.fromAuthorityJson(Map<String, dynamic>.from(value));
    } on CatalogFormatException catch (error) {
      throw CatalogHttpException(
        'invalid_authority',
        'Server 返回的漫画源配置无效',
        error,
      );
    } on Object catch (error) {
      throw CatalogHttpException(
        'invalid_authority',
        'Server 返回的漫画源配置不是有效 JSON',
        error,
      );
    }
  }

  Uri indexUri(CatalogPointer pointer) {
    pointer.validate();
    return Uri.parse(pointer.indexUrl);
  }

  Uri sourceUri(CatalogPointer pointer, String fileName) {
    pointer.validate();
    final entry = Uri.parse(pointer.indexUrl);
    if (!RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]*\.js$').hasMatch(fileName) ||
        fileName.contains('..')) {
      throw const CatalogHttpException('invalid_source', '源文件名无效');
    }
    return entry.replace(
      path:
          '${entry.path.substring(0, entry.path.length - 'index.json'.length)}$fileName',
    );
  }

  Future<CatalogCandidate> downloadSnapshot(
    CatalogPointer pointer, {
    required CatalogStore store,
    required CatalogAttempt attempt,
    void Function(int completed, int total)? onProgress,
  }) async {
    pointer.validate();
    CatalogCandidate? candidate;
    try {
      final indexResponse = await _get(
        indexUri(pointer),
        attempt: attempt,
        maxBytes: catalogMaxIndexBytes,
      );
      if (indexResponse.statusCode < 200 || indexResponse.statusCode >= 300) {
        throw CatalogHttpException(
          'download_failed',
          'index 请求失败（HTTP ${indexResponse.statusCode}）',
        );
      }
      final indexBytes = indexResponse.bytes;
      final index = CatalogIndex.fromBytes(indexBytes);
      candidate = await store.createCandidate(
        pointer: pointer,
        indexBytes: indexBytes,
        index: index,
        attemptId: attempt.id,
      );
      onProgress?.call(0, index.entries.length);
      var next = 0;
      var completed = 0;
      Future<void> worker() async {
        while (true) {
          if (!attempt.isOpen) return;
          final i = next++;
          if (i >= index.entries.length) return;
          final entry = index.entries[i];
          final response = await _get(
            sourceUri(pointer, entry.fileName),
            attempt: attempt,
            maxBytes: catalogMaxSourceBytes,
          );
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw CatalogHttpException(
              'download_failed',
              '${entry.fileName} 请求失败（HTTP ${response.statusCode}）',
            );
          }
          if (!attempt.isOpen) return;
          await store.writeCandidateSource(candidate!, entry, response.bytes);
          completed++;
          onProgress?.call(completed, index.entries.length);
        }
      }

      await Future.wait(
        List.generate(catalogMaxConcurrentDownloads, (_) => worker()),
      );
      if (!attempt.isOpen) {
        throw const CatalogHttpException('cancelled', 'Catalog 准备已取消');
      }
      final completedCandidate = await store.finalizeCandidate(candidate);
      candidate = completedCandidate;
      if (!attempt.isOpen) {
        await completedCandidate.discard();
        throw const CatalogHttpException('cancelled', 'Catalog 准备已取消');
      }
      return completedCandidate;
    } catch (error) {
      if (candidate != null) await candidate.discard();
      if (error is CatalogHttpException) rethrow;
      if (error is CatalogFormatException) {
        throw CatalogHttpException('invalid_catalog', '漫画源配置索引或文件无效', error);
      }
      rethrow;
    }
  }

  Future<CatalogBytesResponse> _get(
    Uri uri, {
    required CatalogAttempt attempt,
    required int maxBytes,
  }) {
    if (!attempt.isOpen) {
      throw const CatalogHttpException('cancelled', 'Catalog 准备已取消');
    }
    final remaining = attempt.deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw const CatalogHttpException('timeout', 'Catalog 准备超时');
    }
    final timeout = remaining < catalogFileRequestTimeout
        ? remaining
        : catalogFileRequestTimeout;
    return transport
        .getBytes(
          uri,
          timeout: timeout,
          maxBytes: maxBytes,
          cancellation: attempt.cancellation,
        )
        .timeout(timeout)
        .catchError((error) {
          throw _normalizeTransportError(error);
        });
  }
}

Object _normalizeTransportError(Object error) {
  if (error is CatalogHttpException) return error;
  if (error is TimeoutException) {
    return CatalogHttpException('timeout', 'Catalog 请求超时', error);
  }
  if (error is SocketException ||
      error is HandshakeException ||
      error is HttpException) {
    return CatalogHttpException('connection_failed', 'Catalog 连接失败', error);
  }
  return error;
}

String _basePath(String path) {
  if (path.isEmpty || path == '/') return '/';
  return '${path.replaceFirst(RegExp(r'/+$'), '')}/';
}

Future<List<int>> _readLimited(
  HttpClientResponse response,
  int maxBytes,
) async {
  if (response.contentLength > maxBytes) {
    throw const CatalogHttpException('response_too_large', '响应过大');
  }
  final chunks = <int>[];
  await for (final chunk in response) {
    chunks.addAll(chunk);
    if (chunks.length > maxBytes) {
      throw const CatalogHttpException('response_too_large', '响应过大');
    }
  }
  return chunks;
}
