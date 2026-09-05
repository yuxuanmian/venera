import 'trusted_catalog.dart';

enum TrackingStrategy { off, local, cloud, pausedCloud }

class RuntimeGeneration {
  const RuntimeGeneration({
    required this.generation,
    required this.artifact,
    required this.revision,
    required this.strategy,
  });

  final int generation;
  final TrustedArtifact artifact;
  final String revision;
  final TrackingStrategy strategy;

  Map<String, dynamic> toJson() => {
    'generation': generation,
    'sourceKey': artifact.sourceKey,
    'fileName': artifact.fileName,
    'revision': revision,
    'strategy': strategy.name,
  };

  bool matches(RuntimeGeneration other) =>
      generation == other.generation &&
      artifact == other.artifact &&
      revision == other.revision &&
      strategy == other.strategy;

  @override
  bool operator ==(Object other) =>
      other is RuntimeGeneration && matches(other);

  @override
  int get hashCode => Object.hash(generation, artifact, revision, strategy);
}

class RuntimeGenerationController {
  RuntimeGenerationController({int initialGeneration = 0})
    : _generation = initialGeneration;

  int _generation;
  final _active = <TrustedArtifact, RuntimeGeneration>{};

  int get generation => _generation;

  RuntimeGeneration activate({
    required TrustedArtifact artifact,
    required String revision,
    required TrackingStrategy strategy,
  }) {
    _generation++;
    final value = RuntimeGeneration(
      generation: _generation,
      artifact: artifact,
      revision: revision,
      strategy: strategy,
    );
    _active[artifact] = value;
    return value;
  }

  /// Reuses the existing token when the actual artifact strategy and
  /// revision did not change. Periodic authority polling must not invalidate
  /// otherwise healthy Local or Cloud work.
  RuntimeGeneration activateIfChanged({
    required TrustedArtifact artifact,
    required String revision,
    required TrackingStrategy strategy,
  }) {
    final current = _active[artifact];
    if (current != null &&
        current.revision == revision &&
        current.strategy == strategy) {
      return current;
    }
    return activate(artifact: artifact, revision: revision, strategy: strategy);
  }

  RuntimeGeneration? current(TrustedArtifact artifact) => _active[artifact];

  /// Invalidates work before a source artifact is replaced or detached.
  /// Captured tokens are rejected even if the replacement later fails.
  int invalidate(TrustedArtifact artifact) {
    _generation++;
    _active.remove(artifact);
    return _generation;
  }

  /// Invalidates every captured artifact before a global runtime restart.
  int invalidateAll() {
    _generation++;
    _active.clear();
    return _generation;
  }

  RuntimeGeneration capture(TrustedArtifact artifact) {
    final value = _active[artifact];
    if (value == null) throw StateError('tracking artifact is not active');
    return value;
  }

  bool canCommit(RuntimeGeneration captured) {
    final current = _active[captured.artifact];
    return current != null && current.matches(captured);
  }
}
