import '../catalog/runtime_context.dart';
import 'models.dart';
import 'scan_call_lease.dart';

typedef ScanHostRequest =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> request);

typedef ScanHostRequestFactory = ScanHostRequest Function(ScanCallLease lease);

typedef ScanComicLoader =
    Future<Object?> Function(String comicId, ScanHostRequest request);

typedef ScanCollectionLoader =
    Future<Object?> Function(
      String collectionKey,
      Object? cursor,
      ScanHostRequest request,
    );

class ScanHttpRequest {
  const ScanHttpRequest({
    required this.method,
    required this.url,
    this.headers = const {},
    this.body,
  });

  final String method;
  final String url;
  final Map<String, String> headers;
  final String? body;

  factory ScanHttpRequest.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('invalid scan request');
    final method = value['method'];
    final url = value['url'];
    if (method is! String || url is! String) {
      throw const FormatException('scan request requires method and url');
    }
    final upper = method.toUpperCase();
    if (upper != 'GET' && upper != 'POST') {
      throw const FormatException('scan request method is not supported');
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('scan request URL is not allowed');
    }
    final rawHeaders = value['headers'];
    final headers = <String, String>{};
    if (rawHeaders != null) {
      if (rawHeaders is! Map) {
        throw const FormatException('invalid scan request headers');
      }
      for (final entry in rawHeaders.entries) {
        if (entry.key is! String || entry.value is! String) {
          throw const FormatException('scan request headers must be strings');
        }
        headers[entry.key as String] = entry.value as String;
      }
    }
    final body = value['body'];
    if (body != null && body is! String) {
      throw const FormatException('scan request body must be a string');
    }
    return ScanHttpRequest(
      method: upper,
      url: url,
      headers: Map.unmodifiable(headers),
      body: body as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'method': method,
    'url': url,
    if (headers.isNotEmpty) 'headers': Map<String, String>.from(headers),
    if (body != null) 'body': body,
  };
}

class ScanHttpResponse {
  const ScanHttpResponse({
    required this.status,
    required this.headers,
    required this.body,
  });

  final int status;
  final Map<String, String> headers;
  final String body;

  Map<String, dynamic> toJson() => {
    'status': status,
    'headers': Map<String, String>.from(headers),
    'body': body,
  };
}

class ScanHostRequestException implements Exception {
  const ScanHostRequestException(this.failure);

  final ScanFailure failure;
}

enum ScanCapabilitiesState { absent, invalid, supported }

class ScanCapability {
  const ScanCapability.comic(this.load, {this.evidenceSchema})
    : producer = ScanProducer.comic;
  const ScanCapability.collection(this.load, {this.evidenceSchema})
    : producer = ScanProducer.collection;

  final ScanProducer producer;
  final Object load;

  /// The normalized comparable label of this branch's mapping declaration.
  ///
  /// Null means the branch declared no usable mapping; such a branch is
  /// reported as [ScanCapabilitiesState.invalid] and is not selectable
  /// (Contract C1/C6).
  final String? evidenceSchema;

  ScanComicLoader get comicLoad => load as ScanComicLoader;
  ScanCollectionLoader get collectionLoad => load as ScanCollectionLoader;
}

/// Immutable capability information captured while parsing one Source.
class ScanCapabilities {
  const ScanCapabilities._({
    required this.state,
    this.primary,
    this.comic,
    this.collection,
    this.reason,
    this.onDispose,
  });

  const ScanCapabilities.absent() : this._(state: ScanCapabilitiesState.absent);

  const ScanCapabilities.invalid(String reason)
    : this._(state: ScanCapabilitiesState.invalid, reason: reason);

  const ScanCapabilities.supported({
    required ScanProducer primary,
    ScanCapability? comic,
    ScanCapability? collection,
    void Function()? onDispose,
  }) : this._(
         state: ScanCapabilitiesState.supported,
         primary: primary,
         comic: comic,
         collection: collection,
         onDispose: onDispose,
       );

  final ScanCapabilitiesState state;
  final ScanProducer? primary;
  final ScanCapability? comic;
  final ScanCapability? collection;
  final String? reason;
  final void Function()? onDispose;

  bool get isSupported => state == ScanCapabilitiesState.supported;
  ScanCapability? get selected =>
      primary == ScanProducer.comic ? comic : collection;

  /// The comparable label of the currently selected branch.
  ///
  /// A declaration lives on a branch, so switching `primary` changes the label
  /// structurally rather than by convention (Contract C1).
  String? get selectedEvidenceSchema => selected?.evidenceSchema;

  void dispose() => onDispose?.call();
}

abstract class ScanSourceAdapter {
  String get sourceKey;
  String get definitionRevision;

  /// Comparable label of the branch this adapter was built from.
  String? get evidenceSchema;

  ManagedSourceContext? get runtimeContext;
  ScanCapabilities get capabilities;

  Future<Object?> loadComic(String comicId, ScanCallLease lease);

  Future<Object?> loadCollection(
    String collectionKey,
    Object? cursor,
    ScanCallLease lease,
  );
}
