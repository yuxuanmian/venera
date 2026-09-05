import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'source_revision_store.dart';
import 'source_runtime_policy.dart';
import 'trusted_catalog.dart';

typedef CatalogArtifactFetcher = Future<List<int>> Function(Uri uri);
typedef CatalogScriptValidator =
    Future<void> Function(String source, String filePath);
typedef CatalogSourceKeyResolver =
    Future<String> Function(String source, String filePath);

class StagedCatalogArtifact {
  const StagedCatalogArtifact({
    required this.artifact,
    required this.revision,
    required this.cloudCapable,
  });

  final ActiveArtifact artifact;
  final String revision;
  final bool cloudCapable;
}

class SourceRevisionManager {
  SourceRevisionManager({
    required this.store,
    this.catalog = const TrustedCatalog(),
  });

  final SourceRevisionStore store;
  final TrustedCatalog catalog;
  ActiveArtifactRegistry? _lastKnownGood;
  final _candidatePermits = <TrustedArtifact, SourceRuntimePermit>{};

  String normalizedSourceHash(List<int> bytes) => sha256
      .convert(utf8.encode(utf8.decode(bytes).replaceAll('\r\n', '\n')))
      .toString();

  Future<ActiveArtifactRegistry> current() async {
    try {
      // Resolve legacy identities lexically even when the caller has not yet
      // supplied a runtime parser.  This keeps Cloud-off startup compatible
      // with maintained class-based scripts without falling back to a
      // basename guess or executing JavaScript for discovery.
      return await store.load() ?? const ActiveArtifactRegistry();
    } catch (_) {
      if (_lastKnownGood != null) return _lastKnownGood!;
      rethrow;
    }
  }

  /// Fetches and validates every artifact before replacing the active pointer.
  /// A failed fetch, UTF-8 decode, parser validation, or pointer write leaves
  /// the last-known-good registry untouched.
  Future<ActiveArtifactRegistry> activate({
    required String revision,
    required List<TrustedArtifact> artifacts,
    required CatalogArtifactFetcher fetch,
    CatalogScriptValidator? validate,
    Iterable<TrustedArtifact>? cloudCapableArtifacts,
    FutureOr<void> Function()? beforeCommit,
  }) async {
    if (!catalog.isValidRevision(revision)) {
      throw const FormatException('revision must be an immutable full commit');
    }
    final previous = await current();
    final seen = <TrustedArtifact>{};
    final staged = <ActiveArtifact>[];
    for (final artifact in artifacts) {
      if (!seen.add(artifact)) {
        throw const FormatException('duplicate catalog artifact');
      }
      final relativePath = TrustedCatalog.safeRelativePath(
        artifact.relativePath,
      );
      if (relativePath != artifact.fileName) {
        throw const FormatException(
          'catalog artifact must use its file name path',
        );
      }
      final bytes = await fetch(catalog.artifactUri(revision, relativePath));
      final source = utf8.decode(bytes, allowMalformed: false);
      final target = store.fileForRelativePath(
        '$managedDirectoryName/$revision/${artifact.fileName}',
      );
      final hash = sha256.convert(bytes).toString();
      final candidateHash = sha256
          .convert(utf8.encode(source.replaceAll('\r\n', '\n')))
          .toString();
      SourceRuntimePermit? candidatePermit;
      if (sourceRuntimePolicy.registry != null) {
        candidatePermit = sourceRuntimePolicy.issueCandidatePermit(
          identity: artifact,
          path: target.path,
          sha256: candidateHash,
          revision: sourceRuntimePolicy.cloudEnabled ? revision : null,
        );
        _candidatePermits[artifact] = candidatePermit;
      }
      try {
        await validate?.call(source, target.path);
      } catch (_) {
        if (candidatePermit != null) {
          sourceRuntimePolicy.revoke(candidatePermit);
          _candidatePermits.remove(artifact);
        }
        rethrow;
      }
      late final ActiveArtifact materialized;
      try {
        materialized = await store.writeManagedArtifact(
          revision,
          artifact.fileName,
          bytes,
          sourceKey: artifact.sourceKey,
        );
      } catch (_) {
        if (candidatePermit != null) {
          sourceRuntimePolicy.revoke(candidatePermit);
          _candidatePermits.remove(artifact);
        }
        rethrow;
      }
      staged.add(
        ActiveArtifact(
          sourceKey: artifact.sourceKey,
          fileName: artifact.fileName,
          revision: revision,
          relativePath: materialized.relativePath,
          origin: ArtifactOrigin.managedCatalog,
          sha256: hash,
          cloudCapable: cloudCapableArtifacts?.contains(artifact) ?? false,
          activationBlocked: false,
        ),
      );
    }

    final next = <ActiveArtifact>[
      for (final item in previous.artifacts)
        if (!staged.any(
          (candidate) =>
              candidate.sourceKey == item.sourceKey &&
              candidate.fileName == item.fileName,
        ))
          item,
      ...staged,
    ];
    final registry = previous.copyWith(artifacts: next);
    try {
      await beforeCommit?.call();
      await store.save(registry);
    } catch (_) {
      for (final artifact in staged) {
        revokeCandidatePermit(artifact.identity);
      }
      rethrow;
    }
    // Keep the actual pre-activation registry for an explicit rollback. The
    // store also persists the same value as its restart-safe LKG pointer.
    _lastKnownGood = previous;
    if (!sourceRuntimePolicy.cloudEnabled) {
      for (final artifact in staged) {
        revokeCandidatePermit(artifact.identity);
      }
    }
    return registry;
  }

  /// Resolves the exact artifact from the pinned catalog index before any
  /// executable bytes are staged. The caller supplies only a file name; the
  /// catalog derives sourceKey, Cloud capability, and optional hash metadata.
  Future<ActiveArtifactRegistry> activateFromIndex({
    required String revision,
    required String fileName,
    String? expectedSourceKey,
    required CatalogArtifactFetcher fetch,
    CatalogScriptValidator? validate,
    CatalogSourceKeyResolver? resolveSourceKey,
    FutureOr<void> Function()? beforeCommit,
  }) async {
    if (!catalog.isValidRevision(revision)) {
      throw const FormatException('revision must be an immutable full commit');
    }
    if (fileName != fileName.trim() ||
        fileName.isEmpty ||
        fileName != p.basename(fileName) ||
        !fileName.endsWith('.js')) {
      throw const FormatException('catalog artifact file name is invalid');
    }
    final indexBytes = await fetch(catalog.indexUri(revision));
    final indexText = utf8.decode(indexBytes, allowMalformed: false);
    final index = catalog.parseIndex(jsonDecode(indexText));
    final entry = expectedSourceKey == null
        ? index.findByFileName(fileName)
        : index.findByArtifact(
            TrustedArtifact(sourceKey: expectedSourceKey, fileName: fileName),
          );
    if (entry == null) {
      throw const FormatException(
        'catalog artifact is not present at revision',
      );
    }
    final staged = await stageCatalogEntry(
      revision: revision,
      entry: entry,
      fetch: fetch,
      validate: validate,
      resolveSourceKey: resolveSourceKey,
    );
    return commitStaged(staged, beforeCommit: beforeCommit);
  }

  /// Fetches, hashes, parses, and materializes one trusted catalog candidate
  /// without changing the active registry pointer.  The caller may therefore
  /// perform network work before entering the App commit lock.
  Future<StagedCatalogArtifact> stageCatalogEntry({
    required String revision,
    required CatalogIndexEntry entry,
    required CatalogArtifactFetcher fetch,
    CatalogScriptValidator? validate,
    CatalogSourceKeyResolver? resolveSourceKey,
  }) async {
    if (!catalog.isValidRevision(revision)) {
      throw const FormatException('revision must be an immutable full commit');
    }
    final artifact = entry.artifact;
    final bytes = await fetch(catalog.artifactUri(revision, artifact.fileName));
    if (entry.sha256 != null &&
        sha256.convert(bytes).toString() != entry.sha256) {
      throw const FormatException('catalog artifact hash mismatch');
    }
    final source = utf8.decode(bytes, allowMalformed: false);
    final target = store.fileForRelativePath(
      '$managedDirectoryName/$revision/${artifact.fileName}',
    );
    final candidateHash = sha256
        .convert(utf8.encode(source.replaceAll('\r\n', '\n')))
        .toString();
    SourceRuntimePermit? candidatePermit;
    if (sourceRuntimePolicy.registry != null) {
      candidatePermit = sourceRuntimePolicy.issueCandidatePermit(
        identity: artifact,
        path: target.path,
        sha256: candidateHash,
        revision: sourceRuntimePolicy.cloudEnabled ? revision : null,
      );
      _candidatePermits[artifact] = candidatePermit;
    }
    try {
      if (resolveSourceKey != null) {
        final parsedSourceKey = await resolveSourceKey(source, target.path);
        if (parsedSourceKey != artifact.sourceKey) {
          throw const FormatException('catalog source key does not match');
        }
      }
      await validate?.call(source, target.path);
      final materialized = await store.writeManagedArtifact(
        revision,
        artifact.fileName,
        bytes,
        sourceKey: artifact.sourceKey,
      );
      return StagedCatalogArtifact(
        artifact: materialized,
        revision: revision,
        cloudCapable: entry.cloudCapable,
      );
    } catch (_) {
      if (candidatePermit != null) {
        sourceRuntimePolicy.revoke(candidatePermit);
        _candidatePermits.remove(artifact);
      }
      rethrow;
    }
  }

  /// Replaces only the exact selected registry entry with a previously staged
  /// candidate.  This method performs no network work and is intended to run
  /// inside the App commit lock.
  Future<ActiveArtifactRegistry> commitStaged(
    StagedCatalogArtifact staged, {
    ActiveArtifact? expectedCurrent,
    bool activationBlocked = false,
    FutureOr<void> Function()? beforeCommit,
  }) async {
    final previous = await current();
    final selected = previous.find(
      staged.artifact.sourceKey,
      staged.artifact.fileName,
    );
    if (expectedCurrent != null && selected != expectedCurrent) {
      throw StateError('active artifact selection changed');
    }
    final replacement = staged.artifact.copyWith(
      cloudCapable: staged.cloudCapable,
      activationBlocked: activationBlocked,
    );
    final next = previous.copyWith(
      artifacts: [
        for (final item in previous.artifacts)
          if (item.identity != replacement.identity) item,
        replacement,
      ],
    );
    try {
      await beforeCommit?.call();
      await store.save(next);
    } catch (_) {
      revokeCandidatePermit(replacement.identity);
      rethrow;
    }
    _lastKnownGood = previous;
    if (!sourceRuntimePolicy.cloudEnabled) {
      revokeCandidatePermit(replacement.identity);
    }
    return next;
  }

  Future<CatalogIndex> fetchIndex({
    required String revision,
    required CatalogArtifactFetcher fetch,
  }) async {
    if (!catalog.isValidRevision(revision)) {
      throw const FormatException('revision must be an immutable full commit');
    }
    final bytes = await fetch(catalog.indexUri(revision));
    final text = utf8.decode(bytes, allowMalformed: false);
    return catalog.parseIndex(jsonDecode(text));
  }

  Future<ActiveArtifactRegistry> prepareForCloudTakeover(
    TrustedArtifact artifact,
  ) async {
    final result = await store.prepareForCloudTakeover(artifact);
    _lastKnownGood = result;
    return result;
  }

  Future<ActiveArtifactRegistry> setActivationBlocked(
    TrustedArtifact artifact,
    bool blocked, {
    bool preserveLastKnownGood = false,
  }) async {
    final result = await store.setActivationBlocked(
      artifact,
      blocked,
      preserveLastKnownGood: preserveLastKnownGood,
    );
    _lastKnownGood = result;
    return result;
  }

  SourceRuntimePermit? candidatePermitFor(TrustedArtifact artifact) =>
      _candidatePermits[artifact];

  void revokeCandidatePermit(TrustedArtifact artifact) {
    final permit = _candidatePermits.remove(artifact);
    if (permit != null) sourceRuntimePolicy.revoke(permit);
  }

  /// Activates one artifact from an already pinned raw-catalog URL. The URL
  /// is checked against the trusted catalog template before the fetcher is
  /// invoked, so callers cannot accidentally materialize a branch or a
  /// different file under an immutable revision entry.
  Future<ActiveArtifactRegistry> activatePinnedArtifact({
    required Uri uri,
    required CatalogArtifactFetcher fetch,
    CatalogScriptValidator? validate,
    CatalogSourceKeyResolver? resolveSourceKey,
  }) {
    final revision = catalog.pinnedRevisionFromArtifactUri(
      uri,
      uri.pathSegments.last,
    );
    if (revision == null) {
      throw const FormatException('artifact URL is not a trusted pinned URI');
    }
    final fileName = uri.pathSegments.last;
    return activateFromIndex(
      revision: revision,
      fileName: fileName,
      fetch: (expected) {
        if (expected != uri && expected != catalog.indexUri(revision)) {
          throw const FormatException('pinned artifact URL mismatch');
        }
        return fetch(expected);
      },
      validate: validate,
      resolveSourceKey: resolveSourceKey,
    );
  }

  Future<ActiveArtifactRegistry> rollback() async {
    final previous = _lastKnownGood;
    if (previous == null) return current();
    final currentRegistry = await current();
    await store.save(previous);
    _lastKnownGood = currentRegistry;
    return previous;
  }

  /// Restores an explicitly captured registry without consulting the
  /// process-local rollback slot. This is used when an activation has already
  /// replaced the pointer but its operation epoch became stale before the new
  /// runtime was verified.
  Future<ActiveArtifactRegistry> restoreRegistry(
    ActiveArtifactRegistry registry,
  ) async {
    await store.restore(registry);
    _lastKnownGood = registry;
    return registry;
  }

  /// Restores only one exact selection after an activation failure.  The
  /// current registry is re-read while the caller holds the App commit lock;
  /// unrelated artifact commits and recovery references are therefore kept.
  /// When [activationBlocked] is true the restored bytes remain durable data,
  /// never runtime permission.
  Future<ActiveArtifactRegistry> restoreArtifactSelection({
    required TrustedArtifact identity,
    required ActiveArtifact expectedCurrent,
    required ActiveArtifact replacement,
    required bool activationBlocked,
  }) async {
    final currentRegistry = await current();
    final selected = currentRegistry.find(
      identity.sourceKey,
      identity.fileName,
    );
    if (selected == null || !_sameSelection(selected, expectedCurrent)) {
      throw const FormatException('active artifact selection changed');
    }
    final next = currentRegistry.copyWith(
      artifacts: [
        for (final item in currentRegistry.artifacts)
          if (item.identity == identity)
            replacement.copyWith(activationBlocked: activationBlocked)
          else
            item,
      ],
    );
    await store.restore(next);
    _lastKnownGood = next;
    return next;
  }

  Future<ActiveArtifactRegistry> detachForEdit(TrustedArtifact artifact) async {
    final registry = await current();
    final active = registry.find(artifact.sourceKey, artifact.fileName);
    if (active == null) throw const FormatException('artifact is not active');
    final detached = await store.detachForEdit(active, registry);
    _lastKnownGood = detached;
    return detached;
  }

  static const managedDirectoryName = '.managed';
}

bool _sameSelection(ActiveArtifact left, ActiveArtifact right) =>
    left.sourceKey == right.sourceKey &&
    left.fileName == right.fileName &&
    left.revision == right.revision &&
    left.relativePath == right.relativePath &&
    left.origin == right.origin &&
    left.sha256 == right.sha256 &&
    left.cloudCapable == right.cloudCapable;
