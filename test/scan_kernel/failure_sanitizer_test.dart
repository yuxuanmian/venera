import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/scan/failure_sanitizer.dart';
import 'package:venera/foundation/scan/scan_limits.dart';

void main() {
  test('keeps only whitelisted HTTP status and safe diagnostics', () {
    final failure = FailureSanitizer.sanitize({
      'httpStatus': 403,
      'sourceCode': ' ERR_SOURCE ',
      'exceptionType': 'TransportError',
      'message': 'Authorization: Bearer secret https://private.invalid/x',
      'retryAfter': '2026-09-10T12:00:00+08:00',
      'body': 'must be discarded',
    });
    expect(failure.httpStatus, 403);
    expect(failure.sourceCode, 'ERR_SOURCE');
    expect(failure.message, contains('<redacted>'));
    expect(failure.message, isNot(contains('secret')));
    expect(failure.message, isNot(contains('private.invalid')));
    expect(failure.retryAfter, '2026-09-10T04:00:00.000Z');
  });

  test('drops invalid status and retry-after values', () {
    final failure = FailureSanitizer.sanitize({
      'httpStatus': 700,
      'retryAfter': '30',
      'message': 'safe',
    });
    expect(failure.httpStatus, isNull);
    expect(failure.retryAfter, isNull);
    expect(failure.message, 'safe');
  });

  test('keeps a numeric source error code as a safe identifier', () {
    final failure = FailureSanitizer.sanitize({
      'httpStatus': 503,
      'sourceCode': '123',
    });

    expect(failure.httpStatus, 503);
    expect(failure.sourceCode, '123');
  });

  test('truncates UTF-8 without splitting a character', () {
    final failure = FailureSanitizer.sanitize({
      'message': '漫画' * 100,
    }, limits: const ScanLimits(maxFailureMessageBytes: 5));
    expect(failure.message, '漫');
  });

  test('arbitrary exceptions never expose their text', () {
    final failure = FailureSanitizer.fromException(
      StateError('token=top-secret password=hunter2'),
    );
    expect(failure.message, isNot(contains('top-secret')));
    expect(failure.message, isNot(contains('hunter2')));
    expect(failure.exceptionType, 'StateError');
  });

  test(
    'drops unsafe code fields and redacts structured credentials and body',
    () {
      final failure = FailureSanitizer.sanitize({
        'httpStatus': 403,
        'sourceCode': '{"token":"source-code-secret"}',
        'exceptionType': 'DioException token=exception-secret',
        'message':
            '{"authorization":"Bearer header-secret",'
            '"cookie":"session=cookie-one; other=cookie-two",'
            '"password":"password-secret"} '
            'Basic basic-secret https://private.example/path?token=query-secret',
        'body': '<html><body>response-body-secret</body></html>',
        'retryAfter': '2026-09-10T12:00:00Z',
      });

      expect(failure.httpStatus, 403);
      expect(failure.sourceCode, isNull);
      expect(failure.exceptionType, isNull);
      expect(failure.retryAfter, '2026-09-10T12:00:00.000Z');
      final encoded = failure.toJson().toString();
      for (final secret in [
        'source-code-secret',
        'exception-secret',
        'header-secret',
        'cookie-one',
        'cookie-two',
        'password-secret',
        'basic-secret',
        'query-secret',
        'response-body-secret',
        'private.example',
      ]) {
        expect(encoded, isNot(contains(secret)));
      }
    },
  );

  test('rejects credential-shaped codes and prefixed response bodies', () {
    for (final unsafe in [
      'token:synthetic-secret',
      'PASSWORD=synthetic-secret',
      'sEcReT:synthetic-secret',
      'body:synthetic-secret',
    ]) {
      final failure = FailureSanitizer.sanitize({
        'httpStatus': 429,
        'sourceCode': unsafe,
        'exceptionType': unsafe,
        'message': 'permission denied',
        'retryAfter': '2026-09-10T12:00:00Z',
      });
      expect(failure.sourceCode, isNull, reason: unsafe);
      expect(failure.exceptionType, isNull, reason: unsafe);
      expect(failure.httpStatus, 429);
      expect(failure.retryAfter, '2026-09-10T12:00:00.000Z');
    }

    for (final body in [
      'diagnostic prefix: {"opaque":"json-body-secret"}',
      'diagnostic prefix ["array-body-secret"]',
      'diagnostic prefix <svg><title>markup-body-secret</title></svg>',
      'diagnostic prefix <table><tr><td>table-body-secret</td></tr></table>',
    ]) {
      final failure = FailureSanitizer.sanitize({
        'httpStatus': 502,
        'message': body,
      });
      expect(failure.message, '<body redacted>', reason: body);
      expect(failure.message, isNot(contains('secret')));
    }

    final safe = FailureSanitizer.sanitize({
      'httpStatus': 403,
      'sourceCode': 'ERR_REMOTE',
      'exceptionType': 'ScanRequestError',
      'message': 'permission denied',
    });
    expect(safe.sourceCode, 'ERR_REMOTE');
    expect(safe.exceptionType, 'ScanRequestError');
    expect(safe.message, 'permission denied');
  });

  test('drops a JSON response body even when its fields are not sensitive', () {
    final failure = FailureSanitizer.sanitize({
      'httpStatus': 502,
      'message': '{"error":"json-response-sentinel","detail":"server text"}',
    });

    expect(failure.httpStatus, 502);
    expect(failure.message, '<body redacted>');
    expect(failure.message, isNot(contains('json-response-sentinel')));
  });
}
