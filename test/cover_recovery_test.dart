import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/cover_recovery.dart';

DioException _statusError(int statusCode) {
  final requestOptions = RequestOptions(path: 'https://example.com/cover');
  return DioException(
    requestOptions: requestOptions,
    response: Response(requestOptions: requestOptions, statusCode: statusCode),
  );
}

void main() {
  test('404 refreshes once and loads the replacement URL', () async {
    final requestedUrls = <String>[];
    var refreshCalls = 0;

    final result = await recoverCover<int>(
      initialUrl: 'https://example.com/old.jpg',
      load: (url) async {
        requestedUrls.add(url);
        if (url.endsWith('old.jpg')) {
          throw _statusError(404);
        }
        return 42;
      },
      refreshUrl: () async {
        refreshCalls++;
        return 'https://example.com/new.jpg';
      },
    );

    expect(result.value, 42);
    expect(result.url, 'https://example.com/new.jpg');
    expect(result.refreshed, isTrue);
    expect(requestedUrls, [
      'https://example.com/old.jpg',
      'https://example.com/new.jpg',
    ]);
    expect(refreshCalls, 1);
  });

  test(
    'a refreshed URL equal to the old URL is loaded exactly once more',
    () async {
      var loadCalls = 0;
      var refreshCalls = 0;

      final result = await recoverCover<int>(
        initialUrl: 'https://example.com/same.jpg',
        load: (_) async {
          loadCalls++;
          if (loadCalls == 1) throw _statusError(410);
          return 7;
        },
        refreshUrl: () async {
          refreshCalls++;
          return 'https://example.com/same.jpg';
        },
      );

      expect(result.value, 7);
      expect(result.url, 'https://example.com/same.jpg');
      expect(loadCalls, 2);
      expect(refreshCalls, 1);
    },
  );

  test(
    'a second missing response terminates without another refresh',
    () async {
      var loadCalls = 0;
      var refreshCalls = 0;
      final secondError = _statusError(410);

      final future = recoverCover<void>(
        initialUrl: 'https://example.com/old.jpg',
        load: (_) async {
          loadCalls++;
          if (loadCalls == 1) throw _statusError(404);
          throw secondError;
        },
        refreshUrl: () async {
          refreshCalls++;
          return 'https://example.com/new.jpg';
        },
      );

      await expectLater(future, throwsA(same(secondError)));
      expect(loadCalls, 2);
      expect(refreshCalls, 1);
    },
  );

  test(
    'a second non-missing failure is propagated without another refresh',
    () async {
      var loadCalls = 0;
      var refreshCalls = 0;
      final secondError = StateError('replacement failed');

      final future = recoverCover<void>(
        initialUrl: 'https://example.com/old.jpg',
        load: (_) async {
          loadCalls++;
          if (loadCalls == 1) throw _statusError(404);
          throw secondError;
        },
        refreshUrl: () async {
          refreshCalls++;
          return 'https://example.com/new.jpg';
        },
      );

      await expectLater(future, throwsA(same(secondError)));
      expect(loadCalls, 2);
      expect(refreshCalls, 1);
    },
  );

  test('403, cancellation, and timeout do not refresh', () async {
    final errors = <Object>[
      _statusError(403),
      DioException(
        requestOptions: RequestOptions(path: '/cover'),
        type: DioExceptionType.cancel,
      ),
      DioException(
        requestOptions: RequestOptions(path: '/cover'),
        response: Response(
          requestOptions: RequestOptions(path: '/cover'),
          statusCode: 404,
        ),
        type: DioExceptionType.cancel,
      ),
      DioException(
        requestOptions: RequestOptions(path: '/cover'),
        type: DioExceptionType.connectionTimeout,
      ),
    ];

    for (final error in errors) {
      var loadCalls = 0;
      var refreshCalls = 0;
      final future = recoverCover<void>(
        initialUrl: 'https://example.com/old.jpg',
        load: (_) async {
          loadCalls++;
          throw error;
        },
        refreshUrl: () async {
          refreshCalls++;
          return 'https://example.com/new.jpg';
        },
      );

      await expectLater(future, throwsA(same(error)));
      expect(loadCalls, 1);
      expect(refreshCalls, 0);
    }
  });

  test('empty initial and refreshed URLs terminate without looping', () async {
    var loadCalls = 0;
    var refreshCalls = 0;

    await expectLater(
      recoverCover<void>(
        initialUrl: '',
        load: (_) async {
          loadCalls++;
        },
        refreshUrl: () async {
          refreshCalls++;
          return 'https://example.com/new.jpg';
        },
      ),
      throwsA(isA<CoverRecoveryException>()),
    );
    expect(loadCalls, 0);
    expect(refreshCalls, 0);

    await expectLater(
      recoverCover<void>(
        initialUrl: 'https://example.com/old.jpg',
        load: (_) async {
          loadCalls++;
          throw _statusError(404);
        },
        refreshUrl: () async {
          refreshCalls++;
          return '';
        },
      ),
      throwsA(isA<CoverRecoveryException>()),
    );
    expect(loadCalls, 1);
    expect(refreshCalls, 1);
  });

  test(
    'a refresh exception terminates without another image request',
    () async {
      var loadCalls = 0;
      var refreshCalls = 0;
      final refreshError = StateError('comic info failed');

      final future = recoverCover<void>(
        initialUrl: 'https://example.com/old.jpg',
        load: (_) async {
          loadCalls++;
          throw _statusError(404);
        },
        refreshUrl: () async {
          refreshCalls++;
          throw refreshError;
        },
      );

      await expectLater(future, throwsA(same(refreshError)));
      expect(loadCalls, 1);
      expect(refreshCalls, 1);
    },
  );

  test('status detection prefers Dio response and rejects loose text', () {
    expect(coverHttpStatus(_statusError(404)), 404);
    expect(isMissingCoverError(Exception('Invalid Status Code: 410')), isTrue);
    expect(
      isMissingCoverError(Exception('server mentioned status 410')),
      isFalse,
    );
  });
}
