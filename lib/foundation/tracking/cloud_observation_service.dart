import 'cloud_tracking_client.dart';
import 'apply_service.dart';
import 'diagnostics.dart';
import 'observation.dart';
import 'runtime_generation.dart';
import 'trusted_catalog.dart';

class CloudObservationValidationException implements Exception {
  const CloudObservationValidationException(this.reason);

  final String reason;

  @override
  String toString() => 'CloudObservationValidationException: $reason';
}

/// Validates the Server-owned authority and freshness before handing Cloud
/// facts to the single App comparison/persistence service.
class CloudObservationService {
  const CloudObservationService({
    required this.catalog,
    required this.generations,
    required this.applyService,
    this.isInterest,
    this.isArtifactAdmitted,
    this.diagnostics,
  });

  final TrustedCatalog catalog;
  final RuntimeGenerationController generations;
  final TrackingApplyService applyService;
  final bool Function(TrustedArtifact artifact, String comicId)? isInterest;
  final bool Function(TrustedArtifact artifact)? isArtifactAdmitted;
  final TrackingDiagnostics? diagnostics;

  List<TrackingApplyResult> applySnapshot(
    CloudObservationSnapshot snapshot,
    RuntimeGeneration captured, {
    DateTime? now,
  }) {
    final currentTime = now ?? DateTime.now().toUtc();
    if (!catalog.isTrustedCatalog(snapshot.authority.catalogId)) {
      throw _reject(captured, 'catalog mismatch');
    }
    if (snapshot.authority.activeRevision != captured.revision) {
      throw _reject(captured, 'revision mismatch');
    }
    if (snapshot.authority.generation != null &&
        snapshot.authority.generation != captured.generation) {
      throw _reject(captured, 'generation mismatch');
    }
    if (captured.strategy != TrackingStrategy.cloud ||
        !generations.canCommit(captured)) {
      throw _reject(captured, 'generation is not current');
    }
    if (isArtifactAdmitted != null && !isArtifactAdmitted!(captured.artifact)) {
      throw _reject(captured, 'artifact is not admitted');
    }
    if (!snapshot.authority.contains(captured.artifact)) {
      throw _reject(captured, 'artifact is not capable');
    }

    // Validate the complete snapshot before opening the first write
    // transaction. A malformed item later in the response must not leave a
    // partially applied snapshot behind.
    final seen = <String>{};
    final observations = <TrackingObservation>[];
    for (final observation in snapshot.observations) {
      if (observation.revision != snapshot.authority.activeRevision) {
        throw _reject(
          captured,
          'observation revision mismatch',
          comicId: observation.comicId,
        );
      }
      if (observation.artifact != captured.artifact) {
        throw _reject(
          captured,
          'observation artifact mismatch',
          comicId: observation.comicId,
        );
      }
      if (!observation.validUntil.isAfter(observation.observedAt) ||
          currentTime.isAfter(observation.validUntil)) {
        throw _reject(
          captured,
          'observation is stale',
          comicId: observation.comicId,
        );
      }
      if (!seen.add(observation.comicId)) {
        throw _reject(
          captured,
          'duplicate observation comic ID',
          comicId: observation.comicId,
        );
      }
      if (isInterest != null &&
          !isInterest!(observation.artifact, observation.comicId)) {
        throw _reject(captured, 'not tracked', comicId: observation.comicId);
      }
      observations.add(observation.toTrackingObservation());
    }
    return applyService.applySnapshot(
      observations,
      canCommit: () => generations.canCommit(captured),
    );
  }

  CloudObservationValidationException _reject(
    RuntimeGeneration captured,
    String reason, {
    String comicId = '',
  }) {
    diagnostics?.recordRejection(
      sourceKey: captured.artifact.sourceKey,
      fileName: captured.artifact.fileName,
      comicId: comicId,
      reason: reason,
      runtime: {
        'generation': captured.generation,
        'revision': captured.revision,
        'strategy': captured.strategy.name,
      },
    );
    return CloudObservationValidationException(reason);
  }
}
