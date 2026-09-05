import 'runtime_generation.dart';
import 'trusted_catalog.dart';

class TrackingModeController {
  TrackingModeController({
    this.followUpdatesEnabled = false,
    this.cloudEnabled = false,
  });

  bool followUpdatesEnabled;
  bool cloudEnabled;
  final _capable = <TrustedArtifact>{};
  final _aligned = <TrustedArtifact>{};
  final _pausedReasons = <TrustedArtifact, String>{};
  final _known = <TrustedArtifact>{};
  final _activationBlocked = <TrustedArtifact>{};

  void setCapability(TrustedArtifact artifact, bool capable) {
    _known.add(artifact);
    if (capable) {
      _capable.add(artifact);
    } else {
      _capable.remove(artifact);
    }
  }

  void setRevisionAligned(TrustedArtifact artifact, bool aligned) {
    _known.add(artifact);
    if (aligned) {
      _aligned.add(artifact);
    } else {
      _aligned.remove(artifact);
    }
  }

  void pause(TrustedArtifact artifact, String reason) {
    _known.add(artifact);
    _pausedReasons[artifact] = reason;
    _aligned.remove(artifact);
  }

  void clearPause(TrustedArtifact artifact) {
    _pausedReasons.remove(artifact);
  }

  void setActivationBlocked(TrustedArtifact artifact, bool blocked) {
    _known.add(artifact);
    if (blocked) {
      _activationBlocked.add(artifact);
      _aligned.remove(artifact);
    } else {
      _activationBlocked.remove(artifact);
    }
  }

  String? errorFor(TrustedArtifact artifact) => _pausedReasons[artifact];

  bool isCapable(TrustedArtifact artifact) => _capable.contains(artifact);

  TrackingStrategy strategyFor(TrustedArtifact artifact) {
    if (!followUpdatesEnabled) return TrackingStrategy.off;
    if (_activationBlocked.contains(artifact)) {
      return TrackingStrategy.pausedCloud;
    }
    if (!cloudEnabled) {
      return TrackingStrategy.local;
    }
    if (!_aligned.contains(artifact) || _pausedReasons.containsKey(artifact)) {
      return TrackingStrategy.pausedCloud;
    }
    return _capable.contains(artifact)
        ? TrackingStrategy.cloud
        : TrackingStrategy.local;
  }

  bool isCloudPaused(TrustedArtifact artifact) =>
      strategyFor(artifact) == TrackingStrategy.pausedCloud;

  TrackingArtifactStatus statusFor(
    TrustedArtifact artifact, {
    String? revision,
  }) {
    final strategy = strategyFor(artifact);
    final reason =
        _pausedReasons[artifact] ??
        (_activationBlocked.contains(artifact)
            ? 'Runtime activation is blocked until verification succeeds.'
            : switch (strategy) {
                TrackingStrategy.off => 'Follow-up scanning is disabled.',
                TrackingStrategy.local when !cloudEnabled =>
                  'Global Cloud is disabled.',
                TrackingStrategy.local =>
                  'Artifact is Local-only and uses the pinned runtime.',
                TrackingStrategy.pausedCloud =>
                  'Waiting for Server revision alignment.',
                TrackingStrategy.cloud => 'Cloud artifact is aligned.',
              });
    return TrackingArtifactStatus(
      artifact: artifact,
      revision: revision,
      strategy: strategy,
      reason: reason,
      activationBlocked: _activationBlocked.contains(artifact),
    );
  }
}

class TrackingArtifactStatus {
  const TrackingArtifactStatus({
    required this.artifact,
    required this.revision,
    required this.strategy,
    required this.reason,
    this.activationBlocked = false,
    this.loadedRevision,
    this.relativePath,
  });

  final TrustedArtifact artifact;
  final String? revision;
  final TrackingStrategy strategy;
  final String reason;
  final bool activationBlocked;
  final String? loadedRevision;
  final String? relativePath;
}
