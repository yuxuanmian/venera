import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/cloudflare.dart';
import 'package:venera/network/network_diagnostics.dart';

void main() {
  late bool previousMuted;

  setUp(() {
    previousMuted = Log.isMuted;
    Log.isMuted = false;
    Log.clear();
  });

  tearDown(() {
    Log.clear();
    Log.isMuted = previousMuted;
  });

  LogItem entry() => Log.logs.singleWhere((item) => item.title == 'Network');

  for (final acceptsStatus in [true, false]) {
    test(
      'AppDio logs HTTP 500 once when validateStatus accepts=$acceptsStatus',
      () async {
        final dio =
            AppDio(
                BaseOptions(
                  responseType: ResponseType.plain,
                  validateStatus: acceptsStatus ? (_) => true : null,
                ),
              )
              ..httpClientAdapter = _Adapter(
                (_) => ResponseBody.fromString(
                  'response-secret',
                  500,
                  headers: {
                    'set-cookie': ['response-cookie-secret'],
                  },
                ),
              );
        addTearDown(() => dio.close(force: true));

        final response = dio.post<String>(
          'https://url-user:url-pass@example.invalid/api/items?page=2&access_token=query-secret#fragment-secret',
          data: {
            'page': 2,
            'filters': {'sort': 'recent', 'accessToken': 'body-secret'},
            'nested': [
              {'cookie': 'a=one-secret; b=two-secret'},
            ],
            'notes': 'authorization: Basic text-secret',
          },
          options: Options(headers: {'Authorization': 'Bearer header-secret'}),
        );
        if (acceptsStatus) {
          expect((await response).statusCode, 500);
        } else {
          await expectLater(
            response,
            throwsA(
              isA<DioException>().having(
                (e) => e.response?.statusCode,
                'status',
                500,
              ),
            ),
          );
        }

        final log = entry();
        expect(log.level, LogLevel.error);
        expect(
          log.content,
          contains('POST https://example.invalid/api/items?page=2'),
        );
        expect(log.content, contains('HTTP 500'));
        expect(log.content, contains('"sort":"recent"'));
        expect(log.content, contains('"accessToken":"[redacted]"'));
        for (final secret in [
          'url-user',
          'url-pass',
          'query-secret',
          'fragment-secret',
          'body-secret',
          'one-secret',
          'two-secret',
          'text-secret',
          'header-secret',
          'response-secret',
          'response-cookie-secret',
        ]) {
          expect(log.content, isNot(contains(secret)));
        }
      },
    );
  }

  test(
    'Cloudflare can replace the error after the request has been logged',
    () async {
      final dio = Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = _Adapter(
          (_) => ResponseBody.fromString(
            'challenge-page',
            403,
            headers: {
              'cf-mitigated': ['challenge'],
            },
          ),
        )
        ..interceptors.add(NetworkFailureInterceptor())
        ..interceptors.add(CloudflareInterceptor());
      addTearDown(() => dio.close(force: true));

      await expectLater(
        dio.post<Object>(
          'https://example.invalid/api/check',
          data: {'page': 3},
        ),
        throwsA(isA<CloudflareException>()),
      );
      expect(
        entry().content,
        contains('POST https://example.invalid/api/check HTTP 403'),
      );
      expect(entry().content, contains('"page":3'));
      expect(entry().content, isNot(contains('challenge-page')));
    },
  );

  test(
    'transport error logs the form while cancellation produces no entry',
    () async {
      final dio = Dio()
        ..httpClientAdapter = _Adapter(
          (options) => throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionTimeout,
            error: 'transport-secret',
          ),
        )
        ..interceptors.add(NetworkFailureInterceptor());
      addTearDown(() => dio.close(force: true));

      const url = 'https://example.invalid/api/list';
      await expectLater(
        dio.post<Object>(
          url,
          data: 'page=2&password=encoded%3Asecret&sort=recent',
          options: Options(contentType: Headers.formUrlEncodedContentType),
        ),
        throwsA(isA<DioException>()),
      );
      final content = entry().content;
      expect(content, contains('connectionTimeout'));
      expect(content, contains('"page":["2"]'));
      expect(content, contains('"sort":["recent"]'));
      expect(content, isNot(contains('encoded:secret')));
      expect(content, isNot(contains('transport-secret')));

      Log.clear();
      final cancellation = CancelToken()..cancel();
      await expectLater(
        dio.get<Object>(url, cancelToken: cancellation),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      expect(Log.logs, isEmpty);
    },
  );

  test(
    'accepted success keeps a safe request summary for business errors',
    () async {
      final dio = Dio(BaseOptions(responseType: ResponseType.plain))
        ..httpClientAdapter = _Adapter(
          (_) => ResponseBody.fromString('server-data', 200),
        )
        ..interceptors.add(
          NetworkFailureInterceptor(logSuccessfulResponses: true),
        );
      addTearDown(() => dio.close(force: true));

      final response = await dio.post<String>(
        'https://example.invalid/api/search',
        data: '{"page":3,"email":"account@example.invalid"}',
        options: Options(contentType: Headers.jsonContentType),
      );
      expect(response.data, 'server-data');
      expect(entry().level, LogLevel.info);
      expect(entry().content, contains('HTTP 200'));
      expect(entry().content, contains('"page":3'));
      expect(entry().content, isNot(contains('account@example.invalid')));
      expect(entry().content, isNot(contains('server-data')));
    },
  );

  test(
    'a broken response stream preserves its error and logs the request',
    () async {
      final failure = StateError('stream-secret');
      final responseStream = Stream<Uint8List>.error(failure);
      final dio = Dio(BaseOptions(responseType: ResponseType.stream))
        ..httpClientAdapter = _Adapter((_) => ResponseBody(responseStream, 200))
        ..interceptors.add(
          NetworkFailureInterceptor(logSuccessfulResponses: true),
        );
      addTearDown(() => dio.close(force: true));

      final response = await dio.post<ResponseBody>(
        'https://example.invalid/api/image?X-Amz-Signature=signed-secret',
        data: {'page': 2},
        options: Options(extra: {'veneraImage': true}),
      );
      expect(Log.logs, isEmpty);
      await expectLater(response.data!.stream, emitsError(same(failure)));
      expect(
        entry().content,
        contains('HTTP 200 (response_stream:StateError)'),
      );
      expect(entry().content, contains('"page":2'));
      expect(entry().content, isNot(contains('stream-secret')));
      expect(entry().content, isNot(contains('signed-secret')));
    },
  );

  test('body opt-out, opaque bodies, and scans omit their contents', () {
    final stream = StreamController<List<int>>();
    addTearDown(() {
      unawaited(stream.close());
    });
    final request = RequestOptions(
      path: 'https://example.invalid/api/items',
      method: 'POST',
      data: {'page': 2},
      extra: {'maskDataInLog': true},
    );
    NetworkDiagnostics.recordRequest(request, status: 500, failure: 'http');
    expect(entry().content, contains('Request body: [redacted]'));
    expect(entry().content, isNot(contains('"page"')));

    Log.clear();
    NetworkDiagnostics.recordRequest(
      request.copyWith(data: stream.stream, extra: {}),
      failure: 'connectionError',
    );
    expect(entry().content, contains('Request body: [stream]'));
    expect(stream.hasListener, isFalse);

    Log.clear();
    NetworkDiagnostics.recordRequest(
      request.copyWith(extra: {'veneraScan': true}),
      status: 500,
      failure: 'http',
    );
    expect(Log.logs, isEmpty);
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);

  final ResponseBody Function(RequestOptions) respond;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => respond(options);
}
