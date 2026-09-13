import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as file_path;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/runtime_context.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/scan/execution_guard.dart';
import 'package:venera/foundation/scan/scan_call_lease.dart';
import 'package:venera/foundation/scan/scan_limits.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/network/cloudflare.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('scan requests bypass a cached response and cache writes', () async {
    final cache = NetworkCacheManager.instance;
    cache.clear();
    addTearDown(cache.clear);

    final uri = Uri.parse('https://example.invalid/scan');
    cache.setCache(
      NetworkCache(
        uri: uri,
        requestHeaders: const {},
        responseHeaders: const {},
        data: const {'cached': true},
        time: DateTime.now(),
        size: 1,
      ),
    );
    final adapter = _RecordingAdapter(
      body: '{"remote":true}',
      headers: const {
        'content-type': ['application/json'],
      },
    );
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = adapter
      ..interceptors.add(cache);

    final first = await dio.get<Object?>(
      uri.toString(),
      options: Options(extra: {'veneraScan': true}),
    );
    final second = await dio.get<Object?>(
      uri.toString(),
      options: Options(extra: {'veneraScan': true}),
    );

    expect(adapter.requests, hasLength(2));
    expect(first.data, {'remote': true});
    expect(second.data, {'remote': true});
    expect(cache.getCache(uri)!.data, {'cached': true});

    final ordinary = await dio.get<Object?>(uri.toString());
    expect(ordinary.data, {'cached': true});
    expect(adapter.requests, hasLength(2));
  });

  test('scan responses keep Cloudflare challenge status and headers', () async {
    final adapter = _RecordingAdapter(
      status: 403,
      headers: const {
        'cf-mitigated': ['challenge'],
      },
      body: '<challenge-secret>',
    );
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = adapter
      ..interceptors.add(CloudflareInterceptor());

    final response = await dio.get<Object?>(
      'https://example.invalid/protected',
      options: Options(extra: {'veneraScan': true}),
    );

    expect(response.statusCode, 403);
    expect(response.headers['cf-mitigated'], ['challenge']);
    expect(response.data, '<challenge-secret>');
  });

  test('scan network logs omit URL, headers, and response body', () async {
    final previousMuted = Log.isMuted;
    Log.isMuted = false;
    Log.clear();
    addTearDown(() {
      Log.clear();
      Log.isMuted = previousMuted;
    });

    final adapter = _RecordingAdapter(
      body: jsonEncode({'secret': 'response-secret'}),
    );
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = adapter
      ..interceptors.add(MyLogInterceptor());

    await dio.get<Object?>(
      'https://private.example.invalid/path?token=query-secret',
      options: Options(
        headers: const {
          'authorization': 'Bearer header-secret',
          'cookie': 'session=cookie-secret',
        },
        extra: {'veneraScan': true},
      ),
    );

    final output = Log.logs.map((item) => item.content).join('\n');
    expect(output, contains('Scan GET status=200'));
    expect(output, isNot(contains('private.example.invalid')));
    expect(output, isNot(contains('query-secret')));
    expect(output, isNot(contains('header-secret')));
    expect(output, isNot(contains('cookie-secret')));
    expect(output, isNot(contains('response-secret')));
  });

  test('requestForScan uses the real AppDio host path safely', () async {
    final cache = NetworkCacheManager.instance;
    cache.clear();
    addTearDown(cache.clear);
    final uri = Uri.parse(
      'https://host.example.invalid/scan?token=query-secret',
    );
    cache.setCache(
      NetworkCache(
        uri: uri,
        requestHeaders: const {},
        responseHeaders: const {},
        data: const {'cached': true},
        time: DateTime.now(),
        size: 1,
      ),
    );
    final adapter = _RecordingAdapter(
      status: 403,
      headers: const {
        'retry-after': ['2'],
      },
      body: 'remote-response',
    );
    final dio = AppDio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = adapter
      ..interceptors.add(cache)
      ..interceptors.add(CloudflareInterceptor())
      ..interceptors.add(MyLogInterceptor());
    addTearDown(() => dio.close(force: true));

    final previousMuted = Log.isMuted;
    Log.isMuted = false;
    Log.clear();
    addTearDown(() {
      Log.clear();
      Log.isMuted = previousMuted;
    });
    final engine = JsEngine();
    engine.setDioForTesting(dio);
    final context = _publishedContext('host-appdio');
    final lease = ScanCallLease(
      guard: _guard('host-appdio', context),
      timeout: const Duration(seconds: 1),
    );

    final result = await engine.requestForScan(
      {
        'method': 'GET',
        'url': uri.toString(),
        'headers': {
          'authorization': 'Bearer header-secret',
          'cookie': 'session=cookie-secret',
        },
      },
      context,
      lease: lease,
      limits: const ScanLimits(requestTimeout: Duration(seconds: 1)),
    );
    lease.close();

    expect(result['ok'], isTrue);
    final response = result['response'] as Map;
    expect(response['status'], 403);
    expect(response['body'], 'remote-response');
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.extra['veneraScan'], isTrue);
    expect(cache.getCache(uri)!.data, {'cached': true});
    expect(context.revokeListenerCount, 0);
    final logs = Log.logs.map((item) => item.content).join('\n');
    for (final secret in [
      'host.example.invalid',
      'query-secret',
      'header-secret',
      'cookie-secret',
      'remote-response',
    ]) {
      expect(logs, isNot(contains(secret)));
    }
  });

  test(
    'requestForScan covers IO, response limits, invalid UTF-8, timeout, and revoke',
    () async {
      final oldProxy = appdata.settings['proxy'];
      appdata.settings['proxy'] = 'direct';
      addTearDown(() => appdata.settings['proxy'] = oldProxy);
      final cookieDirectory = await Directory.systemTemp.createTemp(
        'venera-scan-cookie-',
      );
      addTearDown(() async {
        SingleInstanceCookieJar.instance?.dispose();
        if (cookieDirectory.existsSync()) {
          await cookieDirectory.delete(recursive: true);
        }
      });
      SingleInstanceCookieJar(
        file_path.join(cookieDirectory.path, 'cookies.db'),
      );

      final engine = JsEngine();
      final ioAdapter = _RecordingAdapter(body: 'io-response');
      engine.setScanIoAdapterFactoryForTesting((_) => ioAdapter);
      addTearDown(() => engine.setScanIoAdapterFactoryForTesting(null));
      final ioContext = _publishedContext('host-io');
      final ioLease = ScanCallLease(
        guard: _guard('host-io', ioContext),
        timeout: const Duration(seconds: 1),
      );
      final ioResult = await engine.requestForScan(
        {
          'method': 'GET',
          'url': 'https://host.example.invalid/io',
          'headers': const {'http_client': 'dart:io'},
        },
        ioContext,
        lease: ioLease,
        limits: const ScanLimits(requestTimeout: Duration(seconds: 1)),
      );
      ioLease.close();
      expect(ioResult['ok'], isTrue);
      expect((ioResult['response'] as Map)['body'], 'io-response');
      expect(ioAdapter.requests, hasLength(1));
      expect(ioContext.revokeListenerCount, 0);

      final largeDio = AppDio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = _RecordingAdapter(bodyBytes: Uint8List(33));
      addTearDown(() => largeDio.close(force: true));
      engine.setDioForTesting(largeDio);
      final largeContext = _publishedContext('host-large');
      final largeLease = ScanCallLease(
        guard: _guard('host-large', largeContext),
        timeout: const Duration(seconds: 1),
      );
      final largeResult = await engine.requestForScan(
        {'method': 'GET', 'url': 'https://host.example.invalid/large'},
        largeContext,
        lease: largeLease,
        limits: const ScanLimits(
          requestTimeout: Duration(seconds: 1),
          maxScanResponseBytes: 16,
        ),
      );
      largeLease.close();
      expect(largeResult['ok'], isFalse);
      expect(
        (largeResult['failure'] as Map)['exceptionType'],
        'ResponseSizeLimitException',
      );
      expect(largeContext.revokeListenerCount, 0);

      final invalidDio = AppDio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = _RecordingAdapter(
          bodyBytes: Uint8List.fromList([0xc3, 0x28]),
        );
      addTearDown(() => invalidDio.close(force: true));
      engine.setDioForTesting(invalidDio);
      final invalidContext = _publishedContext('host-invalid-utf8');
      final invalidLease = ScanCallLease(
        guard: _guard('host-invalid-utf8', invalidContext),
        timeout: const Duration(seconds: 1),
      );
      final invalidResult = await engine.requestForScan(
        {'method': 'GET', 'url': 'https://host.example.invalid/invalid-utf8'},
        invalidContext,
        lease: invalidLease,
        limits: const ScanLimits(requestTimeout: Duration(seconds: 1)),
      );
      invalidLease.close();
      expect(invalidResult['ok'], isFalse);
      expect(
        (invalidResult['failure'] as Map)['exceptionType'],
        'FormatException',
      );
      expect(invalidContext.revokeListenerCount, 0);

      final boundaryDio = AppDio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = _RecordingAdapter(bodyBytes: Uint8List(16));
      addTearDown(() => boundaryDio.close(force: true));
      engine.setDioForTesting(boundaryDio);
      final boundaryContext = _publishedContext('host-boundary');
      final boundaryLease = ScanCallLease(
        guard: _guard('host-boundary', boundaryContext),
        timeout: const Duration(seconds: 1),
      );
      final boundaryResult = await engine.requestForScan(
        {'method': 'GET', 'url': 'https://host.example.invalid/boundary'},
        boundaryContext,
        lease: boundaryLease,
        limits: const ScanLimits(
          requestTimeout: Duration(seconds: 1),
          maxScanResponseBytes: 16,
        ),
      );
      boundaryLease.close();
      expect(boundaryResult['ok'], isTrue);
      expect((boundaryResult['response'] as Map)['body'].toString().length, 16);
      expect(boundaryContext.revokeListenerCount, 0);

      final timeoutAdapter = _RecordingAdapter.pending();
      final timeoutDio = AppDio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = timeoutAdapter;
      addTearDown(() => timeoutDio.close(force: true));
      engine.setDioForTesting(timeoutDio);
      final timeoutContext = _publishedContext('host-timeout');
      final timeoutLease = ScanCallLease(
        guard: _guard('host-timeout', timeoutContext),
        timeout: const Duration(seconds: 1),
      );
      final timeoutResult = await engine.requestForScan(
        {'method': 'GET', 'url': 'https://host.example.invalid/timeout'},
        timeoutContext,
        lease: timeoutLease,
        limits: const ScanLimits(
          requestTimeout: Duration(milliseconds: 10),
          jsCallTimeout: Duration(seconds: 1),
        ),
      );
      timeoutLease.close();
      expect(timeoutResult['ok'], isFalse);
      expect(
        (timeoutResult['failure'] as Map)['exceptionType'],
        'ScanRequestTimeout',
      );
      expect(timeoutAdapter.canceled, isTrue);
      expect(timeoutContext.revokeListenerCount, 0);

      final revokeAdapter = _RecordingAdapter.pending();
      final revokeDio = AppDio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = revokeAdapter;
      addTearDown(() => revokeDio.close(force: true));
      engine.setDioForTesting(revokeDio);
      final revokedContext = _publishedContext('host-revoked');
      final revokeLease = ScanCallLease(
        guard: _guard('host-revoked', revokedContext),
        timeout: const Duration(seconds: 1),
      );
      final request = engine.requestForScan(
        {'method': 'GET', 'url': 'https://host.example.invalid/revoked'},
        revokedContext,
        lease: revokeLease,
        limits: const ScanLimits(requestTimeout: Duration(seconds: 1)),
      );
      await revokeAdapter.started.future;
      expect(revokedContext.revokeListenerCount, 1);
      revokedContext.revoke();
      await expectLater(request, throwsA(isA<ScanControlException>()));
      expect(revokeAdapter.canceled, isTrue);
      expect(revokedContext.revokeListenerCount, 0);
    },
  );
}

ManagedSourceContext _publishedContext(String key) {
  final snapshot = CatalogSnapshot(
    manifest: CatalogSnapshotManifest(
      pointer: CatalogPointer(
        catalogId: 'owner/repo',
        revision: 'a' * 40,
        indexUrl:
            'https://raw.githubusercontent.com/owner/repo/${'a' * 40}/index.json',
      ),
      indexSha256: '0' * 64,
      files: const [],
    ),
    indexBytes: const [],
    index: CatalogIndex.fromJson([]),
    rootPath: Directory.systemTemp.path,
  );
  final context = ManagedSourceContext(snapshot: snapshot, sourceKey: key);
  context.publish();
  return context;
}

ScanExecutionGuard _guard(String key, ManagedSourceContext context) =>
    ScanExecutionGuard(
      sourceKey: key,
      sourceInstance: Object(),
      runtimeContext: context,
      cacheGeneration: 0,
    );

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({
    this.status = 200,
    this.headers = const {},
    String? body,
    Uint8List? bodyBytes,
  }) : bodyBytes = bodyBytes ?? Uint8List.fromList(utf8.encode(body ?? '')),
       pendingRequest = false;

  _RecordingAdapter.pending()
    : status = 200,
      headers = const {},
      bodyBytes = Uint8List(0),
      pendingRequest = true;

  final int status;
  final Map<String, List<String>> headers;
  final Uint8List bodyBytes;
  final bool pendingRequest;
  final List<RequestOptions> requests = [];
  final started = Completer<void>();
  bool canceled = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (!started.isCompleted) started.complete();
    if (pendingRequest) {
      final result = Completer<ResponseBody>();
      cancelFuture?.then((_) {
        canceled = true;
        if (!result.isCompleted) {
          result.completeError(
            DioException(
              requestOptions: options,
              type: DioExceptionType.cancel,
            ),
          );
        }
      });
      return result.future;
    }
    return ResponseBody(
      Stream<Uint8List>.value(bodyBytes),
      status,
      headers: headers,
    );
  }

  @override
  void close({bool force = false}) {}
}
