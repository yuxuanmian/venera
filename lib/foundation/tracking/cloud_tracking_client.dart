import 'dart:convert';

import 'package:venera/network/app_dio.dart';

import 'observation.dart';
import 'trusted_catalog.dart';
import 'update_state.dart';

class TrackingHttpResponse {
  const TrackingHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  final int statusCode;
  final Map<String, String> headers;
  final String body;
}

abstract interface class TrackingHttpTransport {
  Future<TrackingHttpResponse> send(
    String method,
    String path, {
    Map<String, String> headers,
    String? body,
  });
}

class DioTrackingHttpTransport implements TrackingHttpTransport {
  DioTrackingHttpTransport(this.dio);

  final Dio dio;

  @override
  Future<TrackingHttpResponse> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final response = await dio.request<String>(
      path,
      data: body,
      options: Options(
        method: method,
        responseType: ResponseType.plain,
        headers: headers,
        extra: const {
          'maskHeadersInLog': ['Authorization'],
        },
        validateStatus: (_) => true,
      ),
    );
    final responseHeaders = <String, String>{};
    response.headers.forEach((key, values) {
      if (values.isNotEmpty) responseHeaders[key.toLowerCase()] = values.first;
    });
    return TrackingHttpResponse(
      statusCode: response.statusCode ?? 0,
      headers: responseHeaders,
      body: response.data ?? '',
    );
  }
}

class TrackingInterest {
  const TrackingInterest({required this.artifact, required this.comicId});

  final TrustedArtifact artifact;
  final String comicId;

  Map<String, dynamic> toJson() => {
    'artifact': artifact.toJson(),
    'comicId': comicId,
  };

  factory TrackingInterest.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('invalid tracking interest');
    final comicId = value['comicId'];
    if (comicId is! String || comicId.trim().isEmpty || comicId.length > 1024) {
      throw const FormatException('invalid tracking comic ID');
    }
    return TrackingInterest(
      artifact: TrustedArtifact.fromJson(value['artifact']),
      comicId: comicId,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TrackingInterest &&
      other.artifact == artifact &&
      other.comicId == comicId;

  @override
  int get hashCode => Object.hash(artifact, comicId);
}

class CloudClientState {
  const CloudClientState({
    required this.cloudEnabled,
    required this.interests,
    required this.stateRevision,
    required this.updatedAt,
  });

  final bool cloudEnabled;
  final List<TrackingInterest> interests;
  final int stateRevision;
  final DateTime updatedAt;

  factory CloudClientState.fromJson(Object? value) {
    if (value is! Map ||
        value['cloudEnabled'] is! bool ||
        value['interests'] is! List ||
        value['stateRevision'] is! int ||
        value['updatedAt'] is! String) {
      throw const FormatException('invalid tracking client state');
    }
    final updatedAt = _parseDateTime(value['updatedAt'] as String);
    if (updatedAt == null || (value['stateRevision'] as int) < 1) {
      throw const FormatException('invalid tracking client state timestamp');
    }
    final interests = (value['interests'] as List)
        .map(TrackingInterest.fromJson)
        .toList(growable: false);
    if (interests.length > 10000) {
      throw const FormatException('tracking interest limit exceeded');
    }
    return CloudClientState(
      cloudEnabled: value['cloudEnabled'] as bool,
      interests: interests,
      stateRevision: value['stateRevision'] as int,
      updatedAt: updatedAt,
    );
  }
}

class CloudObservation {
  const CloudObservation({
    required this.revision,
    required this.artifact,
    required this.comicId,
    required this.observedAt,
    required this.validUntil,
    required this.state,
    required this.sourceUnread,
    required this.marker,
    required this.metadata,
  });

  final String revision;
  final TrustedArtifact artifact;
  final String comicId;
  final DateTime observedAt;
  final DateTime validUntil;
  final UpdateState? state;
  final bool? sourceUnread;
  final String? marker;
  final Map<String, dynamic>? metadata;

  factory CloudObservation.fromJson(Object? value) {
    if (value is! Map ||
        value['revision'] is! String ||
        value['comicId'] is! String ||
        value['artifact'] == null ||
        value['observedAt'] is! String ||
        value['validUntil'] is! String ||
        value['favoriteUpdate'] is! Map) {
      throw const FormatException('invalid tracking observation');
    }
    final revision = value['revision'] as String;
    if (!TrustedCatalog.revisionPattern.hasMatch(revision)) {
      throw const FormatException('invalid observation revision');
    }
    final comicId = value['comicId'] as String;
    if (comicId.trim().isEmpty || comicId.length > 1024) {
      throw const FormatException('invalid observation comic ID');
    }
    final observedAt = _parseDateTime(value['observedAt'] as String);
    final validUntil = _parseDateTime(value['validUntil'] as String);
    if (observedAt == null ||
        validUntil == null ||
        !validUntil.isAfter(observedAt)) {
      throw const FormatException('invalid observation freshness');
    }
    final update = value['favoriteUpdate'] as Map;
    final state = update['state'] == null
        ? null
        : UpdateState.fromJson(update['state']);
    if (update.containsKey('state') &&
        update['state'] != null &&
        state == null) {
      throw const FormatException('invalid observation UpdateState');
    }
    bool? sourceUnread;
    if (update['sourceUnread'] != null) {
      if (update['sourceUnread'] is! bool) {
        throw const FormatException('invalid observation sourceUnread');
      }
      sourceUnread = update['sourceUnread'] as bool;
    }
    String? marker;
    if (update['marker'] != null) {
      if (update['marker'] is! String) {
        throw const FormatException('invalid observation marker');
      }
      marker = (update['marker'] as String).trim();
      if (marker.isEmpty || utf8.encode(marker).length > 4096) {
        throw const FormatException('observation marker exceeds limit');
      }
    }
    Map<String, dynamic>? metadata;
    if (update['metadata'] != null) {
      if (update['metadata'] is! Map) {
        throw const FormatException('invalid observation metadata');
      }
      metadata = Map<String, dynamic>.from(update['metadata'] as Map);
      if (utf8.encode(jsonEncode(metadata)).length > 4096) {
        throw const FormatException('observation metadata exceeds limit');
      }
    }
    return CloudObservation(
      revision: revision,
      artifact: TrustedArtifact.fromJson(value['artifact']),
      comicId: comicId,
      observedAt: observedAt,
      validUntil: validUntil,
      state: state,
      sourceUnread: sourceUnread,
      marker: marker,
      metadata: metadata,
    );
  }

  TrackingObservation toTrackingObservation() => TrackingObservation(
    origin: TrackingObservationOrigin.cloud,
    revision: revision,
    artifact: TrackingArtifactIdentity(
      sourceKey: artifact.sourceKey,
      fileName: artifact.fileName,
    ),
    comicId: comicId,
    observedAt: observedAt,
    validUntil: validUntil,
    state: state,
    sourceUnread: sourceUnread,
    marker: marker,
    metadata: metadata,
  );
}

class CloudObservationSnapshot {
  const CloudObservationSnapshot({
    required this.authority,
    required this.generatedAt,
    required this.observations,
  });

  final TrustedAuthority authority;
  final DateTime generatedAt;
  final List<CloudObservation> observations;

  factory CloudObservationSnapshot.fromJson(Object? value) {
    if (value is! Map ||
        value['authority'] == null ||
        value['generatedAt'] is! String ||
        value['observations'] is! List) {
      throw const FormatException('invalid tracking observation snapshot');
    }
    final generatedAt = _parseDateTime(value['generatedAt'] as String);
    if (generatedAt == null) {
      throw const FormatException('invalid tracking snapshot time');
    }
    final raw = value['observations'] as List;
    if (raw.length > 10000) {
      throw const FormatException('tracking observation limit exceeded');
    }
    return CloudObservationSnapshot(
      authority: TrustedAuthority.fromJson(value['authority']),
      generatedAt: generatedAt,
      observations: List.unmodifiable(raw.map(CloudObservation.fromJson)),
    );
  }
}

class CloudObservationResult {
  const CloudObservationResult({
    required this.snapshot,
    required this.notModified,
    required this.etag,
  });

  final CloudObservationSnapshot? snapshot;
  final bool notModified;
  final String? etag;
}

class CloudTrackingException implements Exception {
  const CloudTrackingException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.requestId,
  });

  final int statusCode;
  final String code;
  final String message;
  final String? requestId;

  @override
  String toString() => 'CloudTrackingException($statusCode, $code): $message';
}

class CloudTrackingClient {
  CloudTrackingClient({
    required Uri server,
    String? accessToken,
    TrackingHttpTransport? transport,
    this.catalog = const TrustedCatalog(),
  }) : server = _normalizeServer(server),
       accessToken = accessToken?.trim() ?? '',
       transport =
           transport ??
           DioTrackingHttpTransport(
             AppDio(BaseOptions(baseUrl: _normalizeServer(server).toString())),
           );

  final Uri server;
  final String accessToken;
  final TrustedCatalog catalog;
  final TrackingHttpTransport transport;
  String? _etag;
  CloudObservationSnapshot? _cachedSnapshot;

  Future<TrustedAuthority> getAuthority() async {
    final response = await _send('GET', '/api/tracking/authority');
    if (response.statusCode != 200) throw _exception(response);
    final data = _data(response);
    final authority = TrustedAuthority.fromJson(data);
    if (!catalog.isTrustedCatalog(authority.catalogId)) {
      throw const CloudTrackingException(
        statusCode: 409,
        code: 'catalog_mismatch',
        message: 'tracking authority is not trusted',
      );
    }
    return authority;
  }

  Future<CloudClientState> putClientState({
    required bool cloudEnabled,
    required List<TrackingInterest> interests,
  }) async {
    if (interests.length > 10000) {
      throw const CloudTrackingException(
        statusCode: 400,
        code: 'client_state_invalid',
        message: 'too many tracking interests',
      );
    }
    final response = await _send(
      'PUT',
      '/api/tracking/client-state',
      body: jsonEncode({
        'cloudEnabled': cloudEnabled,
        'interests': interests.map((e) => e.toJson()).toList(),
      }),
    );
    if (response.statusCode != 200) throw _exception(response);
    return CloudClientState.fromJson(_data(response));
  }

  Future<CloudObservationResult> getObservations() async {
    final headers = <String, String>{};
    if (_etag != null) headers['If-None-Match'] = _etag!;
    final response = await _send(
      'GET',
      '/api/tracking/observations',
      headers: headers,
    );
    final etag = response.headers['etag'];
    if (response.statusCode == 304) {
      return CloudObservationResult(
        snapshot: _cachedSnapshot,
        notModified: true,
        etag: etag ?? _etag,
      );
    }
    if (response.statusCode != 200) throw _exception(response);
    final snapshot = CloudObservationSnapshot.fromJson(_data(response));
    if (snapshot.observations.length > 10000) {
      throw const CloudTrackingException(
        statusCode: 409,
        code: 'observation_limit_exceeded',
        message: 'too many observations',
      );
    }
    _etag = etag;
    _cachedSnapshot = snapshot;
    return CloudObservationResult(
      snapshot: snapshot,
      notModified: false,
      etag: etag,
    );
  }

  Future<TrackingHttpResponse> _send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final allHeaders = <String, String>{
      'Accept': 'application/json',
      ...headers,
    };
    if (body != null) allHeaders['Content-Type'] = 'application/json';
    if (accessToken.isNotEmpty) {
      allHeaders['Authorization'] = 'Bearer $accessToken';
    }
    final response = await transport.send(
      method,
      path,
      headers: allHeaders,
      body: body,
    );
    if (utf8.encode(response.body).length > 16 * 1024 * 1024) {
      throw const CloudTrackingException(
        statusCode: 413,
        code: 'response_too_large',
        message: 'tracking response exceeds the client limit',
      );
    }
    return response;
  }

  dynamic _data(TrackingHttpResponse response) {
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['data'] == null) {
      throw const CloudTrackingException(
        statusCode: 502,
        code: 'invalid_tracking_response',
        message: 'tracking response has no data envelope',
      );
    }
    return decoded['data'];
  }

  CloudTrackingException _exception(TrackingHttpResponse response) {
    try {
      final decoded = jsonDecode(response.body);
      final error = decoded is Map ? decoded['error'] : null;
      if (error is Map) {
        return CloudTrackingException(
          statusCode: response.statusCode,
          code: error['code']?.toString() ?? 'tracking_error',
          message: error['message']?.toString() ?? 'tracking request failed',
          requestId: error['request_id']?.toString(),
        );
      }
    } catch (_) {}
    return CloudTrackingException(
      statusCode: response.statusCode,
      code: 'tracking_error',
      message: 'tracking request failed',
    );
  }

  static Uri _normalizeServer(Uri value) {
    if (value.scheme != 'http' && value.scheme != 'https' ||
        value.host.isEmpty) {
      throw const FormatException('tracking server URL must be HTTP(S)');
    }
    final path = value.path.endsWith('/')
        ? value.path.substring(0, value.path.length - 1)
        : value.path;
    return value.replace(path: path, query: null, fragment: null);
  }
}

DateTime? _parseDateTime(String value) {
  final candidate = value.trim();
  if (!RegExp(
    r'^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$',
  ).hasMatch(candidate)) {
    return null;
  }
  try {
    return DateTime.parse(candidate).toUtc();
  } catch (_) {
    return null;
  }
}
