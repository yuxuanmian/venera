import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';

import 'cloud_tracking_coordinator.dart';
import 'legacy_source_identity.dart';
import 'source_revision_manager.dart';
import 'source_revision_store.dart';
import 'source_runtime_policy.dart';
import 'trusted_catalog.dart';

typedef SourceIdentityResolver = FutureOr<String?> Function(File file);
typedef SourceRuntimeReloader = Future<void> Function(ActiveArtifact artifact);

/// The state captured when a source editor is opened.  Opening an editor only
/// creates a draft; the selected runtime and registry remain untouched until a
/// changed buffer is explicitly committed.
class SourceEditSession {
  const SourceEditSession({
    required this.identity,
    required this.artifact,
    required this.registry,
    required this.priorBytes,
    required this.draftPath,
    required this.openedEpoch,
  });

  final TrustedArtifact identity;
  final ActiveArtifact artifact;
  final ActiveArtifactRegistry registry;
  final List<int> priorBytes;
  final String draftPath;
  final int openedEpoch;
}

/// Shared production boundary for all custom source mutations.
///
/// UI code may create a [SourceEditSession], but it cannot detach or write an
/// active artifact itself.  Every changed commit is validated against a
/// one-shot runtime permit, fenced, atomically materialized, reloaded, and
/// only then unblocked.
class SourceMutationService {
  SourceMutationService({
    required this.store,
    required this.coordinator,
    this.resolveSourceKey,
    SourceRuntimeReloader? runtimeReloader,
  }) : _runtimeReloader =
           runtimeReloader ??
           ((artifact) => ComicSourceManager().reloadUnderCommitLock(
             requiredArtifact: artifact,
           ));

  final SourceRevisionStore store;
  final CloudTrackingCoordinator coordinator;
  final SourceIdentityResolver? resolveSourceKey;
  final SourceRuntimeReloader _runtimeReloader;

  Future<void> _commitQueue = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final next = _commitQueue.then((_) => action());
    _commitQueue = next.then<void>((_) {}, onError: (_, _) {});
    return next;
  }

  Future<SourceEditSession> openEditor(TrustedArtifact identity) async {
    sourceRuntimePolicy.requireCustomMutationAllowed();
    final registry = await _loadRegistry();
    final artifact = registry.find(identity.sourceKey, identity.fileName);
    if (artifact == null) {
      throw const SourceMutationDenied('The source artifact is not installed.');
    }
    if (artifact.activationBlocked) {
      throw const SourceMutationDenied(
        'The source artifact is blocked until it is verified.',
      );
    }
    final bytes = await store.readBytes(artifact);
    final draft = await _writeDraft(artifact.fileName, bytes);
    return SourceEditSession(
      identity: identity,
      artifact: artifact,
      registry: registry,
      priorBytes: List.unmodifiable(bytes),
      draftPath: draft.path,
      openedEpoch: sourceRuntimePolicy.operationEpoch,
    );
  }

  /// Writes a buffer to the isolated draft and commits it when changed.
  /// Returns false for a no-change commit; such a path has no fence or
  /// generation side effect.
  Future<bool> commitBuffer(SourceEditSession session, String buffer) async {
    sourceRuntimePolicy.requireCustomMutationAllowed();
    await _writeDraft(
      p.basename(session.draftPath),
      utf8.encode(buffer),
      existingPath: session.draftPath,
    );
    return commitDraft(session);
  }

  Future<bool> commitDraft(SourceEditSession session) {
    return _serialized(
      () => coordinator.withCommitLock(() => _commitDraft(session)),
    ).then((committed) async {
      if (committed) await coordinator.onSettingsChanged();
      return committed;
    });
  }

  Future<ActiveArtifact> updateCustom(
    TrustedArtifact identity,
    List<int> bytes,
  ) async {
    final session = await openEditor(identity);
    await _writeDraft(
      p.basename(session.draftPath),
      bytes,
      existingPath: session.draftPath,
    );
    await commitDraft(session);
    final registry = await _loadRegistry();
    final result = registry.find(identity.sourceKey, identity.fileName);
    if (result == null) {
      throw const FormatException('custom source artifact is missing');
    }
    return result;
  }

  /// Installs a new custom source without ever writing the source root.  The
  /// no-execution identity pass supplies the exact permit identity before the
  /// validating parser is allowed to execute the candidate.
  Future<ActiveArtifact> addCustom(String js, String fileName) {
    return _serialized(
      () => coordinator.withCommitLock(() => _addCustom(js, fileName)),
    ).then((artifact) async {
      await coordinator.onSettingsChanged();
      return artifact;
    });
  }

  /// Explicitly selects one persisted custom recovery version.  Merely
  /// disabling Cloud never calls this method; the caller must pass an exact
  /// record from [ActiveArtifactRegistry.recoverableArtifacts].
  Future<ActiveArtifact> restoreCustom(ActiveArtifact recovery) {
    return _serialized(
      () => coordinator.withCommitLock(() => _restoreCustom(recovery)),
    ).then((artifact) async {
      await coordinator.onSettingsChanged();
      return artifact;
    });
  }

  Future<void> cancel(SourceEditSession session) async {
    final draft = File(session.draftPath);
    if (await draft.exists()) await draft.delete();
  }

  Future<bool> _commitDraft(SourceEditSession session) async {
    sourceRuntimePolicy.requireCustomMutationAllowed();
    final draft = File(session.draftPath);
    final changedBytes = await draft.readAsBytes();
    if (_sameBytes(session.priorBytes, changedBytes)) {
      await cancel(session);
      return false;
    }

    final currentRegistry = await _loadRegistry();
    final current = currentRegistry.find(
      session.identity.sourceKey,
      session.identity.fileName,
    );
    if (current == null || current != session.artifact) {
      throw const SourceMutationDenied(
        'The source selection changed while the editor was open.',
      );
    }
    if (sourceRuntimePolicy.operationEpoch != session.openedEpoch) {
      throw const SourceMutationDenied(
        'The source mode changed while the editor was open.',
      );
    }

    // Validate the changed buffer before touching the active pointer.  The
    // permit is path/hash/identity/epoch bound and cannot grant scan writes.
    final normalizedDraft = utf8
        .decode(changedBytes, allowMalformed: false)
        .replaceAll('\r\n', '\n');
    final draftHash = sha256.convert(utf8.encode(normalizedDraft)).toString();
    final validationPermit = _issuePermit(
      identity: session.identity,
      path: draft.path,
      sha256: draftHash,
    );
    try {
      final parsed = await ComicSourceParser().parse(
        utf8.decode(changedBytes, allowMalformed: false),
        draft.path,
        register: false,
        allowExistingKey: true,
        loadData: false,
        scheduleInit: false,
        runtimePermit: validationPermit,
      );
      if (parsed.key != session.identity.sourceKey) {
        throw const FormatException('comic source key does not match');
      }
    } finally {
      if (validationPermit != null) {
        sourceRuntimePolicy.revoke(validationPermit);
      }
    }

    // The fence is immediately before the first active mutation.  Re-check
    // the mode and exact selection after every awaited validation boundary.
    sourceRuntimePolicy.requireCustomMutationAllowed();
    if (sourceRuntimePolicy.operationEpoch != session.openedEpoch) {
      throw const SourceMutationDenied(
        'The source mode changed before the edit could be committed.',
      );
    }
    coordinator.beforeArtifactChange(session.identity);
    final mutationEpoch = sourceRuntimePolicy.operationEpoch;
    var pointerCommitted = false;
    ActiveArtifact? replacement;
    SourceRuntimePermit? reloadPermit;
    try {
      final afterFence = await _loadRegistry();
      if (sourceRuntimePolicy.operationEpoch != mutationEpoch ||
          !sourceRuntimePolicy.customMutationAllowed) {
        throw const SourceMutationDenied(
          'The source mode changed before the edit was fenced.',
        );
      }
      final selected = afterFence.find(
        session.identity.sourceKey,
        session.identity.fileName,
      );
      if (selected == null || selected != session.artifact) {
        throw const SourceMutationDenied(
          'The source selection changed before the edit was committed.',
        );
      }

      final working = await store.writeCustomWorkingCopy(
        selected,
        changedBytes,
      );
      if (sourceRuntimePolicy.operationEpoch != mutationEpoch ||
          !sourceRuntimePolicy.customMutationAllowed) {
        throw const SourceMutationDenied(
          'The source mode changed while the edit was being written.',
        );
      }
      replacement = working.copyWith(activationBlocked: true);
      final next = _replaceArtifact(afterFence, selected, replacement);
      await store.save(next);
      if (sourceRuntimePolicy.operationEpoch != mutationEpoch ||
          !sourceRuntimePolicy.customMutationAllowed) {
        throw const SourceMutationDenied(
          'The source mode changed after the edit pointer was saved.',
        );
      }
      pointerCommitted = true;
      sourceRuntimePolicy.updateRegistry(next, authorityRevision: null);

      reloadPermit = _issuePermit(
        identity: session.identity,
        path: store.fileForRelativePath(replacement.relativePath).path,
        sha256: draftHash,
      );
      await _runtimeReloader(replacement);
      if (sourceRuntimePolicy.operationEpoch != mutationEpoch ||
          !sourceRuntimePolicy.customMutationAllowed) {
        throw const SourceMutationDenied(
          'The source mode changed while the edited runtime was reloading.',
        );
      }

      final verified = await SourceRevisionManager(
        store: store,
      ).setActivationBlocked(session.identity, false);
      sourceRuntimePolicy.updateRegistry(verified, authorityRevision: null);
      if (sourceRuntimePolicy.operationEpoch != mutationEpoch ||
          !sourceRuntimePolicy.customMutationAllowed) {
        throw const SourceMutationDenied(
          'The source mode changed before the edited runtime was published.',
        );
      }
      final published = verified.find(
        session.identity.sourceKey,
        session.identity.fileName,
      );
      if (published == null) {
        throw const FormatException('edited source artifact is missing');
      }
      sourceRuntimePolicy.promoteRuntime(published.identity);
      coordinator.publishLocalGeneration(published);
      if (reloadPermit != null) sourceRuntimePolicy.revoke(reloadPermit);
      await cancel(session);
      return true;
    } catch (error, stack) {
      if (reloadPermit != null) sourceRuntimePolicy.revoke(reloadPermit);
      await _recoverAfterFailure(
        session,
        currentRegistry: currentRegistry,
        committedArtifact: replacement,
        pointerCommitted: pointerCommitted,
        error: error,
        stack: stack,
      );
      rethrow;
    }
  }

  Future<ActiveArtifact> _addCustom(String js, String fileName) async {
    sourceRuntimePolicy.requireCustomMutationAllowed();
    final safeName = p.basename(
      fileName.endsWith('.js') ? fileName : '$fileName.js',
    );
    if (safeName != fileName && fileName != p.basename(fileName)) {
      throw const FormatException('custom source file name is invalid');
    }
    if (!safeName.endsWith('.js') || safeName == '.js') {
      throw const FormatException('custom source file name is invalid');
    }
    final bytes = utf8.encode(js);
    final legacyIdentity = LegacySourceIdentity.fromBytes(bytes);
    final identity = TrustedArtifact(
      sourceKey: legacyIdentity.sourceKey,
      fileName: safeName,
    );
    final registry = await _loadRegistry();
    if (registry.find(identity.sourceKey, safeName) != null) {
      throw const FormatException('comic source artifact already exists');
    }
    final validationEpoch = sourceRuntimePolicy.operationEpoch;
    final draft = await _writeDraft(safeName, bytes);
    final normalized = js.replaceAll('\r\n', '\n');
    final candidateHash = sha256.convert(utf8.encode(normalized)).toString();
    final validationPermit = _issuePermit(
      identity: identity,
      path: draft.path,
      sha256: candidateHash,
    );
    try {
      final parsed = await ComicSourceParser().parse(
        normalized,
        draft.path,
        register: false,
        allowExistingKey: true,
        loadData: false,
        scheduleInit: false,
        runtimePermit: validationPermit,
      );
      if (parsed.key != identity.sourceKey) {
        throw const FormatException('comic source key does not match');
      }
    } finally {
      if (validationPermit != null) {
        sourceRuntimePolicy.revoke(validationPermit);
      }
    }

    sourceRuntimePolicy.requireCustomMutationAllowed();
    if (sourceRuntimePolicy.operationEpoch != validationEpoch) {
      throw const SourceMutationDenied(
        'The source mode changed while the custom source was validated.',
      );
    }
    coordinator.beforeArtifactsChange();
    final mutationEpoch = sourceRuntimePolicy.operationEpoch;
    var pointerCommitted = false;
    SourceRuntimePermit? reloadPermit;
    try {
      final afterFence = await _loadRegistry();
      if (sourceRuntimePolicy.operationEpoch != mutationEpoch ||
          !sourceRuntimePolicy.customMutationAllowed) {
        throw const SourceMutationDenied(
          'The source mode changed before the custom source was fenced.',
        );
      }
      if (afterFence.find(identity.sourceKey, safeName) != null) {
        throw const FormatException('comic source artifact already exists');
      }
      final seed = ActiveArtifact(
        sourceKey: identity.sourceKey,
        fileName: safeName,
        revision: null,
        relativePath: safeName,
        origin: ArtifactOrigin.custom,
        sha256: sha256.convert(bytes).toString(),
      );
      final working = await store.writeCustomWorkingCopy(seed, bytes);
      if (sourceRuntimePolicy.operationEpoch != mutationEpoch ||
          !sourceRuntimePolicy.customMutationAllowed) {
        throw const SourceMutationDenied(
          'The source mode changed while the custom source was being written.',
        );
      }
      final replacement = working.copyWith(activationBlocked: true);
      final next = afterFence.copyWith(
        artifacts: [...afterFence.artifacts, replacement],
      );
      await store.save(next);
      if (sourceRuntimePolicy.operationEpoch != mutationEpoch ||
          !sourceRuntimePolicy.customMutationAllowed) {
        throw const SourceMutationDenied(
          'The source mode changed after the custom source pointer was saved.',
        );
      }
      pointerCommitted = true;
      sourceRuntimePolicy.updateRegistry(next, authorityRevision: null);
      reloadPermit = _issuePermit(
        identity: identity,
        path: store.fileForRelativePath(replacement.relativePath).path,
        sha256: candidateHash,
      );
      await _runtimeReloader(replacement);
      if (sourceRuntimePolicy.operationEpoch != mutationEpoch ||
          !sourceRuntimePolicy.customMutationAllowed) {
        throw const SourceMutationDenied(
          'The source mode changed while the custom source was reloading.',
        );
      }
      final verified = await SourceRevisionManager(
        store: store,
      ).setActivationBlocked(identity, false);
      sourceRuntimePolicy.updateRegistry(verified, authorityRevision: null);
      if (sourceRuntimePolicy.operationEpoch != mutationEpoch ||
          !sourceRuntimePolicy.customMutationAllowed) {
        throw const SourceMutationDenied(
          'The source mode changed before the custom source was published.',
        );
      }
      final published = verified.find(identity.sourceKey, safeName);
      if (published == null) {
        throw const FormatException(
          'installed comic source artifact is missing',
        );
      }
      sourceRuntimePolicy.promoteRuntime(published.identity);
      coordinator.publishLocalGeneration(published);
      if (reloadPermit != null) sourceRuntimePolicy.revoke(reloadPermit);
      await cancel(
        SourceEditSession(
          identity: identity,
          artifact: seed,
          registry: registry,
          priorBytes: const [],
          draftPath: draft.path,
          openedEpoch: sourceRuntimePolicy.operationEpoch,
        ),
      );
      return verified.find(identity.sourceKey, safeName)!;
    } catch (error, stack) {
      if (reloadPermit != null) sourceRuntimePolicy.revoke(reloadPermit);
      if (pointerCommitted) {
        try {
          final restored = await SourceRevisionManager(
            store: store,
          ).restoreRegistry(registry);
          sourceRuntimePolicy.updateRegistry(restored, authorityRevision: null);
          if (!sourceRuntimePolicy.cloudEnabled) {
            final previous = restored.find(identity.sourceKey, safeName);
            if (previous != null && !previous.activationBlocked) {
              await _runtimeReloader(previous);
            }
          }
        } catch (restoreError, restoreStack) {
          try {
            final blocked = await SourceRevisionManager(
              store: store,
            ).setActivationBlocked(identity, true, preserveLastKnownGood: true);
            sourceRuntimePolicy.updateRegistry(
              blocked,
              authorityRevision: null,
            );
          } catch (blockError, blockStack) {
            sourceRuntimePolicy.admissionReady = false;
            sourceRuntimePolicy.registry = null;
            Log.error(
              'Block custom source after install failure',
              blockError,
              blockStack,
            );
          }
          Log.error(
            'Restore custom source after install failure',
            restoreError,
            restoreStack,
          );
        }
      }
      Log.error('Custom source install failed', error, stack);
      rethrow;
    }
  }

  Future<ActiveArtifact> _restoreCustom(ActiveArtifact recovery) async {
    sourceRuntimePolicy.requireCustomMutationAllowed();
    final registry = await _loadRegistry();
    if (!registry.recoverableArtifacts.any((item) => item == recovery)) {
      throw const FormatException('custom recovery version is not registered');
    }
    final validationEpoch = sourceRuntimePolicy.operationEpoch;
    final bytes = await store.readBytes(recovery);
    final normalized = utf8
        .decode(bytes, allowMalformed: false)
        .replaceAll('\r\n', '\n');
    final candidateHash = sha256.convert(utf8.encode(normalized)).toString();
    final validationPermit = _issuePermit(
      identity: recovery.identity,
      path: store.fileForRelativePath(recovery.relativePath).path,
      sha256: candidateHash,
    );
    try {
      final parsed = await ComicSourceParser().parse(
        normalized,
        store.fileForRelativePath(recovery.relativePath).path,
        register: false,
        allowExistingKey: true,
        loadData: false,
        scheduleInit: false,
        runtimePermit: validationPermit,
      );
      if (parsed.key != recovery.sourceKey) {
        throw const FormatException('comic source key does not match');
      }
    } finally {
      if (validationPermit != null) {
        sourceRuntimePolicy.revoke(validationPermit);
      }
    }
    sourceRuntimePolicy.requireCustomMutationAllowed();
    if (sourceRuntimePolicy.operationEpoch != validationEpoch) {
      throw const SourceMutationDenied(
        'The source mode changed while the recovery version was validated.',
      );
    }
    coordinator.beforeArtifactChange(recovery.identity);
    final mutationEpoch = sourceRuntimePolicy.operationEpoch;
    var pointerCommitted = false;
    SourceRuntimePermit? reloadPermit;
    try {
      final afterFence = await _loadRegistry();
      if (sourceRuntimePolicy.operationEpoch != mutationEpoch ||
          !sourceRuntimePolicy.customMutationAllowed) {
        throw const SourceMutationDenied(
          'The source mode changed before recovery was fenced.',
        );
      }
      final current = afterFence.find(recovery.sourceKey, recovery.fileName);
      if (current == null) {
        throw const FormatException('source artifact is not active');
      }
      final working = await store.writeCustomWorkingCopy(current, bytes);
      if (sourceRuntimePolicy.operationEpoch != mutationEpoch ||
          !sourceRuntimePolicy.customMutationAllowed) {
        throw const SourceMutationDenied(
          'The source mode changed while recovery was being written.',
        );
      }
      final replacement = working.copyWith(activationBlocked: true);
      final next = _replaceArtifact(afterFence, current, replacement);
      await store.save(next);
      if (sourceRuntimePolicy.operationEpoch != mutationEpoch ||
          !sourceRuntimePolicy.customMutationAllowed) {
        throw const SourceMutationDenied(
          'The source mode changed after recovery was selected.',
        );
      }
      pointerCommitted = true;
      sourceRuntimePolicy.updateRegistry(next, authorityRevision: null);
      reloadPermit = _issuePermit(
        identity: recovery.identity,
        path: store.fileForRelativePath(replacement.relativePath).path,
        sha256: candidateHash,
      );
      await _runtimeReloader(replacement);
      if (sourceRuntimePolicy.operationEpoch != mutationEpoch ||
          !sourceRuntimePolicy.customMutationAllowed) {
        throw const SourceMutationDenied(
          'The source mode changed while recovery was reloading.',
        );
      }
      final verified = await SourceRevisionManager(
        store: store,
      ).setActivationBlocked(recovery.identity, false);
      sourceRuntimePolicy.updateRegistry(verified, authorityRevision: null);
      if (sourceRuntimePolicy.operationEpoch != mutationEpoch ||
          !sourceRuntimePolicy.customMutationAllowed) {
        throw const SourceMutationDenied(
          'The source mode changed before recovery was published.',
        );
      }
      final published = verified.find(recovery.sourceKey, recovery.fileName);
      if (published == null) {
        throw const FormatException('recovered source artifact is missing');
      }
      sourceRuntimePolicy.promoteRuntime(published.identity);
      coordinator.publishLocalGeneration(published);
      if (reloadPermit != null) sourceRuntimePolicy.revoke(reloadPermit);
      return verified.find(recovery.sourceKey, recovery.fileName)!;
    } catch (error, stack) {
      if (reloadPermit != null) sourceRuntimePolicy.revoke(reloadPermit);
      if (pointerCommitted) {
        try {
          final restored = await SourceRevisionManager(
            store: store,
          ).restoreRegistry(registry);
          sourceRuntimePolicy.updateRegistry(restored, authorityRevision: null);
          if (!sourceRuntimePolicy.cloudEnabled) {
            final previous = restored.find(
              recovery.sourceKey,
              recovery.fileName,
            );
            if (previous != null && !previous.activationBlocked) {
              await _runtimeReloader(previous);
            }
          }
        } catch (restoreError, restoreStack) {
          try {
            final blocked = await SourceRevisionManager(store: store)
                .setActivationBlocked(
                  recovery.identity,
                  true,
                  preserveLastKnownGood: true,
                );
            sourceRuntimePolicy.updateRegistry(
              blocked,
              authorityRevision: null,
            );
          } catch (blockError, blockStack) {
            sourceRuntimePolicy.admissionReady = false;
            sourceRuntimePolicy.registry = null;
            Log.error(
              'Block custom recovery after failure',
              blockError,
              blockStack,
            );
          }
          Log.error(
            'Restore custom recovery after failure',
            restoreError,
            restoreStack,
          );
        }
      }
      Log.error('Custom recovery failed', error, stack);
      rethrow;
    }
  }

  Future<ActiveArtifactRegistry> _loadRegistry() async =>
      await store.load() ?? const ActiveArtifactRegistry();

  SourceRuntimePermit? _issuePermit({
    required TrustedArtifact identity,
    required String path,
    required String sha256,
  }) {
    if (sourceRuntimePolicy.registry == null) return null;
    return sourceRuntimePolicy.issueCandidatePermit(
      identity: identity,
      path: path,
      sha256: sha256,
      revision: null,
    );
  }

  Future<File> _writeDraft(
    String fileName,
    List<int> bytes, {
    String? existingPath,
  }) async {
    final target = existingPath == null
        ? await _newDraft(fileName)
        : File(existingPath);
    await target.parent.create(recursive: true);
    if (existingPath != null) {
      await target.writeAsBytes(bytes, flush: true);
      return target;
    }
    final temp = File(
      '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temp.writeAsBytes(bytes, flush: true);
    try {
      await temp.rename(target.path);
    } catch (_) {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
    return target;
  }

  Future<File> _newDraft(String fileName) async {
    final directory = Directory(
      p.join(store.sourceDirectory.path, '.custom-drafts'),
    );
    await directory.create(recursive: true);
    final safeName = p.basename(fileName);
    var target = File(
      p.join(
        directory.path,
        '${DateTime.now().microsecondsSinceEpoch}-$safeName',
      ),
    );
    while (await target.exists()) {
      target = File(
        p.join(
          directory.path,
          '${DateTime.now().microsecondsSinceEpoch + 1}-$safeName',
        ),
      );
    }
    return target;
  }

  Future<void> _recoverAfterFailure(
    SourceEditSession session, {
    required ActiveArtifactRegistry currentRegistry,
    required ActiveArtifact? committedArtifact,
    required bool pointerCommitted,
    required Object error,
    required StackTrace stack,
  }) async {
    if (!pointerCommitted) return;
    final manager = SourceRevisionManager(store: store);
    try {
      final latest = await manager.current();
      final latestArtifact = latest.find(
        session.identity.sourceKey,
        session.identity.fileName,
      );
      final originalArtifact = currentRegistry.find(
        session.identity.sourceKey,
        session.identity.fileName,
      );
      if (latestArtifact == null ||
          originalArtifact == null ||
          (!_sameSelection(latestArtifact, originalArtifact) &&
              (committedArtifact == null ||
                  !_sameSelection(latestArtifact, committedArtifact)))) {
        Log.warning(
          'Restore source after edit failure',
          'A newer exact source selection won; leaving it for reconciliation.',
        );
        return;
      }
      final restored = await manager.restoreRegistry(currentRegistry);
      sourceRuntimePolicy.updateRegistry(restored, authorityRevision: null);
      final restoredArtifact = restored.find(
        session.identity.sourceKey,
        session.identity.fileName,
      );
      if (restoredArtifact == null) {
        throw StateError('restored source artifact is missing');
      }
      if (!sourceRuntimePolicy.cloudEnabled &&
          !restoredArtifact.activationBlocked) {
        await _runtimeReloader(restoredArtifact);
      }
    } catch (restoreError, restoreStack) {
      try {
        final blocked = await manager.setActivationBlocked(
          session.identity,
          true,
          preserveLastKnownGood: true,
        );
        sourceRuntimePolicy.updateRegistry(blocked, authorityRevision: null);
      } catch (blockError, blockStack) {
        sourceRuntimePolicy.admissionReady = false;
        sourceRuntimePolicy.registry = null;
        // Keep the failure fail-closed even when neither pointer recovery nor
        // the blocking registry write is available.
        Log.error(
          'Block source after edit recovery failure',
          blockError,
          blockStack,
        );
      }
      Log.error(
        'Restore source after edit failure',
        restoreError,
        restoreStack,
      );
    }
    Log.error('Custom source edit failed', error, stack);
  }

  static ActiveArtifactRegistry _replaceArtifact(
    ActiveArtifactRegistry registry,
    ActiveArtifact previous,
    ActiveArtifact replacement,
  ) {
    return registry.copyWith(
      recoverableArtifacts: [
        ...registry.recoverableArtifacts,
        if (previous.origin == ArtifactOrigin.custom &&
            !registry.recoverableArtifacts.contains(previous))
          previous,
      ],
      artifacts: [
        for (final item in registry.artifacts)
          if (item.identity == previous.identity) replacement else item,
      ],
    );
  }

  static bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  static bool _sameSelection(ActiveArtifact left, ActiveArtifact right) =>
      left.sourceKey == right.sourceKey &&
      left.fileName == right.fileName &&
      left.revision == right.revision &&
      left.relativePath == right.relativePath &&
      left.origin == right.origin &&
      left.sha256 == right.sha256 &&
      left.cloudCapable == right.cloudCapable;
}
