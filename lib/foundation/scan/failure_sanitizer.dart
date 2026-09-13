import 'dart:convert';

import 'scan_limits.dart';
import 'models.dart';

/// Converts untrusted source/transport diagnostics to the small, safe failure
/// vocabulary allowed by Contract O.
class FailureSanitizer {
  static final _credentialFieldPattern = RegExp(
    r'''(?:^|\s|[{},();\[\]])["']?(?:authorization|cookie|set-cookie|token|password|passwd|secret|api[-_]?key|body)["']?\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;}]+)''',
    caseSensitive: false,
  );
  static final _markupPattern = RegExp(
    r'''<\s*(?:/?[A-Za-z][^>]*|![^>]*|--[^>]*)>''',
    caseSensitive: false,
  );

  static ScanFailure sanitize(
    Object? value, {
    ScanLimits limits = const ScanLimits(),
    String defaultMessage = 'Scan failed without diagnostic details',
  }) {
    final map = value is ScanFailure
        ? value.toJson()
        : value is Map
        ? value
        : const <String, dynamic>{};

    int? status;
    final rawStatus = map['httpStatus'];
    if (rawStatus is int && rawStatus >= 100 && rawStatus <= 599) {
      status = rawStatus;
    }

    final sourceCode = _safeCodeField(
      map['sourceCode'],
      limits.maxSourceCodeBytes,
    );
    final exceptionType = _safeCodeField(
      map['exceptionType'],
      limits.maxExceptionTypeBytes,
    );
    final rawMessage = map['message'];
    final message = _stringField(
      rawMessage,
      limits.maxFailureMessageBytes,
      redact: true,
    );
    final retryAfter = _retryAfter(map['retryAfter']);
    final safeDefault = _stringField(
      defaultMessage,
      limits.maxFailureMessageBytes,
      redact: true,
    );
    final result = ScanFailure(
      httpStatus: status,
      sourceCode: sourceCode,
      exceptionType: exceptionType,
      message: message == null || message.isEmpty
          ? safeDefault ?? 'Scan failed without diagnostic details'
          : message,
      retryAfter: retryAfter,
    );
    if (_utf8Length(jsonEncode(result.toJson())) <=
        limits.maxFailureJsonBytes) {
      return result;
    }
    return ScanFailure(
      httpStatus: status,
      exceptionType: exceptionType,
      message: 'Scan failure diagnostic exceeded its size limit',
    );
  }

  static ScanFailure fromException(
    Object error, {
    int? httpStatus,
    String? exceptionType,
    ScanLimits limits = const ScanLimits(),
  }) {
    return sanitize({
      'httpStatus': httpStatus,
      'exceptionType': exceptionType ?? _exceptionType(error),
      // Do not use DioException.toString() or a request object here. The
      // caller may pass a controlled, already-safe message instead.
      'message': _safeExceptionMessage(error),
    }, limits: limits);
  }

  static String? _stringField(
    Object? value,
    int maxBytes, {
    bool redact = false,
  }) {
    if (value is! String) return null;
    var result = value.trim();
    if (redact) result = _redact(result);
    if (result.isEmpty) return null;
    return _truncateUtf8(result, maxBytes);
  }

  /// Source error codes and exception type names are useful only when they
  /// stay within a deliberately tiny identifier vocabulary.  Treat anything
  /// else as untrusted message text and drop it rather than persisting a
  /// caller-controlled credential or response fragment under a diagnostic
  /// field that looks safe.
  static String? _safeCodeField(Object? value, int maxBytes) {
    if (value is! String) return null;
    final result = value.trim();
    if (result.isEmpty ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$').hasMatch(result) ||
        _containsUntrustedDiagnosticText(result)) {
      return null;
    }
    return _truncateUtf8(result, maxBytes);
  }

  static bool _containsUntrustedDiagnosticText(String value) =>
      _credentialFieldPattern.hasMatch(value) ||
      _markupPattern.hasMatch(value) ||
      value.contains('{') ||
      value.contains('[');

  static String? _retryAfter(Object? value) {
    if (value is! String) return null;
    final candidate = value.trim();
    if (candidate.isEmpty) return null;
    final hasTimezone =
        candidate.endsWith('Z') ||
        RegExp(r'[+-]\d{2}:\d{2}$').hasMatch(candidate);
    if (!hasTimezone) return null;
    final parsed = DateTime.tryParse(candidate);
    if (parsed == null) return null;
    return parsed.toUtc().toIso8601String();
  }

  static String _redact(String input) {
    var result = input;
    // A response body may be prefixed by a short diagnostic.  Once a
    // structure or markup marker appears, discard the whole message rather
    // than attempting to redact an unknown response schema field-by-field.
    if (_markupPattern.hasMatch(result) ||
        result.contains('{') ||
        result.contains('[')) {
      return '<body redacted>';
    }
    // Cookie values can contain several semicolon-separated pairs. Consume
    // the complete field before the generic key/value pass so the second
    // pair cannot survive as a retained diagnostic fragment.
    result = result.replaceAllMapped(
      RegExp(
        r'''(?:["']?)(cookie|set-cookie)(?:["']?)\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\r\n,}]+)''',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}=<redacted>',
    );
    result = result.replaceAllMapped(
      RegExp(
        r'''(?:["']?)(authorization|token|password|passwd|secret|api[-_]?key|body)(?:["']?)\s*[:=]\s*(?:"[^"]*"|'[^']*'|(?:Bearer|Basic)\s+[^\s,;}]+|[^\s,;}]+)''',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}=<redacted>',
    );
    result = result.replaceAll(
      RegExp(r'''\b(?:Bearer|Basic)\s+[^\s,;}"']+''', caseSensitive: false),
      'Bearer <redacted>',
    );
    // A diagnostic may receive a serialized response or an HTML error page
    // through an exception message. Drop the whole markup-bearing fragment;
    // removing tags alone would still retain the response body.
    result = result.replaceAll(
      RegExp(r'https?://[^\s]+', caseSensitive: false),
      '<url>',
    );
    return result;
  }

  static String _safeExceptionMessage(Object error) {
    // Only retain a type-level diagnostic for arbitrary exceptions. Source
    // messages are separately sanitized when they are supplied as a map.
    return 'Scan operation failed (${_exceptionType(error)})';
  }

  static String _exceptionType(Object error) {
    final name = error.runtimeType.toString();
    return _truncateUtf8(name, 128);
  }

  static int _utf8Length(String value) => utf8.encode(value).length;

  static String _truncateUtf8(String value, int maxBytes) {
    final bytes = utf8.encode(value);
    if (bytes.length <= maxBytes) return value;
    var end = maxBytes;
    while (end > 0 && (bytes[end] & 0xc0) == 0x80) {
      end--;
    }
    return utf8.decode(bytes.sublist(0, end), allowMalformed: false);
  }
}
