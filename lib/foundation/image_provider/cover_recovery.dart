import 'package:dio/dio.dart';

/// The result of a cover load, including the URL that actually produced it.
class CoverRecoveryResult<T> {
  const CoverRecoveryResult({
    required this.value,
    required this.url,
    required this.refreshed,
  });

  final T value;
  final String url;
  final bool refreshed;
}

/// A diagnostic error raised when cover recovery cannot start or finish.
class CoverRecoveryException implements Exception {
  const CoverRecoveryException(this.message);

  final String message;

  @override
  String toString() => 'CoverRecoveryException: $message';
}

/// Returns the HTTP status carried by [error], when it can be identified.
///
/// Dio's response status is authoritative. The text fallback is intentionally
/// narrow so unrelated errors mentioning a number are not treated as HTTP
/// status errors.
int? coverHttpStatus(Object error) {
  if (error is DioException) {
    final statusCode = error.response?.statusCode;
    if (statusCode != null) {
      return statusCode;
    }
  }

  final match = RegExp(
    r'Invalid Status Code:\s*(\d{3})(?!\d)',
  ).firstMatch(error.toString());
  return match == null ? null : int.tryParse(match.group(1)!);
}

bool isMissingCoverError(Object error) {
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.cancel:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return false;
      default:
        break;
    }
  }
  final statusCode = coverHttpStatus(error);
  return statusCode == 404 || statusCode == 410;
}

/// Loads a cover once and, only for a missing cover response, refreshes its URL
/// once and tries that URL once more.
Future<CoverRecoveryResult<T>> recoverCover<T>({
  required String initialUrl,
  required Future<T> Function(String url) load,
  required Future<String?> Function() refreshUrl,
}) async {
  if (initialUrl.isEmpty) {
    throw const CoverRecoveryException('Initial cover URL is empty.');
  }

  try {
    final value = await load(initialUrl);
    return CoverRecoveryResult(value: value, url: initialUrl, refreshed: false);
  } catch (error) {
    if (!isMissingCoverError(error)) {
      rethrow;
    }
  }

  final refreshedUrl = await refreshUrl();
  if (refreshedUrl == null || refreshedUrl.isEmpty) {
    throw const CoverRecoveryException('Refreshed cover URL is empty.');
  }

  final value = await load(refreshedUrl);
  return CoverRecoveryResult(value: value, url: refreshedUrl, refreshed: true);
}
