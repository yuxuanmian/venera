import 'cloud_tracking_client.dart';
import 'source_revision_store.dart';
import 'trusted_catalog.dart';

/// A source-scoped favorite identity supplied by the local favorite cache.
///
/// The source key is intentionally kept separate from the file name. A
/// catalog may contain two artifacts with the same source key, and resolving
/// that ambiguity is the responsibility of the active-artifact registry.
class TrackingFavoriteRef {
  const TrackingFavoriteRef({
    required this.sourceKey,
    required this.comicId,
    this.fileName,
  });

  final String sourceKey;
  final String comicId;
  final String? fileName;
}

/// Builds the exact Cloud demand set from local favorites and the active
/// source registry. The result is canonical (deduplicated and sorted), so
/// repeating a sync is idempotent and produces a stable client-state body.
class CloudInterestSync {
  const CloudInterestSync({this.catalog = const TrustedCatalog()});

  final TrustedCatalog catalog;

  List<TrackingInterest> buildInterests(
    Iterable<TrackingFavoriteRef> favorites, {
    required ActiveArtifactRegistry registry,
    Iterable<TrustedArtifact>? capableArtifacts,
  }) {
    final capabilities = capableArtifacts?.toSet();
    final activeByIdentity = <String, ActiveArtifact>{};
    for (final artifact in registry.artifacts) {
      final revision = artifact.revision;
      if (artifact.origin != ArtifactOrigin.managedCatalog ||
          revision == null ||
          artifact.activationBlocked ||
          !catalog.isValidRevision(revision)) {
        continue;
      }
      final identity = artifact.identity;
      if (capabilities != null && !capabilities.contains(identity)) continue;
      activeByIdentity['${artifact.sourceKey}\u0000${artifact.fileName}'] =
          artifact;
    }

    final unique = <String, TrackingInterest>{};
    for (final favorite in favorites) {
      final sourceKey = favorite.sourceKey.trim();
      final comicId = favorite.comicId.trim();
      if (sourceKey.isEmpty || comicId.isEmpty || comicId.length > 1024) {
        continue;
      }
      final active = favorite.fileName == null
          ? _singleActiveForSource(sourceKey, activeByIdentity)
          : activeByIdentity['$sourceKey\u0000${favorite.fileName}'];
      if (active == null) continue;
      final interest = TrackingInterest(
        artifact: active.identity,
        comicId: comicId,
      );
      unique['$sourceKey\u0000${active.fileName}\u0000$comicId'] = interest;
    }
    final result = unique.values.toList()
      ..sort((a, b) {
        final artifact = a.artifact.sourceKey.compareTo(b.artifact.sourceKey);
        if (artifact != 0) return artifact;
        final file = a.artifact.fileName.compareTo(b.artifact.fileName);
        if (file != 0) return file;
        return a.comicId.compareTo(b.comicId);
      });
    return List.unmodifiable(result);
  }

  ActiveArtifact? _singleActiveForSource(
    String sourceKey,
    Map<String, ActiveArtifact> activeByIdentity,
  ) {
    final matches = activeByIdentity.values
        .where((artifact) => artifact.sourceKey == sourceKey)
        .toList(growable: false);
    return matches.length == 1 ? matches.single : null;
  }

  Future<CloudClientState> synchronize({
    required CloudTrackingClient client,
    required bool cloudEnabled,
    required Iterable<TrackingFavoriteRef> favorites,
    required ActiveArtifactRegistry registry,
    Iterable<TrustedArtifact>? capableArtifacts,
  }) {
    final interests = buildInterests(
      favorites,
      registry: registry,
      capableArtifacts: capableArtifacts,
    );
    return client.putClientState(
      cloudEnabled: cloudEnabled,
      interests: interests,
    );
  }
}
