import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/network_diagnostics.dart';
import 'package:venera/utils/semantic_version.dart';

import 'models.dart';
import 'store.dart';

part 'git_head.dart';

const catalogHeadTimeout = Duration(seconds: 6);
const catalogManualHeadTimeout = Duration(seconds: 10);
const catalogNormalPrepareBudget = Duration(seconds: 30);
const catalogBootstrapPrepareBudget = Duration(seconds: 120);
const catalogFileRequestTimeout = Duration(seconds: 15);
const catalogMaxGitRefBytes = 64 << 10;
const catalogMaxMetadataBytes = 16 << 10;
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

class CatalogBytesResponse {
  const CatalogBytesResponse(
    this.statusCode,
    this.bytes, {
    this.contentType,
    this.headers = const {},
  });

  final int statusCode;
  final List<int> bytes;
  final String? contentType;
  final Map<String, List<String>> headers;

  String? header(String name) => headers[name]?.firstOrNull;
}

class CatalogHeadRateLimitException extends CatalogHttpException {
  const CatalogHeadRateLimitException(this.retryAt)
    : super('head_rate_limited', 'GitHub API 请求额度已用完');

  final DateTime retryAt;
}

abstract interface class CatalogTransport {
  Future<CatalogBytesResponse> getBytes(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    CatalogCancellationToken? cancellation,
  });
}

abstract interface class CatalogGitTransport implements CatalogTransport {
  Future<CatalogBytesResponse> requestGit(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    required CatalogCancellationToken cancellation,
    Uint8List? body,
  });
}

const _gitProtocolHeaders = {'Git-Protocol': 'version=2'};
const _gitRequestContentType = 'application/x-git-upload-pack-request';

class IoCatalogTransport implements CatalogGitTransport {
  const IoCatalogTransport();

  @override
  Future<CatalogBytesResponse> getBytes(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    CatalogCancellationToken? cancellation,
  }) => _request(uri, timeout, maxBytes, cancellation);

  @override
  Future<CatalogBytesResponse> requestGit(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    required CatalogCancellationToken cancellation,
    Uint8List? body,
  }) => _request(uri, timeout, maxBytes, cancellation, git: true, body: body);

  Future<CatalogBytesResponse> _request(
    Uri uri,
    Duration timeout,
    int maxBytes,
    CatalogCancellationToken? cancellation, {
    bool git = false,
    Uint8List? body,
  }) async {
    if (cancellation?.isCancelled == true) {
      throw const CatalogHttpException('cancelled', '请求已取消');
    }
    final client = HttpClient();
    final method = body == null ? 'GET' : 'POST';
    int? status;
    void recordFailure(String failure) {
      if (cancellation?.isCancelled == true) return;
      NetworkDiagnostics.record(
        method: method,
        uri: uri,
        data: body,
        status: status,
        failure: failure,
      );
    }

    final removeCancellation = cancellation?.onCancel(
      () => client.close(force: true),
    );
    try {
      final request = await client.openUrl(method, uri).timeout(timeout);
      request.followRedirects = false;
      request.headers.set('Cache-Control', 'no-cache');
      if (git) _gitProtocolHeaders.forEach(request.headers.set);
      if (body != null) {
        request.headers.set(
          HttpHeaders.contentTypeHeader,
          _gitRequestContentType,
        );
        request.contentLength = body.length;
        request.add(body);
      }
      final response = await request.close().timeout(timeout);
      status = response.statusCode;
      if (response.isRedirect) {
        throw const CatalogHttpException(
          'untrusted_redirect',
          'Catalog 请求不允许重定向',
        );
      }
      final bytes = await _readLimited(response, maxBytes).timeout(timeout);
      final headers = <String, List<String>>{};
      response.headers.forEach((name, values) => headers[name] = values);
      if (status >= 400) recordFailure('http');
      return CatalogBytesResponse(
        response.statusCode,
        bytes,
        contentType: response.headers.contentType?.mimeType,
        headers: headers,
      );
    } on CatalogHttpException catch (error) {
      recordFailure(error.code);
      rethrow;
    } on TimeoutException catch (error) {
      recordFailure('timeout');
      throw CatalogHttpException('timeout', 'Catalog 请求超时', error);
    } on SocketException catch (error) {
      recordFailure('connection_failed');
      throw CatalogHttpException('connection_failed', 'Catalog 连接失败', error);
    } on HandshakeException catch (error) {
      recordFailure('tls_handshake');
      throw CatalogHttpException(
        'connection_failed',
        'Catalog TLS 连接失败',
        error,
      );
    } on HttpException catch (error) {
      recordFailure('http_transport');
      throw CatalogHttpException(
        'connection_failed',
        'Catalog HTTP 连接失败',
        error,
      );
    } finally {
      removeCancellation?.call();
      client.close(force: true);
    }
  }
}

/// Production Catalog transport. It deliberately goes through AppDio so the
/// shared rhttp adapter supplies the app's proxy, DNS overrides, TLS policy,
/// cookie boundary and cancellation path.
class AppDioCatalogTransport implements CatalogGitTransport {
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
  }) => _request(uri, timeout, maxBytes, cancellation);

  @override
  Future<CatalogBytesResponse> requestGit(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    required CatalogCancellationToken cancellation,
    Uint8List? body,
  }) => _request(uri, timeout, maxBytes, cancellation, git: true, body: body);

  Future<CatalogBytesResponse> _request(
    Uri uri,
    Duration timeout,
    int maxBytes,
    CatalogCancellationToken? cancellation, {
    bool git = false,
    Uint8List? body,
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
          .request<List<int>>(
            uri.toString(),
            data: body,
            cancelToken: cancelToken,
            options: Options(
              method: body == null ? 'GET' : 'POST',
              contentType: body == null ? null : _gitRequestContentType,
              responseType: ResponseType.bytes,
              followRedirects: false,
              maxRedirects: 0,
              sendTimeout: timeout,
              receiveTimeout: timeout,
              headers: {
                'Cache-Control': 'no-cache',
                if (git) ..._gitProtocolHeaders,
              },
              extra: {
                // RHttpAdapter consumes these before Dio buffers a body. The
                // ordinary AppDio path keeps its existing redirect policy.
                'catalogNoRedirect': true,
                'catalogMaxBytes': maxBytes,
                // HEAD and Git advertisements must go directly to GitHub.
                if (git || uri.host == 'api.github.com') 'catalogLiveRef': true,
              },
            ),
          )
          .timeout(timeout);
      if (response.isRedirect ||
          response.statusCode != null &&
              response.statusCode! >= 300 &&
              response.statusCode! < 400) {
        NetworkDiagnostics.recordRequest(
          response.requestOptions,
          status: response.statusCode,
          failure: 'untrusted_redirect',
        );
        throw const CatalogHttpException(
          'untrusted_redirect',
          'Catalog 请求不允许重定向',
        );
      }
      final bytes = response.data ?? const <int>[];
      if (bytes.length > maxBytes) {
        throw const CatalogHttpException('response_too_large', '响应过大');
      }
      return CatalogBytesResponse(
        response.statusCode ?? 0,
        List<int>.from(bytes),
        contentType: response.headers.value('content-type'),
        headers: response.headers.map,
      );
    } on TimeoutException catch (error) {
      // Future.timeout only abandons the Dart future. Explicitly cancel the
      // Dio/rhttp request as well so a timed-out Catalog transfer cannot keep
      // receiving bytes in the background.
      cancelToken.cancel('Catalog request timed out');
      NetworkDiagnostics.record(
        method: body == null ? 'GET' : 'POST',
        uri: uri,
        data: body,
        failure: 'timeout',
      );
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
  DateTime? _restRateLimitedUntil;

  Future<CatalogPointer> resolveRepositoryHead(
    CatalogRepositorySource source, {
    CatalogAttempt? attempt,
    Duration timeout = catalogHeadTimeout,
  }) async {
    final budget = _timeoutForAttempt(attempt, timeout);
    final deadline = DateTime.now().add(budget);
    final head = CatalogAttempt(
      id: attempt?.id ?? 'repository-head',
      deadline: attempt != null && attempt.deadline.isBefore(deadline)
          ? attempt.deadline
          : deadline,
    );
    final removeCancellation = attempt?.cancellation.onCancel(head.close);
    try {
      return await head.waitFor(() => _resolveRepositoryHead(source, head));
    } finally {
      removeCancellation?.call();
      head.finish();
    }
  }

  Future<CatalogPointer> _resolveRepositoryHead(
    CatalogRepositorySource source,
    CatalogAttempt attempt,
  ) async {
    final git = transport;
    if (git is CatalogGitTransport) {
      try {
        final pointer = await _queryGitBranch(git, source, attempt);
        Log.info('Catalog', 'Repository HEAD resolved via Git HTTPS');
        return pointer;
      } on CatalogHttpException catch (error) {
        if (error.code == 'branch_not_found' ||
            error.code == 'cancelled' ||
            !attempt.isOpen) {
          rethrow;
        }
        Log.info(
          'Catalog',
          'Git HEAD query failed (${error.code}); trying REST',
        );
      }
    }
    return _resolveRestHead(source, attempt);
  }

  Future<CatalogPointer> _resolveRestHead(
    CatalogRepositorySource source,
    CatalogAttempt attempt,
  ) async {
    final retryAt = _restRateLimitedUntil;
    if (retryAt != null && retryAt.isAfter(DateTime.now())) {
      throw CatalogHeadRateLimitException(retryAt);
    }
    final response = await transport
        .getBytes(
          _repositoryHeadUri(source),
          timeout: _timeoutForAttempt(attempt, attempt.remaining),
          maxBytes: catalogMaxGitRefBytes,
          cancellation: attempt.cancellation,
        )
        .catchError((error) {
          throw _normalizeTransportError(error);
        });
    if (response.bytes.length > catalogMaxGitRefBytes) {
      throw const CatalogHttpException('response_too_large', 'GitHub 分支响应过大');
    }
    final rateLimit = _restRateLimitRetryAt(response, DateTime.now());
    if (rateLimit != null) {
      _restRateLimitedUntil = rateLimit;
      throw CatalogHeadRateLimitException(rateLimit);
    }
    if (response.statusCode == HttpStatus.notFound) {
      throw const CatalogHttpException('branch_not_found', '找不到配置仓库或分支');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CatalogHttpException(
        'head_query_failed',
        'GitHub 分支请求失败（HTTP ${response.statusCode}）',
      );
    }
    try {
      final value = jsonDecode(utf8.decode(response.bytes));
      if (value is! Map) {
        throw const CatalogFormatException('head response must be an object');
      }
      final object = value['object'];
      if (value['ref'] != 'refs/heads/${source.branch}' ||
          object is! Map ||
          object['type'] != 'commit' ||
          object['sha'] is! String) {
        throw const CatalogFormatException('invalid repository head');
      }
      final revision = object['sha'] as String;
      if (!_gitCommitSha.hasMatch(revision)) {
        throw const CatalogFormatException('invalid repository head revision');
      }
      final pointer = source.pointerForRevision(revision);
      Log.info('Catalog', 'Repository HEAD resolved via GitHub REST');
      return pointer;
    } on CatalogFormatException {
      throw const CatalogHttpException(
        'invalid_head_response',
        'GitHub 分支响应无效',
      );
    } on Object {
      throw const CatalogHttpException(
        'invalid_head_response',
        'GitHub 分支响应不是有效 JSON',
      );
    }
  }

  /// Reads and validates only the index declared by [pointer]. This is used to
  /// validate a repository change without downloading or publishing sources.
  Future<CatalogIndex> readIndex(
    CatalogPointer pointer, {
    required CatalogAttempt attempt,
  }) {
    _timeoutForAttempt(attempt, catalogFileRequestTimeout);
    return attempt.waitFor(() => _readIndex(pointer, attempt));
  }

  Future<CatalogIndex> _readIndex(
    CatalogPointer pointer,
    CatalogAttempt attempt,
  ) async {
    try {
      pointer.validate();
    } on CatalogFormatException {
      throw const CatalogHttpException('invalid_pointer', 'Catalog 指针无效');
    }
    _timeoutForAttempt(attempt, catalogFileRequestTimeout);
    final response = await _get(
      indexUri(pointer),
      attempt: attempt,
      maxBytes: catalogMaxIndexBytes,
    );
    if (response.bytes.length > catalogMaxIndexBytes) {
      throw const CatalogHttpException('response_too_large', 'index 响应过大');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CatalogHttpException(
        'index_query_failed',
        'index 请求失败（HTTP ${response.statusCode}）',
      );
    }
    try {
      return CatalogIndex.fromBytes(response.bytes);
    } on CatalogFormatException {
      throw const CatalogHttpException('invalid_index', '漫画源配置索引无效');
    }
  }

  Uri indexUri(CatalogPointer pointer) {
    pointer.validate();
    return Uri.parse(pointer.indexUrl);
  }

  Future<String?> checkCompatibility(
    CatalogPointer pointer, {
    required CatalogAttempt attempt,
  }) => attempt.waitFor(() async {
    final response = await _get(
      indexUri(pointer).resolve('catalog.json'),
      attempt: attempt,
      maxBytes: catalogMaxMetadataBytes,
    );
    if (response.statusCode == HttpStatus.notFound) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CatalogHttpException(
        'catalog_metadata_query_failed',
        'catalog.json 请求失败（HTTP ${response.statusCode}）',
      );
    }
    if (response.bytes.length > catalogMaxMetadataBytes) {
      throw const CatalogHttpException(
        'response_too_large',
        'catalog.json 响应过大',
      );
    }
    final String minimum;
    try {
      final data = jsonDecode(utf8.decode(response.bytes));
      if (data is! Map) {
        throw const CatalogFormatException('catalog.json must be an object');
      }
      minimum = parseCatalogMinimumAppVersion(data['minAppVersion']);
    } on FormatException catch (error) {
      throw CatalogHttpException(
        'invalid_catalog_metadata',
        'catalog.json 无效',
        error,
      );
    } on CatalogFormatException catch (error) {
      throw CatalogHttpException(
        'invalid_catalog_metadata',
        'catalog.json 无效',
        error,
      );
    }
    requireCompatibleApp(minimum);
    return minimum;
  });

  void requireCompatibleApp(String? minimumAppVersion) {
    if (minimumAppVersion == null) return;
    final comparison = compareSemanticVersions(
      App.packageVersion,
      minimumAppVersion,
    );
    if (comparison == null || comparison < 0) {
      throw CatalogAppVersionException(minimumAppVersion);
    }
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
      final minAppVersion = await checkCompatibility(pointer, attempt: attempt);
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
        minAppVersion: minAppVersion,
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

DateTime? _restRateLimitRetryAt(CatalogBytesResponse response, DateTime now) {
  final status = response.statusCode;
  if (status != HttpStatus.forbidden && status != HttpStatus.tooManyRequests) {
    return null;
  }
  final retryAfter = response.header('retry-after');
  final exhausted = response.header('x-ratelimit-remaining') == '0';
  if (status == HttpStatus.forbidden &&
      !exhausted &&
      retryAfter == null &&
      !String.fromCharCodes(
        response.bytes,
      ).toLowerCase().contains('secondary rate limit')) {
    return null;
  }
  // Bound integer conversions before creating a DateTime from untrusted headers.
  const maxEpochSeconds = 253402300799;
  final nowSeconds = now.millisecondsSinceEpoch ~/ 1000;
  final delay = int.tryParse(retryAfter ?? '');
  if (delay != null && delay > 0 && delay <= maxEpochSeconds - nowSeconds) {
    return now.add(Duration(seconds: delay));
  }
  final reset = exhausted
      ? int.tryParse(response.header('x-ratelimit-reset') ?? '')
      : null;
  if (reset != null && reset > nowSeconds && reset <= maxEpochSeconds) {
    return DateTime.fromMillisecondsSinceEpoch(reset * 1000, isUtc: true);
  }
  return now.add(const Duration(minutes: 1));
}

Duration _timeoutForAttempt(CatalogAttempt? attempt, Duration maximum) {
  if (attempt == null) return maximum;
  if (attempt.cancellation.isCancelled ||
      attempt.phase != CatalogAttemptPhase.preparing) {
    throw const CatalogHttpException('cancelled', 'Catalog 准备已取消');
  }
  final remaining = attempt.remaining;
  if (remaining <= Duration.zero) {
    throw const CatalogHttpException('timeout', 'Catalog 准备超时');
  }
  return remaining < maximum ? remaining : maximum;
}

Uri _repositoryHeadUri(CatalogRepositorySource source) {
  final branchSegments = source.branch.split('/');
  return Uri(
    scheme: 'https',
    host: 'api.github.com',
    pathSegments: [
      'repos',
      source.owner,
      source.repository,
      'git',
      'ref',
      'heads',
      ...branchSegments,
    ],
  );
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
