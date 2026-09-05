import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';

import 'cloud_interest_sync.dart';
import 'cloud_observation_service.dart';
import 'cloud_tracking_client.dart';
import 'diagnostics.dart';
import 'apply_service.dart';
import 'mode_controller.dart';
import 'runtime_generation.dart';
import 'source_revision_manager.dart';
import 'source_revision_store.dart';
import 'source_import_transaction.dart';
import 'source_runtime_policy.dart';
import 'trusted_catalog.dart';

typedef CloudTrackingClientFactory =
    CloudTrackingClient Function(Uri server, String accessToken);
typedef CloudTrackingRuntimeReloader =
    Future<void> Function(ActiveArtifact artifact);

/// The one App-owned coordinator for Cloud tracking.
///
/// It is deliberately composed around the same favorite cache used by Local
/// follow-up scans. The coordinator owns authority refresh, exact interest
/// replacement, revision alignment, Cloud polling, and the runtime generation
/// fence; it never compares observations itself.
class CloudTrackingCoordinator extends ChangeNotifier {
  CloudTrackingCoordinator({
    required this.favorites,
    required this.sourceDirectory,
    this.catalog = const TrustedCatalog(),
    SourceRevisionManager? revisions,
    CloudTrackingClientFactory? clientFactory,
    CatalogArtifactFetcher? artifactFetcher,
    this.pollInterval = const Duration(minutes: 10),
    RuntimeGenerationController? generations,
    TrackingDiagnostics? diagnostics,
    CloudTrackingRuntimeReloader? runtimeReloader,
    CatalogSourceKeyResolver? sourceKeyResolver,
    TrackingApplyStore? applyStore,
    Future<void> Function()? persistSettings,
  }) : generations = generations ?? RuntimeGenerationController(),
       diagnostics = diagnostics ?? trackingDiagnostics,
       revisions =
           revisions ??
           SourceRevisionManager(
             store: SourceRevisionStore(sourceDirectory),
             catalog: catalog,
           ),
       _clientFactory = clientFactory,
       _artifactFetcher = artifactFetcher,
       _runtimeReloader = runtimeReloader,
       _sourceKeyResolver = sourceKeyResolver,
       _applyStore = applyStore,
       _persistSettings = persistSettings ?? (() => appdata.saveData());

  final NetworkFavoriteCacheManager favorites;
  final Directory sourceDirectory;
  final TrustedCatalog catalog;
  final Duration pollInterval;
  final RuntimeGenerationController generations;
  final TrackingDiagnostics diagnostics;
  final SourceRevisionManager revisions;
  final CloudTrackingClientFactory? _clientFactory;
  final CatalogArtifactFetcher? _artifactFetcher;
  final CloudTrackingRuntimeReloader? _runtimeReloader;
  final CatalogSourceKeyResolver? _sourceKeyResolver;
  final TrackingApplyStore? _applyStore;
  final Future<void> Function() _persistSettings;

  final TrackingModeController modes = TrackingModeController();
  final CloudInterestSync interestSync = const CloudInterestSync();

  CloudTrackingClient? _client;
  TrustedAuthority? _authority;
  ActiveArtifactRegistry? _registry;
  Timer? _pollTimer;
  Timer? _interestTimer;
  Future<void>? _refreshFuture;
  Future<void>? _clientStateQueue;
  Future<void> _commitLock = Future<void>.value();
  int _operationEpoch = 0;
  bool _started = false;
  bool _disposed = false;
  final _admissionNeedsLocalReload = <TrustedArtifact>{};
  bool _suppressFavoriteChange = false;
  String? _lastError;
  final _blockedFromLocal = <TrustedArtifact>{};

  bool get started => _started;
  TrustedAuthority? get authority => _authority;
  ActiveArtifactRegistry? get registry => _registry;
  String? get lastError => _lastError;
  int get operationEpoch => _operationEpoch;
  bool get pendingCloudEnable => sourceRuntimePolicy.pendingCloudEnable;
  bool get customizationAllowed => sourceRuntimePolicy.customMutationAllowed;

  /// Publishes the already verified Local runtime without awaiting another
  /// coordinator turn.  Mutation services call this only after their final
  /// epoch/selection check, so no asynchronous work can interleave the check
  /// and the generation publication.
  void publishLocalGeneration(ActiveArtifact artifact) {
    modes.cloudEnabled = false;
    modes.followUpdatesEnabled = followUpdatesEnabledValue;
    modes.setCapability(artifact.identity, false);
    modes.setRevisionAligned(artifact.identity, false);
    modes.setActivationBlocked(artifact.identity, false);
    modes.clearPause(artifact.identity);
    generations.activateIfChanged(
      artifact: artifact.identity,
      revision: artifact.revision ?? 'local',
      strategy: followUpdatesEnabledValue
          ? TrackingStrategy.local
          : TrackingStrategy.off,
    );
  }

  /// Serializes App-side pointer/runtime commits without holding the lock
  /// while a caller performs network work.  Mode requests still advance the
  /// epoch outside this queue, so a waiting transaction can become stale.
  Future<T> withCommitLock<T>(Future<T> Function() action) {
    final next = _commitLock.then((_) => action());
    _commitLock = next.then<void>((_) {}, onError: (_, _) {});
    return next;
  }

  /// Begins a source-directory or pointer transaction after the caller has
  /// acquired the shared commit lock. Mode invalidation itself remains
  /// synchronous and therefore happens before any asynchronous transaction.
  int beginArtifactCommit() {
    beforeArtifactsChange();
    return _operationEpoch;
  }

  final _selectionOwners = <TrustedArtifact, int>{};
  final _takeoverPrior = <TrustedArtifact, ActiveArtifact>{};

  void requireCurrentCommit(int epoch, {bool? expectedCloud}) {
    _ensureCurrentEpoch(epoch);
    if (expectedCloud != null && cloudEnabled != expectedCloud) {
      throw const _StaleCloudRefresh();
    }
  }

  /// Managed installs and explicit updates use the same transaction as Cloud
  /// alignment. Fetch/validation stays outside the lock; pointer, real reload,
  /// handoff and recovery are owned by one exact operation.
  Future<void> activateManagedSource({
    required TrustedArtifact identity,
    required String revision,
    required CatalogArtifactFetcher fetch,
  }) async {
    final requestedEpoch = _operationEpoch;
    final previous = await revisions.current();
    _ensureCurrentEpoch(requestedEpoch);
    if (cloudEnabled && _authority?.activeRevision != revision) {
      throw const SourceRuntimeDenied(
        'Managed installation requires current Cloud authority.',
      );
    }
    final index = await revisions.fetchIndex(revision: revision, fetch: fetch);
    _ensureCurrentEpoch(requestedEpoch);
    final entry = index.findByArtifact(identity);
    if (entry == null) {
      throw const FormatException(
        'Exact artifact is absent from the trusted catalog.',
      );
    }
    final staged = await revisions.stageCatalogEntry(
      revision: revision,
      entry: entry,
      fetch: fetch,
      resolveSourceKey: _resolveSourceKey,
    );
    int? mutationEpoch;
    SourceRuntimePermit? permit;
    try {
      await withCommitLock(() async {
        _ensureCurrentEpoch(requestedEpoch);
        final current = await revisions.current();
        _ensureCurrentEpoch(requestedEpoch);
        final selected = current.find(identity.sourceKey, identity.fileName);
        if (selected != previous.find(identity.sourceKey, identity.fileName)) {
          throw const SourceRuntimeDenied(
            'Source selection changed during download.',
          );
        }
        beforeArtifactChange(identity);
        final epoch = mutationEpoch = _operationEpoch;
        _selectionOwners[identity] = epoch;
        final updated = await revisions.commitStaged(
          staged,
          expectedCurrent: selected,
          activationBlocked: true,
          beforeCommit: () => _ensureCurrentEpoch(epoch),
        );
        _ensureCurrentEpoch(epoch);
        final artifact = updated.find(identity.sourceKey, identity.fileName)!;
        _registry = updated;
        sourceRuntimePolicy.updateRegistry(
          updated,
          authorityRevision: _authority?.activeRevision,
        );
        final bytes = await revisions.store.readBytes(artifact);
        _ensureCurrentEpoch(epoch);
        permit = sourceRuntimePolicy.issueCandidatePermit(
          identity: identity,
          path: revisions.store.fileForRelativePath(artifact.relativePath).path,
          sha256: revisions.normalizedSourceHash(bytes),
          revision: artifact.revision,
        );
        await _reloadRuntime(artifact);
        _ensureCurrentEpoch(epoch);
        final verified = await revisions.setActivationBlocked(identity, false);
        _ensureCurrentEpoch(epoch);
        _registry = verified;
        sourceRuntimePolicy.updateRegistry(
          verified,
          authorityRevision: _authority?.activeRevision,
        );
        sourceRuntimePolicy.promoteRuntime(identity);
        sourceRuntimePolicy.revoke(permit!);
        if (!cloudEnabled) {
          publishLocalGeneration(
            verified.find(identity.sourceKey, identity.fileName)!,
          );
        }
      });
    } catch (_) {
      if (mutationEpoch != null) {
        await _restoreAfterActivation(
          previous,
          identity,
          staged.artifact.copyWith(cloudCapable: staged.cloudCapable),
          mutationEpoch!,
        );
      }
      rethrow;
    } finally {
      if (permit != null) sourceRuntimePolicy.revoke(permit!);
      revisions.revokeCandidatePermit(identity);
    }
    await refreshNow();
  }

  /// Loads the registry without executing a source.  Production startup calls
  /// this after appdata and the JS engine are ready but before
  /// ComicSourceManager; persisted Cloud ownership therefore blocks old/root
  /// scripts before the first parse/init.
  Future<void> prepareRuntimeAdmission() async {
    if (_disposed) return;
    final cloud = cloudEnabled;
    final admissionEpoch = _operationEpoch;
    final store = SourceRevisionStore(sourceDirectory);
    ActiveArtifactRegistry registry;
    try {
      registry = await withCommitLock(() async {
        _ensureCurrentEpoch(admissionEpoch);
        await SourceImportTransaction(sourceDirectory).recover();
        _ensureCurrentEpoch(admissionEpoch);
        final discovered = await store.loadOrMigrate(
          // The no-execution lexical identity path is used in both modes during
          // the pre-JS admission phase.  Cloud-off still permits a later Local
          // parser fallback for files whose identity cannot be proven here.
          cloudEnabled: true,
        );
        _ensureCurrentEpoch(admissionEpoch);
        return discovered;
      });
    } catch (error, stack) {
      if (admissionEpoch != _operationEpoch) return;
      _lastError = 'Source registry admission failed: $error';
      Log.error('Prepare source runtime admission', error, stack);
      denySourceRuntimes();
      return;
    }
    if (cloud) {
      for (final identity in registry.artifacts.map((item) => item.identity)) {
        final active = registry.find(identity.sourceKey, identity.fileName);
        if (active == null || active.activationBlocked) continue;
        final previous = active;
        try {
          registry = await withCommitLock(() async {
            requireCurrentCommit(admissionEpoch, expectedCloud: true);
            final current = await revisions.current();
            final selected = current.find(
              identity.sourceKey,
              identity.fileName,
            );
            if (selected == null || !_sameSelectedRuntime(selected, previous)) {
              throw const _StaleCloudRefresh();
            }
            _selectionOwners[identity] = admissionEpoch;
            _takeoverPrior[identity] = previous;
            final prepared = await revisions.prepareForCloudTakeover(identity);
            requireCurrentCommit(admissionEpoch, expectedCloud: true);
            return prepared;
          });
        } catch (error, stack) {
          if (error is _StaleCloudRefresh) {
            break;
          }
          Log.error('Prepare source artifact for Cloud takeover', error, stack);
          registry = await revisions.current();
        }
      }
    }
    if (admissionEpoch != _operationEpoch) return;
    final currentCloud = cloudEnabled;
    _registry = registry;
    sourceRuntimePolicy.prepare(
      cloudEnabled: currentCloud,
      registry: registry,
      sourceDirectoryPath: sourceDirectory.path,
      operationEpoch: _operationEpoch,
    );
    if (currentCloud) {
      sourceRuntimePolicy.requestMode(
        cloudEnabled: true,
        operationEpoch: _operationEpoch,
      );
      generations.invalidateAll();
      _blockedFromLocal
        ..clear()
        ..addAll(registry.artifacts.map((item) => item.identity));
    }
  }

  /// Invalidates a source before a managed artifact is replaced or detached.
  /// Callers that edit/activate source files use this same controller as the
  /// Cloud and Local workers, so a late result cannot commit into the new
  /// artifact generation.
  void beforeArtifactChange(TrustedArtifact artifact) {
    _operationEpoch++;
    generations.invalidate(artifact);
    _blockedFromLocal.add(artifact);
    sourceRuntimePolicy.operationEpoch = _operationEpoch;
    sourceRuntimePolicy.revokeAll();
  }

  /// Invalidates all in-flight source work when a caller is about to add a
  /// catalog artifact whose exact sourceKey is only known after index parsing.
  int beforeArtifactsChange() {
    _operationEpoch++;
    generations.invalidateAll();
    _blockedFromLocal.clear();
    sourceRuntimePolicy.operationEpoch = _operationEpoch;
    sourceRuntimePolicy.revokeAll();
    return _operationEpoch;
  }

  bool get cloudEnabled => appdata.settings['cloudTrackingEnabled'] == true;

  bool get serverConfigured {
    final raw = appdata.settings['cloudTrackingServerUrl'];
    final uri = raw is String ? Uri.tryParse(raw.trim()) : null;
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  Future<void> start() async {
    if (_disposed || _started) return;
    if (sourceRuntimePolicy.registry == null) {
      await prepareRuntimeAdmission();
    }
    _started = true;
    favorites.addListener(_onFavoritesChanged);
    if (_admissionNeedsLocalReload.isNotEmpty) {
      final reloadIdentities = Set<TrustedArtifact>.from(
        _admissionNeedsLocalReload,
      );
      _admissionNeedsLocalReload.clear();
      final current = _registry ?? await revisions.current();
      final reloader = _runtimeReloader;
      if (reloader != null) {
        for (final active in current.artifacts) {
          if (!active.activationBlocked &&
              reloadIdentities.contains(active.identity)) {
            await reloader(active);
          }
        }
      } else {
        await withCommitLock(
          () => ComicSourceManager().reloadUnderCommitLock(),
        );
      }
    }
    await refreshNow();
    _pollTimer = Timer.periodic(pollInterval, (_) => unawaited(refreshNow()));
  }

  /// Re-runs the complete authority/alignment/state flow after a settings
  /// change. A change invalidates every pending source operation first.
  Future<void> onSettingsChanged() async {
    if (_disposed) return;
    _operationEpoch++;
    generations.invalidateAll();
    sourceRuntimePolicy.requestMode(
      cloudEnabled: cloudEnabled,
      operationEpoch: _operationEpoch,
    );
    sourceRuntimePolicy.updateRegistry(
      _registry ?? const ActiveArtifactRegistry(),
    );
    _client = null;
    await refreshNow();
  }

  /// Persists the one global Cloud preference only after synchronously fencing
  /// the old mode.  The setting UI uses this method so a failed persistence
  /// does not report that the requested mode was applied.
  Future<void> setCloudEnabled(bool enabled) async {
    if (_disposed) return;
    final previous = appdata.settings['cloudTrackingEnabled'] == true;
    _operationEpoch++;
    final requestedEpoch = _operationEpoch;
    generations.invalidateAll();
    sourceRuntimePolicy.requestMode(
      cloudEnabled: enabled,
      operationEpoch: requestedEpoch,
    );
    await withCommitLock(() async {
      _ensureCurrentEpoch(requestedEpoch);
      appdata.settings['cloudTrackingEnabled'] = enabled;
      try {
        await _persistSettings();
        _ensureCurrentEpoch(requestedEpoch);
      } catch (error, stack) {
        // An old request must not restore its old setting after a newer
        // request has already invalidated its epoch.
        if (_operationEpoch == requestedEpoch) {
          appdata.settings['cloudTrackingEnabled'] = previous;
          _operationEpoch++;
          generations.invalidateAll();
          sourceRuntimePolicy.requestMode(
            cloudEnabled: previous,
            operationEpoch: _operationEpoch,
          );
          denySourceRuntimes();
          _lastError = 'Cloud mode could not be persisted: $error';
          notifyListeners();
        }
        Log.error('Persist Cloud tracking mode', error, stack);
        rethrow;
      }
    });
    if (!_disposed && requestedEpoch == _operationEpoch) {
      await refreshNow();
    }
  }

  /// Reloads every source through the same mutation fence used by source
  /// editors and revision activation.  This is used by import/debug entry
  /// points that replace the whole source directory rather than one known
  /// artifact.
  Future<void> reloadAllSources() async {
    if (_disposed) return;
    final epoch = beforeArtifactsChange();
    try {
      await withCommitLock(() => reloadSourcesLocked(epoch));
    } catch (error, stack) {
      // A failed directory reload still invalidated the old generations.  Do
      // the reconciliation before returning so a later retry cannot inherit
      // a permanently fenced runtime.
      try {
        await onSettingsChanged();
      } catch (reconcileError, reconcileStack) {
        Log.error(
          'Reconcile comic sources after reload failure',
          reconcileError,
          reconcileStack,
        );
      }
      Error.throwWithStackTrace(error, stack);
    }
    await onSettingsChanged();
  }

  void denySourceRuntimes() {
    sourceRuntimePolicy.admissionSuspended = true;
    sourceRuntimePolicy.admissionReady = false;
    sourceRuntimePolicy.revokeAll();
    generations.invalidateAll();
  }

  /// Caller owns the commit lock. Does not advance the epoch or enter a
  /// refresh/network queue; a newer mode request always wins.
  Future<void> reloadSourcesLocked(int epoch) async {
    requireCurrentCommit(epoch);
    final registry = await revisions.store.loadOrMigrate(cloudEnabled: true);
    requireCurrentCommit(epoch);
    _registry = registry;
    sourceRuntimePolicy.prepare(
      cloudEnabled: cloudEnabled,
      registry: registry,
      sourceDirectoryPath: sourceDirectory.path,
      authorityRevision: _authority?.activeRevision,
      operationEpoch: epoch,
    );
    final manager = ComicSourceManager();
    await manager.reloadUnderCommitLock();
    requireCurrentCommit(epoch);
    // A Local fallback may have durably registered a legacy root while the
    // reload was in progress.  Validate the registry produced by that reload,
    // not the snapshot used to start it, and require both sides of the
    // ownership handoff: the manager's Dart collection and the policy context.
    final latestRegistry = await revisions.store.loadOrMigrate(
      cloudEnabled: true,
    );
    requireCurrentCommit(epoch);
    _registry = latestRegistry;
    sourceRuntimePolicy.updateRegistry(
      latestRegistry,
      authorityRevision: _authority?.activeRevision,
    );
    for (final artifact in latestRegistry.artifacts) {
      if (artifact.activationBlocked) continue;
      try {
        manager.requireLoadedArtifact(artifact);
        if (!sourceRuntimePolicy.hasActiveRuntime(artifact)) {
          throw StateError('active runtime admission does not match artifact');
        }
      } catch (error, stack) {
        denySourceRuntimes();
        final safeFileName = artifact.fileName.replaceAll(
          RegExp(r'[\x00-\x1f\x7f\r\n]'),
          '?',
        );
        Log.error(
          'Imported source runtime verification for $safeFileName',
          error,
          stack,
        );
        throw StateError(
          'Imported source runtime was not verified: $safeFileName',
        );
      }
    }
  }

  /// Schedules an idempotent full interest replacement after a favorite/cache
  /// mutation. Cloud observations are suppressed from recursively scheduling
  /// themselves while their transaction is being committed.
  void onFavoritesChanged() {
    if (!_started || _disposed || _suppressFavoriteChange || !cloudEnabled) {
      return;
    }
    _interestTimer?.cancel();
    _interestTimer = Timer(const Duration(milliseconds: 250), () {
      _interestTimer = null;
      _operationEpoch++;
      unawaited(refreshNow());
    });
  }

  /// Filters Local follow-up work according to the live effective strategy.
  /// Cloud-capable artifacts remain paused when the Server is unavailable;
  /// they are never silently scanned locally.
  List<NetworkFavoriteFolderRef> localFolders(
    Iterable<NetworkFavoriteFolderRef> folders,
  ) {
    return folders
        .where((folder) {
          final artifact = _artifactForSource(folder.sourceKey);
          if (artifact == null) {
            if (!cloudEnabled) return true;
            final candidates = _registry?.artifacts
                .where((item) => item.sourceKey == folder.sourceKey)
                .toList(growable: false);
            if (candidates != null &&
                candidates.any((item) {
                  final strategy = modes.strategyFor(item.identity);
                  return strategy == TrackingStrategy.cloud ||
                      strategy == TrackingStrategy.pausedCloud ||
                      _blockedFromLocal.contains(item.identity);
                })) {
              return false;
            }
            return true;
          }
          if (_blockedFromLocal.contains(artifact)) return false;
          if (!followUpdatesEnabledValue) return false;
          if (!cloudEnabled) return true;
          final strategy = modes.strategyFor(artifact);
          if (strategy == TrackingStrategy.cloud ||
              strategy == TrackingStrategy.pausedCloud) {
            return false;
          }
          return !_blockedFromLocal.contains(artifact);
        })
        .toList(growable: false);
  }

  /// Returns live status rows for Settings and diagnostics.
  Future<List<TrackingArtifactStatus>> statuses() async {
    final registry = _registry ?? await revisions.current();
    _registry = registry;
    return [for (final active in registry.artifacts) _statusFor(active)];
  }

  Future<void> refreshNow() async {
    if (_disposed) return;
    final running = _refreshFuture;
    if (running != null) return running;
    final future = _refreshLoop();
    _refreshFuture = future;
    try {
      await future;
    } finally {
      if (identical(_refreshFuture, future)) _refreshFuture = null;
    }
  }

  Future<void> _refreshLoop() async {
    while (!_disposed) {
      final epoch = _operationEpoch;
      await _refreshInternal(epoch);
      if (epoch == _operationEpoch) break;
    }
  }

  Future<void> _refreshInternal(int epoch) async {
    try {
      var registry = await withCommitLock(() async {
        _ensureCurrentEpoch(epoch);
        await SourceImportTransaction(sourceDirectory).recover();
        _ensureCurrentEpoch(epoch);
        final discovered = await revisions.store.loadOrMigrate(
          cloudEnabled: true,
        );
        _ensureCurrentEpoch(epoch);
        return discovered;
      });
      _ensureCurrentEpoch(epoch);
      _registry = registry;
      final followEnabled = followUpdatesEnabledValue;
      modes.followUpdatesEnabled = followEnabled;
      final client = _configuredClient();
      modes.cloudEnabled = cloudEnabled;
      if (cloudEnabled && sourceRuntimePolicy.pendingCloudEnable) {
        for (final identity in registry.artifacts.map(
          (item) => item.identity,
        )) {
          final active = registry.find(identity.sourceKey, identity.fileName);
          if (active == null || active.activationBlocked) continue;
          _ensureCurrentEpoch(epoch);
          try {
            registry = await withCommitLock(() async {
              _ensureCurrentEpoch(epoch);
              final current = await revisions.current();
              _ensureCurrentEpoch(epoch);
              final selected = current.find(
                identity.sourceKey,
                identity.fileName,
              );
              if (selected == null || !_sameSelectedRuntime(selected, active)) {
                throw const _StaleCloudRefresh();
              }
              _selectionOwners[identity] = epoch;
              _takeoverPrior[identity] = active;
              final prepared = await revisions.prepareForCloudTakeover(
                identity,
              );
              _ensureCurrentEpoch(epoch);
              return prepared;
            });
          } catch (error, stack) {
            if (error is _StaleCloudRefresh) rethrow;
            Log.error(
              'Prepare source artifact for Cloud takeover',
              error,
              stack,
            );
            registry = await revisions.current();
          }
          _registry = registry;
          sourceRuntimePolicy.updateRegistry(
            registry,
            authorityRevision: _authority?.activeRevision,
          );
        }
      }
      if (!cloudEnabled) {
        for (final active in registry.artifacts) {
          final prior = _takeoverPrior[active.identity];
          final owner = _selectionOwners[active.identity];
          if (active.activationBlocked &&
              prior != null &&
              owner != null &&
              !prior.activationBlocked &&
              prior.origin == ArtifactOrigin.managedCatalog &&
              _sameSelectedRuntime(active, prior)) {
            await _restoreAfterActivation(
              registry.copyWith(
                artifacts: [
                  for (final item in registry.artifacts)
                    if (item.identity == active.identity) prior else item,
                ],
              ),
              active.identity,
              null,
              owner,
            );
            _ensureCurrentEpoch(epoch);
          }
        }
        registry = await revisions.current();
        _ensureCurrentEpoch(epoch);
        if (client != null) {
          await _bestEffortDisableCloud(client, registry, epoch);
          _ensureCurrentEpoch(epoch);
        } else {
          _authority = null;
        }
        sourceRuntimePolicy.prepare(
          cloudEnabled: false,
          registry: registry,
          sourceDirectoryPath: sourceDirectory.path,
          operationEpoch: epoch,
        );
        for (final active in registry.artifacts) {
          modes.setCapability(active.identity, active.cloudCapable);
          modes.setActivationBlocked(active.identity, active.activationBlocked);
          modes.setRevisionAligned(
            active.identity,
            active.revision != null && !active.activationBlocked,
          );
        }
        _blockedFromLocal
          ..clear()
          ..addAll(
            registry.artifacts
                .where((item) => item.activationBlocked)
                .map((item) => item.identity),
          );
        sourceRuntimePolicy.admissionReady = true;
        if (_runtimeReloader == null &&
            registry.artifacts.any(
              (artifact) =>
                  !artifact.activationBlocked &&
                  !sourceRuntimePolicy.hasActiveRuntime(artifact),
            )) {
          await withCommitLock(() => reloadSourcesLocked(epoch));
          _ensureCurrentEpoch(epoch);
        }
        _activateLocalOrPaused(registry);
        _lastError = null;
        notifyListeners();
        return;
      }

      if (client == null) {
        _authority = null;
        sourceRuntimePolicy.prepare(
          cloudEnabled: true,
          registry: registry,
          sourceDirectoryPath: sourceDirectory.path,
          operationEpoch: epoch,
        );
        sourceRuntimePolicy.requestMode(
          cloudEnabled: true,
          operationEpoch: epoch,
        );
        _blockedFromLocal
          ..clear()
          ..addAll(registry.artifacts.map((item) => item.identity));
        for (final active in registry.artifacts) {
          modes.setCapability(active.identity, false);
          modes.setActivationBlocked(active.identity, true);
          modes.setRevisionAligned(active.identity, false);
          modes.pause(
            active.identity,
            'Cloud tracking is paused: Server authority is unavailable.',
          );
        }
        _lastError =
            'Cloud tracking is paused: Server authority is unavailable.';
        _activateLocalOrPaused(registry);
        notifyListeners();
        return;
      }

      final authority = await client.getAuthority();
      _ensureCurrentEpoch(epoch);
      _authority = authority;
      sourceRuntimePolicy.authorityRevision = authority.activeRevision;
      final alignment = await _alignAndActivate(
        registry,
        authority,
        followEnabled,
        epoch,
      );
      _ensureCurrentEpoch(epoch);
      final interests = interestSync.buildInterests(
        favorites.getTrackingFavoriteRefs(
          fileNameForSource: _fileNameForSource,
        ),
        registry: _registry!,
        capableArtifacts: alignment.cloudCapable,
      );
      _ensureCurrentEpoch(epoch);
      await _putClientState(
        client,
        cloudEnabled: true,
        interests: interests,
        epoch: epoch,
      );
      _ensureCurrentEpoch(epoch);
      final result = await client.getObservations();
      _ensureCurrentEpoch(epoch);
      if (!result.notModified && result.snapshot != null) {
        await _applySnapshotByArtifact(result.snapshot!, interests, epoch);
      }
      _ensureCurrentEpoch(epoch);
      sourceRuntimePolicy.admissionReady = true;
      sourceRuntimePolicy.pendingCloudEnable = false;
      sourceRuntimePolicy.updateRegistry(
        _registry!,
        authorityRevision: authority.activeRevision,
      );
      _lastError = null;
      notifyListeners();
    } on _StaleCloudRefresh {
      return;
    } catch (error, stack) {
      _lastError = error.toString();
      Log.error('Cloud tracking coordinator', error, stack);
      // The current artifact remains paused when Cloud is enabled. This is
      // the intentional failure mode required by FR-037.
      if (_registry != null) {
        _blockedFromLocal.addAll(
          _registry!.artifacts.map((item) => item.identity),
        );
        for (final active in _registry!.artifacts) {
          modes.setActivationBlocked(active.identity, true);
          modes.pause(
            active.identity,
            'Cloud tracking is paused: Server authority is unavailable.',
          );
        }
        _activateLocalOrPaused(_registry!);
      }
      notifyListeners();
    }
  }

  void _ensureCurrentEpoch(int epoch) {
    if (_disposed || epoch != _operationEpoch) {
      throw const _StaleCloudRefresh();
    }
  }

  Future<_AlignmentResult> _alignAndActivate(
    ActiveArtifactRegistry registry,
    TrustedAuthority authority,
    bool followEnabled,
    int epoch,
  ) async {
    final aligned = <TrustedArtifact>{};
    final cloudCapable = <TrustedArtifact>{};
    final index = await revisions.fetchIndex(
      revision: authority.activeRevision,
      fetch: _fetchCatalogBytes,
    );
    final identities = registry.artifacts.map((item) => item.identity).toList();
    for (final identity in identities) {
      _ensureCurrentEpoch(epoch);
      final active = (_registry ?? registry).find(
        identity.sourceKey,
        identity.fileName,
      );
      if (active == null) continue;
      final entry = index.findByArtifact(identity);
      final cloudScanCapable =
          entry?.cloudCapable == true && authority.contains(identity);
      modes.setCapability(identity, cloudScanCapable);
      modes.setActivationBlocked(identity, true);
      modes.setRevisionAligned(identity, false);
      _blockedFromLocal.add(identity);
      ActiveArtifactRegistry? previousRegistry;
      ActiveArtifact? attemptedArtifact;
      var takeoverPrepared = false;
      try {
        previousRegistry = await revisions.current();
        final previous = previousRegistry.find(
          identity.sourceKey,
          identity.fileName,
        );
        if (previous == null) continue;
        final verifiedPrior = _takeoverPrior[identity];
        if (verifiedPrior != null &&
            _sameSelectedRuntime(verifiedPrior, previous)) {
          previousRegistry = previousRegistry.copyWith(
            artifacts: [
              for (final item in previousRegistry.artifacts)
                if (item.identity == identity) verifiedPrior else item,
            ],
          );
        }
        generations.invalidate(identity);
        await withCommitLock(() async {
          _ensureCurrentEpoch(epoch);
          final latest = await revisions.current();
          final latestActive = latest.find(
            identity.sourceKey,
            identity.fileName,
          );
          if (latestActive == null ||
              !_sameSelectedRuntime(latestActive, previous)) {
            throw const _StaleCloudRefresh();
          }
          _selectionOwners[identity] = epoch;
          await revisions.prepareForCloudTakeover(identity);
          takeoverPrepared = true;
          _ensureCurrentEpoch(epoch);
          _registry = await revisions.current();
          sourceRuntimePolicy.updateRegistry(
            _registry!,
            authorityRevision: authority.activeRevision,
          );
        });
        if (entry == null) {
          modes.pause(
            identity,
            'Artifact is missing from the trusted catalog.',
          );
          continue;
        }
        final staged = await revisions.stageCatalogEntry(
          revision: authority.activeRevision,
          entry: entry,
          fetch: _fetchCatalogBytes,
          resolveSourceKey:
              _sourceKeyResolver ??
              (_runtimeReloader == null ? _resolveSourceKey : null),
        );
        attemptedArtifact = staged.artifact.copyWith(
          cloudCapable: staged.cloudCapable,
        );
        _ensureCurrentEpoch(epoch);
        await withCommitLock(() async {
          _ensureCurrentEpoch(epoch);
          final latest = await revisions.current();
          final latestActive = latest.find(
            identity.sourceKey,
            identity.fileName,
          );
          if (latestActive == null ||
              !_sameSelectedRuntime(latestActive, previous)) {
            throw const _StaleCloudRefresh();
          }
          final updated = await revisions.commitStaged(
            staged,
            expectedCurrent: latestActive,
            activationBlocked: true,
            beforeCommit: () => _ensureCurrentEpoch(epoch),
          );
          _ensureCurrentEpoch(epoch);
          final alignedArtifact = updated.find(
            identity.sourceKey,
            identity.fileName,
          );
          if (alignedArtifact == null) {
            throw StateError('activated artifact is missing');
          }
          _registry = updated;
          sourceRuntimePolicy.updateRegistry(
            updated,
            authorityRevision: authority.activeRevision,
          );
          await _reloadRuntime(alignedArtifact);
          await revisions.store.readBytes(alignedArtifact);
          _ensureCurrentEpoch(epoch);
          final unblocked = await revisions.setActivationBlocked(
            identity,
            false,
          );
          _registry = unblocked;
          sourceRuntimePolicy.updateRegistry(
            unblocked,
            authorityRevision: authority.activeRevision,
          );
          _ensureCurrentEpoch(epoch);
          sourceRuntimePolicy.promoteRuntime(identity);
          revisions.revokeCandidatePermit(identity);
          modes.setRevisionAligned(identity, true);
          modes.setActivationBlocked(identity, false);
          modes.clearPause(identity);
          _blockedFromLocal.remove(identity);
          aligned.add(identity);
          if (cloudScanCapable) cloudCapable.add(identity);
          generations.activateIfChanged(
            artifact: identity,
            revision: alignedArtifact.revision ?? authority.activeRevision,
            strategy: followEnabled
                ? (cloudScanCapable
                      ? TrackingStrategy.cloud
                      : TrackingStrategy.local)
                : TrackingStrategy.off,
          );
        });
      } on _StaleCloudRefresh {
        revisions.revokeCandidatePermit(identity);
        if (takeoverPrepared && previousRegistry != null) {
          await _restoreAfterActivation(
            previousRegistry,
            identity,
            attemptedArtifact,
            epoch,
          );
        }
        rethrow;
      } catch (error, stack) {
        revisions.revokeCandidatePermit(identity);
        if (takeoverPrepared && previousRegistry != null) {
          await _restoreAfterActivation(
            previousRegistry,
            identity,
            attemptedArtifact,
            epoch,
          );
        }
        modes.setRevisionAligned(identity, false);
        modes.setActivationBlocked(identity, true);
        modes.pause(identity, 'Cloud artifact activation failed: $error');
        _blockedFromLocal.add(identity);
        Log.error('Cloud tracking artifact ${identity.fileName}', error, stack);
      }
    }
    return _AlignmentResult(allAligned: aligned, cloudCapable: cloudCapable);
  }

  Future<void> _reloadRuntime(ActiveArtifact artifact) {
    final reloader = _runtimeReloader;
    if (reloader != null) return reloader(artifact);
    return ComicSourceManager().reloadUnderCommitLock(
      requiredArtifact: artifact,
    );
  }

  Future<String> _resolveSourceKey(String source, String filePath) async {
    final parsed = await ComicSourceParser().parse(
      source,
      filePath,
      register: false,
      allowExistingKey: true,
      loadData: false,
      scheduleInit: false,
    );
    return parsed.key;
  }

  Future<bool> _restoreAfterActivation(
    ActiveArtifactRegistry previousRegistry,
    TrustedArtifact artifact,
    ActiveArtifact? attemptedArtifact,
    int epoch,
  ) => withCommitLock(
    () => _restoreAfterActivationLocked(
      previousRegistry,
      artifact,
      attemptedArtifact,
      epoch,
    ),
  );

  Future<bool> _restoreAfterActivationLocked(
    ActiveArtifactRegistry previousRegistry,
    TrustedArtifact artifact,
    ActiveArtifact? attemptedArtifact,
    int epoch,
  ) async {
    if (_selectionOwners[artifact] != epoch) return false;
    final recoveryEpoch = _operationEpoch;
    try {
      final current = await revisions.current();
      _ensureCurrentEpoch(recoveryEpoch);
      final selected = current.find(artifact.sourceKey, artifact.fileName);
      final prior = previousRegistry.find(
        artifact.sourceKey,
        artifact.fileName,
      );
      final isAttemptedSelection =
          selected != null &&
          attemptedArtifact != null &&
          _sameSelectedRuntime(selected, attemptedArtifact);
      final isPreparedPriorSelection =
          selected != null &&
          prior != null &&
          _sameSelectedRuntime(selected, prior);
      // A failed fetch before takeover, or an unrelated concurrent custom
      // edit/delete, must not be overwritten by recovery.  Only undo a
      // pointer that is visibly the exact attempted revision or the exact
      // prior selection after its durable blocked marker was written.
      if (selected == null ||
          (!isAttemptedSelection && !isPreparedPriorSelection)) {
        return false;
      }
      if (prior == null) return false;
      final authorityRevision = _authority?.activeRevision;
      final canRunRestored =
          !prior.activationBlocked &&
          prior.origin == ArtifactOrigin.managedCatalog &&
          (!cloudEnabled ||
              (prior.origin == ArtifactOrigin.managedCatalog &&
                  prior.revision != null &&
                  authorityRevision != null &&
                  prior.revision == authorityRevision));
      final restored = await revisions.restoreArtifactSelection(
        identity: artifact,
        expectedCurrent: selected,
        replacement: prior,
        activationBlocked: !canRunRestored,
      );
      _ensureCurrentEpoch(recoveryEpoch);
      _registry = restored;
      final restoredArtifact = restored.find(
        artifact.sourceKey,
        artifact.fileName,
      );
      if (restoredArtifact == null) {
        throw StateError('restored artifact missing');
      }
      sourceRuntimePolicy.updateRegistry(
        restored,
        authorityRevision: cloudEnabled ? authorityRevision : null,
      );
      // A durable recovery pointer is not Cloud runtime permission. An old
      // revision/custom selection stays blocked until the current authority
      // explicitly aligns it.
      if (canRunRestored) {
        if (_runtimeReloader == null) {
          await revisions.store.readBytes(restoredArtifact);
          _ensureCurrentEpoch(recoveryEpoch);
        }
        await _reloadRuntime(restoredArtifact);
        _ensureCurrentEpoch(recoveryEpoch);
      } else {
        generations.invalidate(artifact);
        modes.setActivationBlocked(artifact, true);
        modes.pause(
          artifact,
          'Cloud artifact recovery is durable but not aligned to authority.',
        );
      }
      return true;
    } catch (error, stack) {
      if (recoveryEpoch != _operationEpoch ||
          _selectionOwners[artifact] != epoch) {
        return false;
      }
      Log.error('Cloud tracking rollback', error, stack);
      try {
        final blocked = await revisions.setActivationBlocked(
          artifact,
          true,
          preserveLastKnownGood: true,
        );
        _registry = blocked;
        sourceRuntimePolicy.updateRegistry(blocked);
        generations.invalidate(artifact);
      } catch (blockError, blockStack) {
        // If even the blocked registry cannot be persisted, keep admission
        // denied in memory.  No unverified pointer is reloaded or published.
        sourceRuntimePolicy.admissionReady = false;
        _registry = null;
        Log.error('Cloud tracking fail-closed block', blockError, blockStack);
      }
      modes.pause(
        artifact,
        'Cloud artifact recovery failed; runtime is blocked.',
      );
      modes.setActivationBlocked(artifact, true);
      _blockedFromLocal.add(artifact);
      return false;
    }
  }

  void _activateLocalOrPaused(ActiveArtifactRegistry registry) {
    for (final active in registry.artifacts) {
      final artifact = active.identity;
      if (_authority == null) {
        modes.setCapability(artifact, active.cloudCapable);
        modes.setActivationBlocked(artifact, active.activationBlocked);
        modes.setRevisionAligned(artifact, false);
      }
      final capable =
          modes.strategyFor(artifact) != TrackingStrategy.local &&
          modes.strategyFor(artifact) != TrackingStrategy.off;
      if (!capable) {
        modes.setCapability(artifact, false);
        modes.setRevisionAligned(artifact, false);
      }
      final strategy = modes.strategyFor(artifact);
      generations.activateIfChanged(
        artifact: artifact,
        revision: active.revision ?? 'local',
        strategy: strategy,
      );
    }
  }

  Future<void> _applySnapshotByArtifact(
    CloudObservationSnapshot snapshot,
    List<TrackingInterest> interests,
    int epoch,
  ) async {
    final groups = <TrustedArtifact, List<CloudObservation>>{};
    final interestKeys = {
      for (final interest in interests)
        _interestKey(interest.artifact, interest.comicId),
    };
    for (final observation in snapshot.observations) {
      groups.putIfAbsent(observation.artifact, () => []).add(observation);
    }
    final applyService = TrackingApplyService(
      _applyStore ?? favorites.trackingApplyStore,
      diagnostics: diagnostics,
    );
    final service = CloudObservationService(
      catalog: catalog,
      generations: generations,
      applyService: applyService,
      diagnostics: diagnostics,
      isInterest: (artifact, comicId) =>
          interestKeys.contains(_interestKey(artifact, comicId)),
      isArtifactAdmitted: (artifact) {
        final active = _registry?.find(artifact.sourceKey, artifact.fileName);
        return active != null &&
            active.origin == ArtifactOrigin.managedCatalog &&
            active.revision == snapshot.authority.activeRevision &&
            !active.activationBlocked;
      },
    );
    _suppressFavoriteChange = true;
    try {
      for (final entry in groups.entries) {
        _ensureCurrentEpoch(epoch);
        final active = _registry?.find(entry.key.sourceKey, entry.key.fileName);
        if (active == null ||
            active.revision != snapshot.authority.activeRevision) {
          continue;
        }
        final current = generations.current(entry.key);
        if (current == null || current.strategy != TrackingStrategy.cloud) {
          continue;
        }
        try {
          final results = service.applySnapshot(
            CloudObservationSnapshot(
              authority: snapshot.authority,
              generatedAt: snapshot.generatedAt,
              observations: List.unmodifiable(entry.value),
            ),
            current,
          );
          if (results.isNotEmpty) {
            // The apply service has returned only after its one transaction
            // committed. This notification is deliberately separate from
            // membership synchronization and is suppressed from scheduling
            // another interest refresh.
            favorites.notifyCacheChanged();
          }
        } on _StaleCloudRefresh {
          rethrow;
        } catch (error, stack) {
          modes.pause(entry.key, 'Cloud artifact apply failed: $error');
          _blockedFromLocal.add(entry.key);
          Log.error('Cloud tracking apply ${entry.key.fileName}', error, stack);
        }
      }
    } finally {
      _suppressFavoriteChange = false;
    }
  }

  String _interestKey(TrustedArtifact artifact, String comicId) =>
      '${artifact.sourceKey}\u0000${artifact.fileName}\u0000$comicId';

  Future<void> _bestEffortDisableCloud(
    CloudTrackingClient client,
    ActiveArtifactRegistry registry,
    int epoch,
  ) async {
    try {
      _ensureCurrentEpoch(epoch);
      final authority = await client.getAuthority();
      _ensureCurrentEpoch(epoch);
      final interests = interestSync.buildInterests(
        favorites.getTrackingFavoriteRefs(
          fileNameForSource: _fileNameForSource,
        ),
        registry: registry,
        capableArtifacts: authority.artifacts,
      );
      _ensureCurrentEpoch(epoch);
      await _putClientState(
        client,
        cloudEnabled: false,
        interests: interests,
        epoch: epoch,
      );
      _ensureCurrentEpoch(epoch);
      _authority = authority;
    } on _StaleCloudRefresh {
      rethrow;
    } catch (error) {
      // Disabling Cloud is still safe locally after the generation change;
      // retrying this idempotent control update happens on the next settings
      // or favorite refresh.
      Log.warning(
        'Cloud tracking',
        'Unable to disable Cloud on Server: $error',
      );
    }
  }

  /// Serializes client-state PUTs independently from the source mutation
  /// flow.  A request already in flight may finish, but its epoch is checked
  /// before and after the transport and a later refresh queues the current
  /// body instead of treating the old response as proof of the new mode.
  Future<CloudClientState> _putClientState(
    CloudTrackingClient client, {
    required bool cloudEnabled,
    required List<TrackingInterest> interests,
    required int epoch,
  }) {
    final previous = _clientStateQueue ?? Future<void>.value();
    final next = previous.catchError((_) {}).then((_) async {
      _ensureCurrentEpoch(epoch);
      final result = await client.putClientState(
        cloudEnabled: cloudEnabled,
        interests: interests,
      );
      _ensureCurrentEpoch(epoch);
      return result;
    });
    _clientStateQueue = next.then<void>((_) {}, onError: (_, _) {});
    return next;
  }

  TrackingArtifactStatus _statusFor(ActiveArtifact active) {
    final status = modes.statusFor(active.identity, revision: active.revision);
    final loadedRevision = generations.current(active.identity)?.revision;
    final withOwnership = TrackingArtifactStatus(
      artifact: status.artifact,
      revision: status.revision,
      strategy: status.strategy,
      reason: status.reason,
      activationBlocked: active.activationBlocked,
      loadedRevision: loadedRevision,
      relativePath: active.relativePath,
    );
    final artifactError = modes.errorFor(active.identity);
    if (artifactError != null &&
        cloudEnabled &&
        modes.isCapable(active.identity)) {
      return TrackingArtifactStatus(
        artifact: withOwnership.artifact,
        revision: withOwnership.revision,
        strategy: TrackingStrategy.pausedCloud,
        reason: artifactError,
        activationBlocked: withOwnership.activationBlocked,
        loadedRevision: withOwnership.loadedRevision,
        relativePath: withOwnership.relativePath,
      );
    }
    if (cloudEnabled &&
        _lastError != null &&
        modes.isCapable(active.identity)) {
      return TrackingArtifactStatus(
        artifact: withOwnership.artifact,
        revision: withOwnership.revision,
        strategy: TrackingStrategy.pausedCloud,
        reason: 'Cloud tracking is paused: Server authority is unavailable.',
        activationBlocked: withOwnership.activationBlocked,
        loadedRevision: withOwnership.loadedRevision,
        relativePath: withOwnership.relativePath,
      );
    }
    return withOwnership;
  }

  TrustedArtifact? _artifactForSource(String sourceKey) {
    final fileName = _fileNameForSource(sourceKey);
    if (fileName == null) return null;
    final matches = _registry?.artifacts
        .where(
          (item) => item.sourceKey == sourceKey && item.fileName == fileName,
        )
        .toList(growable: false);
    if (matches?.length == 1) return matches!.single.identity;
    return null;
  }

  String? _fileNameForSource(String sourceKey) {
    final source = ComicSource.find(sourceKey);
    final candidates = _registry?.artifacts
        .where((item) => item.sourceKey == sourceKey)
        .toList(growable: false);
    if (source == null) {
      return candidates?.length == 1 ? candidates!.single.fileName : null;
    }
    final value = p.basename(source.filePath);
    if (!value.endsWith('.js')) return null;
    if (candidates != null && candidates.length != 1) return null;
    return candidates == null || candidates.single.fileName == value
        ? value
        : null;
  }

  CloudTrackingClient? _configuredClient() {
    final raw = appdata.settings['cloudTrackingServerUrl'];
    if (raw is! String || raw.trim().isEmpty) return null;
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return null;
    }
    final token = appdata.settings['cloudTrackingAccessToken'] as String? ?? '';
    final current = _client;
    if (current != null &&
        current.server == uri &&
        current.accessToken == token) {
      return current;
    }
    final next = (_clientFactory ?? _defaultClientFactory)(uri, token);
    _client = next;
    return next;
  }

  CloudTrackingClient _defaultClientFactory(Uri server, String token) =>
      CloudTrackingClient(server: server, accessToken: token, catalog: catalog);

  Future<List<int>> _fetchCatalogBytes(Uri uri) async {
    final artifactFetcher = _artifactFetcher;
    if (artifactFetcher != null) return artifactFetcher(uri);
    final response = await AppDio().get<List<int>>(
      uri.toString(),
      options: Options(
        responseType: ResponseType.bytes,
        headers: const {'cache-time': 'no'},
      ),
    );
    if (response.statusCode != 200 || response.data == null) {
      throw FormatException(
        'catalog fetch failed with status ${response.statusCode}',
      );
    }
    return List<int>.from(response.data!);
  }

  void _onFavoritesChanged() => onFavoritesChanged();

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    favorites.removeListener(_onFavoritesChanged);
    _pollTimer?.cancel();
    _interestTimer?.cancel();
    generations.invalidateAll();
    super.dispose();
  }
}

bool get followUpdatesEnabledValue =>
    appdata.settings['followUpdatesEnabled'] == true;

bool _sameSelectedRuntime(ActiveArtifact left, ActiveArtifact right) =>
    left.sourceKey == right.sourceKey &&
    left.fileName == right.fileName &&
    left.revision == right.revision &&
    left.relativePath == right.relativePath &&
    left.origin == right.origin &&
    left.sha256 == right.sha256 &&
    left.cloudCapable == right.cloudCapable;

class _StaleCloudRefresh implements Exception {
  const _StaleCloudRefresh();
}

class _AlignmentResult {
  const _AlignmentResult({
    required this.allAligned,
    required this.cloudCapable,
  });

  final Set<TrustedArtifact> allAligned;
  final Set<TrustedArtifact> cloudCapable;
}
