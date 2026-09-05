import 'update_state.dart';

enum TrackingObservationOrigin { localDetail, localOptimized, cloud }

class TrackingArtifactIdentity {
  const TrackingArtifactIdentity({
    required this.sourceKey,
    required this.fileName,
  });

  final String sourceKey;
  final String fileName;

  Map<String, dynamic> toJson() => {
    'sourceKey': sourceKey,
    'fileName': fileName,
  };

  static TrackingArtifactIdentity? fromJson(Object? value) {
    if (value is! Map) return null;
    final sourceKey = value['sourceKey'];
    final fileName = value['fileName'];
    if (sourceKey is! String ||
        sourceKey.trim().isEmpty ||
        fileName is! String ||
        fileName.trim().isEmpty) {
      return null;
    }
    return TrackingArtifactIdentity(
      sourceKey: sourceKey.trim(),
      fileName: fileName.trim(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TrackingArtifactIdentity &&
      other.sourceKey == sourceKey &&
      other.fileName == fileName;

  @override
  int get hashCode => Object.hash(sourceKey, fileName);
}

class TrackingObservation {
  const TrackingObservation({
    required this.origin,
    required this.revision,
    required this.artifact,
    required this.comicId,
    required this.observedAt,
    required this.validUntil,
    this.state,
    this.sourceUnread,
    this.marker,
    this.metadata,
    this.normalizationDrops = const [],
    this.compatibilityNotes = const [],
  });

  final TrackingObservationOrigin origin;
  final String revision;
  final TrackingArtifactIdentity artifact;
  final String comicId;
  final DateTime observedAt;
  final DateTime validUntil;
  final UpdateState? state;
  final bool? sourceUnread;
  final String? marker;
  final Map<String, dynamic>? metadata;
  final List<Map<String, String>> normalizationDrops;
  final List<String> compatibilityNotes;

  bool isFreshAt(DateTime now) => !now.isAfter(validUntil);

  String get sourceKey => artifact.sourceKey;
}

class TrackingBaseline {
  const TrackingBaseline({
    this.state,
    this.marker,
    this.metadata,
    this.hasNewUpdate = false,
    this.baselineAt,
    this.sourceActivityAt,
  });

  final UpdateState? state;
  final String? marker;
  final Map<String, dynamic>? metadata;
  final bool hasNewUpdate;
  final DateTime? baselineAt;
  final DateTime? sourceActivityAt;
}
