import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:venera/foundation/log.dart';

/// Records the request for both rejected and accepted HTTP error responses.
/// It does not change the response or exception passed to callers.
class NetworkFailureInterceptor extends Interceptor {
  NetworkFailureInterceptor({this.logSuccessfulResponses = false});

  final bool logSuccessfulResponses;

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final status = response.statusCode;
    final request = response.requestOptions;
    if (request.extra['veneraScan'] == true) {
      handler.next(response);
      return;
    }
    if (status != null && status >= 400) {
      NetworkDiagnostics.recordRequest(
        request,
        status: status,
        failure: 'http',
      );
    } else {
      if (logSuccessfulResponses && request.extra['veneraImage'] != true) {
        NetworkDiagnostics.recordRequest(request, status: status);
      }
      // Download and image requests can fail while reading a body after their
      // response headers have already passed the interceptor.
      final body = response.data;
      if (body is ResponseBody) {
        body.stream = body.stream.handleError((Object error, StackTrace stack) {
          if (request.cancelToken?.isCancelled != true &&
              !(error is DioException && CancelToken.isCancel(error))) {
            NetworkDiagnostics.recordRequest(
              request,
              status: status,
              failure: 'response_stream:${error.runtimeType}',
            );
          }
          Error.throwWithStackTrace(error, stack);
        });
      }
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.type != DioExceptionType.cancel) {
      NetworkDiagnostics.recordRequest(
        err.requestOptions,
        status: err.response?.statusCode,
        failure: err.type == DioExceptionType.unknown && err.error != null
            ? err.error.runtimeType.toString()
            : err.type.name,
      );
    }
    handler.next(err);
  }
}

class NetworkDiagnostics {
  static const _redacted = '[redacted]';
  static const _omitted = '[omitted]';
  static final _method = RegExp(r'^[A-Za-z]{1,20}$');
  static final _name = RegExp(r'^[A-Za-z0-9_.\[\]-]{1,64}$');
  static final _normalizedSeparators = RegExp(r'[^a-z0-9]');
  static final _sensitiveName = RegExp(
    r'token|cookie|password|passwd|passphrase|authorization|credential|secret|'
    r'session|signature|apikey|authkey|accesskey|privatekey|username|userid|account|'
    r'email|phone|mobile|deviceid|verifier|^login|^auth$|^user$|^pass$|^pwd$|^key$|'
    r'^sig$|^sign$|^code$|^hash$|^csrf|^xsrf|^otp$|^jwt$|^nonce$|^xamz|^xgoog|^policy$',
  );
  static final _credentialPath = RegExp(
    r'^(?:auth|oauth2?|login|log-in|signin|sign-in|signup|sign-up|register|token|password)$',
    caseSensitive: false,
  );
  static final _privateText = RegExp(
    r'https?://|\b(?:bearer|basic)\s+\S+|[\w.+-]+@[\w.-]+\.[a-z]{2,}|'
    r'[A-Za-z0-9_+/%=-]{32,}|(?:[A-Za-z0-9_-]{6,}\.){2}[A-Za-z0-9_-]{6,}|'
    r'[\x00-\x1f\x7f-\x9f]',
    caseSensitive: false,
  );
  static final _inlineField = RegExp(r'''["']?([\w.-]{1,64})["']?\s*[:=]''');

  static void recordRequest(
    RequestOptions request, {
    int? status,
    String? failure,
  }) {
    if (request.extra['veneraScan'] == true || Log.isMuted) return;
    Uri? uri;
    String? contentType;
    try {
      uri = request.uri;
      contentType = request.contentType;
    } catch (_) {
      // The raw invalid URL could itself contain a secret or control characters.
    }
    record(
      method: request.method,
      uri: uri,
      data: request.data,
      contentType: contentType,
      protectBody: request.extra['maskDataInLog'] == true,
      status: status,
      failure: failure,
    );
  }

  static void record({
    required String method,
    required Uri? uri,
    Object? data,
    String? contentType,
    bool protectBody = false,
    int? status,
    String? failure,
  }) {
    if (Log.isMuted) return;
    // Diagnostics must never interfere with delivery of the original result.
    var url = '[invalid URL]';
    var body = _omitted;
    try {
      final authentication =
          uri != null &&
          uri.path.length <= 1024 &&
          uri.pathSegments.any(_credentialPath.hasMatch);
      if (uri != null) url = _url(uri, authentication: authentication);
      body = data == null
          ? '[none]'
          : protectBody || authentication
          ? _redacted
          : _body(data, contentType);
    } catch (_) {
      // URL decoding, custom request data, or a malformed preview can fail.
    }
    final statusLabel = status == null ? '' : ' HTTP $status';
    final failureLabel = failure == null ? '' : ' ($failure)';
    final verb = _method.hasMatch(method) ? method : 'HTTP';
    try {
      Log.addLog(
        failure == null ? LogLevel.info : LogLevel.error,
        'Network',
        '$verb $url$statusLabel$failureLabel\nRequest body: $body',
      );
    } catch (_) {
      // A failing log sink must not replace the original network result.
    }
  }

  static String _url(Uri uri, {required bool authentication}) {
    if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      return '[invalid URL]';
    }
    final parts = <String>[];
    var redactNext = false;
    if (uri.path.length <= 1024) {
      for (final part in uri.pathSegments) {
        parts.add(redactNext ? _redacted : _text(part));
        redactNext = _credentialPath.hasMatch(part) || _secretKey(part);
      }
    } else {
      parts.add(_omitted);
    }
    final params = <String, Object>{};
    if (uri.query.length > 4096) {
      params['query'] = _omitted;
    } else {
      for (final field in uri.queryParametersAll.entries.take(24)) {
        if (!_name.hasMatch(field.key)) continue;
        params[field.key] = authentication || _secretKey(field.key)
            ? _redacted
            : field.value.take(4).map(_text).toList(growable: false);
      }
    }
    return _limit(
      Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        pathSegments: parts,
        queryParameters: params.isEmpty ? null : params,
      ).toString(),
      1000,
    );
  }

  static String _body(Object data, String? contentType) {
    if (data is List<int>) return '[bytes: ${data.length}]';
    if (data is TypedData) return '[bytes: ${data.lengthInBytes}]';
    if (data is Stream) return '[stream]';
    Object? value = data;
    if (data is FormData) {
      value = {
        'fields': {
          for (final field in data.fields.take(20)) field.key: field.value,
        },
        'files': data.files.length,
      };
    } else if (data is String) {
      if (data.length > 16384) return '[text omitted: ${data.length} chars]';
      final text = data.trimLeft();
      if (contentType?.toLowerCase().startsWith(
            'application/x-www-form-urlencoded',
          ) ==
          true) {
        value = Uri(query: text).queryParametersAll;
      } else if (text.startsWith('{') || text.startsWith('[')) {
        try {
          value = jsonDecode(text);
        } on FormatException {
          return '[malformed JSON omitted]';
        }
      } else {
        return '[text omitted: ${data.length} chars]';
      }
    }
    if (value is! Map && value is! List) return _omitted;
    return _limit(jsonEncode(_BodyPreview().render(value)), 1700);
  }

  static bool _secretKey(String key) => _sensitiveName.hasMatch(
    key.toLowerCase().replaceAll(_normalizedSeparators, ''),
  );

  static String _text(String value) {
    if (value.length > 256) return _omitted;
    if (_privateText.hasMatch(value) ||
        _inlineField
            .allMatches(value)
            .any((match) => _secretKey(match.group(1)!))) {
      return _redacted;
    }
    return value;
  }

  static String _limit(String value, int max) =>
      value.length <= max ? value : '${value.substring(0, max)}…';
}

class _BodyPreview {
  int _remaining = 64;

  Object? render(Object? value, [int depth = 0]) {
    if (_remaining-- <= 0 || depth > 4) return NetworkDiagnostics._omitted;
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries.take(16))
          if (entry.key is String &&
              NetworkDiagnostics._name.hasMatch(entry.key))
            entry.key as String: NetworkDiagnostics._secretKey(entry.key)
                ? NetworkDiagnostics._redacted
                : render(entry.value, depth + 1),
      };
    }
    if (value is List) {
      return [for (final item in value.take(16)) render(item, depth + 1)];
    }
    if (value is String) return NetworkDiagnostics._text(value);
    if (value == null || value is bool || value is num) return value;
    return NetworkDiagnostics._omitted;
  }
}
