import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'source_revision_store.dart';
import 'trusted_catalog.dart';

/// The single runtime admission boundary used by source loading, validation,
/// and custom mutations.  A registry pointer is data; this policy decides
/// whether that pointer is currently executable.
class SourceRuntimePolicy {
  SourceRuntimePolicy._();

  static final instance = SourceRuntimePolicy._();

  bool cloudEnabled = false;
  bool pendingCloudEnable = false;
  // Keep parser-only unit tests and the pre-feature Local path usable until
  // production startup supplies the persisted registry.  Once a registry is
  // configured, every load is governed by the explicit admission state.
  bool admissionReady = true;
  bool admissionSuspended = false;
  int operationEpoch = 0;
  ActiveArtifactRegistry? registry;
  String? sourceDirectoryPath;
  String? authorityRevision;

  void prepare({
    required bool cloudEnabled,
    required ActiveArtifactRegistry registry,
    String? sourceDirectoryPath,
    String? authorityRevision,
    int operationEpoch = 0,
  }) {
    this.cloudEnabled = cloudEnabled;
    this.registry = registry;
    this.sourceDirectoryPath = sourceDirectoryPath;
    this.authorityRevision = authorityRevision;
    this.operationEpoch = operationEpoch;
    pendingCloudEnable = false;
    admissionReady = true;
    admissionSuspended = false;
    _revokeInvalidContexts();
  }

  void requestMode({required bool cloudEnabled, required int operationEpoch}) {
    this.cloudEnabled = cloudEnabled;
    this.operationEpoch = operationEpoch;
    pendingCloudEnable = cloudEnabled;
    if (cloudEnabled) {
      admissionReady = false;
    }
    revokeAll();
  }

  void updateRegistry(
    ActiveArtifactRegistry registry, {
    String? authorityRevision,
  }) {
    this.registry = registry;
    this.authorityRevision = authorityRevision;
    _revokeInvalidContexts();
  }

  bool get customMutationAllowed =>
      admissionReady && !cloudEnabled && !pendingCloudEnable;

  void requireCustomMutationAllowed() {
    if (!customMutationAllowed) {
      throw const SourceMutationDenied(
        'Turn off Cloud before editing or installing a custom source.',
      );
    }
  }

  bool allowUnmanagedRoot(String path) {
    if (!admissionReady || cloudEnabled) return false;
    final normalized = _normalizePath(path);
    final current = registry;
    if (current == null) return true;
    if (current.artifacts.any(
      (artifact) => _artifactPath(artifact) == normalized,
    )) {
      return false;
    }
    if (current.recoverableArtifacts.any(
      (artifact) => _artifactPath(artifact) == normalized,
    )) {
      return false;
    }
    return true;
  }

  bool canLoadPath(String path, {SourceRuntimePermit? permit}) {
    if (admissionSuspended) return false;
    final normalized = _normalizePath(path);
    final candidate = permit ?? permitForPath(normalized);
    if (candidate != null &&
        candidate._allows(normalized, operationEpoch, cloudEnabled)) {
      return true;
    }
    final selected = _selectedByPath(normalized);
    // During a Cloud takeover the global admission remains pending until all
    // installed artifacts have been reconciled.  A previously verified exact
    // pinned artifact may still be needed by the next required-artifact
    // reload; it is safe only when it already matches the current authority.
    if (cloudEnabled &&
        selected != null &&
        !selected.activationBlocked &&
        selected.origin == ArtifactOrigin.managedCatalog &&
        selected.revision != null &&
        authorityRevision != null &&
        selected.revision == authorityRevision) {
      return true;
    }
    if (!admissionReady) return false;
    if (selected == null) {
      return !cloudEnabled && allowUnmanagedRoot(normalized);
    }
    if (selected.activationBlocked) return false;
    if (!cloudEnabled) return true;
    return selected.origin == ArtifactOrigin.managedCatalog &&
        selected.revision != null &&
        authorityRevision != null &&
        selected.revision == authorityRevision;
  }

  void requireLoadPath(String path, {SourceRuntimePermit? permit}) {
    if (!canLoadPath(path, permit: permit)) {
      throw const SourceRuntimeDenied(
        'Source runtime is not admitted for the current Cloud ownership state.',
      );
    }
  }

  SourceRuntimePermit issueCandidatePermit({
    required TrustedArtifact identity,
    required String path,
    required String sha256,
    required String? revision,
  }) {
    final cloud = cloudEnabled;
    if (admissionSuspended) {
      throw const SourceRuntimeDenied('Source admission is suspended.');
    }
    if (!admissionReady && !cloud) {
      throw const SourceRuntimeDenied('Runtime admission is not ready.');
    }
    if (cloud && revision == null) {
      throw const SourceRuntimeDenied('Cloud candidates must be pinned.');
    }
    final permit = SourceRuntimePermit._(
      identity: identity,
      path: _normalizePath(path),
      sha256: sha256,
      revision: revision,
      epoch: operationEpoch,
      cloudEnabled: cloud,
    );
    _permits.add(permit);
    return permit;
  }

  bool validateCandidateSource(
    SourceRuntimePermit permit,
    String path,
    String source,
  ) {
    if (!permit._allows(_normalizePath(path), operationEpoch, cloudEnabled)) {
      return false;
    }
    final normalized = source.replaceAll('\r\n', '\n');
    return sha256.convert(utf8.encode(normalized)).toString() == permit.sha256;
  }

  void revoke(SourceRuntimePermit permit) {
    permit._revoked = true;
    _permits.remove(permit);
    _revokeInvalidContexts();
  }

  void revokeAll() {
    for (final permit in _permits) {
      permit._revoked = true;
    }
    _permits.clear();
    for (final context in _contexts.toList()) {
      context.revoke();
    }
  }

  void _revokeInvalidContexts() {
    for (final context in _contexts.toList()) {
      if (!context._isAdmitted()) context.revoke();
    }
  }

  /// Only the context actually registered by the successful reload may become
  /// active. Validation aliases never participate in this handoff.
  void promoteRuntime(TrustedArtifact identity) {
    final context = _activeContexts[identity];
    if (context == null || context.identity != identity) return;
    requireExecutionContext(context);
    final selected = _selectedByPath(context.path);
    if (selected == null ||
        selected.activationBlocked ||
        selected.identity != identity ||
        selected.revision != context.revision) {
      throw const SourceRuntimeDenied(
        'Runtime selection changed before activation.',
      );
    }
    context.permit = null;
    // Registry hashes preserve raw bytes; parsing normalizes CRLF. The
    // candidate was checked against normalized bytes and the caller verifies
    // the selected raw file before this handoff.
    context.sha256 = selected.sha256;
    requireExecutionContext(context);
  }

  bool hasActiveRuntime(ActiveArtifact artifact) {
    final context = _activeContexts[artifact.identity];
    return context != null &&
        context.identity == artifact.identity &&
        context.path == _artifactPath(artifact) &&
        context.sha256 == artifact.sha256 &&
        context.revision == artifact.revision &&
        context.permit == null &&
        context._isAdmitted();
  }

  void revokeLoadedRuntimes({String? sourceKey}) {
    for (final context in _activeContexts.values.toList()) {
      if (sourceKey == null || context.identity.sourceKey == sourceKey) {
        context.revoke();
      }
    }
  }

  /// Runs source parsing or a source callback inside an exact runtime
  /// admission context. Ordinary App JavaScript does not enter this zone and
  /// therefore retains its existing behavior.
  T runWithExecutionContext<T>(
    SourceRuntimeExecutionContext context,
    T Function() action,
  ) {
    requireExecutionContext(context);
    return runZoned(action, zoneValues: {_executionContextZoneKey: context});
  }

  SourceRuntimeExecutionContext? get currentExecutionContext =>
      Zone.current[_executionContextZoneKey] as SourceRuntimeExecutionContext?;

  SourceRuntimeExecutionContext? executionContextForPath(
    String path, {
    SourceRuntimePermit? permit,
  }) {
    final normalized = _normalizePath(path);
    if (permit != null) {
      return SourceRuntimeExecutionContext._(
        policy: this,
        identity: permit.identity,
        path: normalized,
        sha256: permit.sha256,
        revision: permit.revision,
        epoch: permit.epoch,
        cloudEnabled: permit.cloudEnabled,
        permit: permit,
      );
    }
    final selected = _selectedByPath(normalized);
    if (selected == null) return null;
    return SourceRuntimeExecutionContext._(
      policy: this,
      identity: selected.identity,
      path: normalized,
      sha256: selected.sha256,
      revision: selected.revision,
      epoch: operationEpoch,
      cloudEnabled: cloudEnabled,
    );
  }

  SourceRuntimeExecutionContext executionContextForUnmanaged(
    String path,
    String source,
  ) {
    if (!allowUnmanagedRoot(path) || pendingCloudEnable) {
      throw const SourceRuntimeDenied('Unmanaged source is not admitted.');
    }
    return SourceRuntimeExecutionContext._(
      policy: this,
      identity: TrustedArtifact(
        sourceKey: '__unresolved',
        fileName: p.basename(path),
      ),
      path: _normalizePath(path),
      sha256: sha256.convert(utf8.encode(source)).toString(),
      revision: null,
      epoch: operationEpoch,
      cloudEnabled: false,
      unmanaged: true,
    );
  }

  void requireActiveSourceBytes(
    SourceRuntimeExecutionContext context,
    String source,
  ) {
    requireExecutionContext(context);
    final bytes = File(context.path).readAsBytesSync();
    if (sha256.convert(bytes).toString() != context.sha256 ||
        utf8.decode(bytes).replaceAll('\r\n', '\n') != source) {
      throw const SourceRuntimeDenied(
        'Active source bytes do not match the selected artifact.',
      );
    }
  }

  void registerRuntimeContext(
    String runtimeKey,
    SourceRuntimeExecutionContext context, {
    bool active = true,
  }) {
    requireExecutionContext(context);
    final previousForKey = _runtimeContexts[runtimeKey];
    if (previousForKey != null && !identical(previousForKey, context)) {
      previousForKey.revoke();
    }
    if (active) {
      final previous = _activeContexts[context.identity];
      if (previous != null && !identical(previous, context)) previous.revoke();
      _activeContexts[context.identity] = context;
    }
    _runtimeContexts[runtimeKey] = context;
  }

  void unregisterRuntimeContext(String runtimeKey) {
    _runtimeContexts.remove(runtimeKey)?.revoke();
  }

  SourceRuntimeExecutionContext? contextForRuntimeKey(String runtimeKey) =>
      _runtimeContexts[runtimeKey];

  SourceRuntimeExecutionContext? contextForCode(String source) {
    final match = RegExp(
      r'ComicSource\.sources\.([A-Za-z0-9_]+)',
    ).firstMatch(source);
    return match == null ? null : contextForRuntimeKey(match.group(1)!);
  }

  void requireExecutionContext(SourceRuntimeExecutionContext context) {
    if (!identical(context.policy, this) || !context._isAdmitted()) {
      throw const SourceRuntimeDenied(
        'Source runtime execution was revoked for the current ownership state.',
      );
    }
  }

  SourceRuntimePermit? permitForPath(String path) {
    final normalized = _normalizePath(path);
    for (final permit in _permits) {
      if (permit._allows(normalized, operationEpoch, cloudEnabled)) {
        return permit;
      }
    }
    return null;
  }

  bool validatePermitSource(String path, String source) {
    final permit = permitForPath(_normalizePath(path));
    return permit != null && validateCandidateSource(permit, path, source);
  }

  ActiveArtifact? _selectedByPath(String path) {
    final current = registry;
    if (current == null) return null;
    for (final artifact in current.artifacts) {
      if (_artifactPath(artifact) == path) return artifact;
    }
    return null;
  }

  String _normalizePath(String path) =>
      path.replaceAll('\\', '/').replaceAll(RegExp(r'/+'), '/');

  String _artifactPath(ActiveArtifact artifact) {
    final root = sourceDirectoryPath;
    if (root == null) return _normalizePath(artifact.relativePath);
    return _normalizePath(p.absolute(p.join(root, artifact.relativePath)));
  }

  final _permits = <SourceRuntimePermit>{};
  final _runtimeContexts = <String, SourceRuntimeExecutionContext>{};
  final _activeContexts = <TrustedArtifact, SourceRuntimeExecutionContext>{};
  final _contexts = <SourceRuntimeExecutionContext>{};
}

final _executionContextZoneKey = Object();

class SourceRuntimeExecutionContext {
  SourceRuntimeExecutionContext._({
    required this.policy,
    required this.identity,
    required this.path,
    required this.sha256,
    required this.revision,
    required this.epoch,
    required this.cloudEnabled,
    this.permit,
    this.unmanaged = false,
  }) {
    policy._contexts.add(this);
  }

  final SourceRuntimePolicy policy;
  TrustedArtifact identity;
  final String path;
  String sha256;
  final String? revision;
  final int epoch;
  final bool cloudEnabled;
  final bool unmanaged;
  SourceRuntimePermit? permit;
  bool _revoked = false;
  final _onRevoke = <void Function()>[];

  void bindUnmanagedIdentity(String sourceKey) {
    policy.requireExecutionContext(this);
    if (!unmanaged || identity.sourceKey != '__unresolved') {
      throw const SourceRuntimeDenied('Source identity is already bound.');
    }
    identity = TrustedArtifact(
      sourceKey: sourceKey,
      fileName: identity.fileName,
    );
  }

  void onRevoke(void Function() callback) {
    if (_revoked) {
      callback();
    } else {
      _onRevoke.add(callback);
    }
  }

  void revoke() {
    if (_revoked) return;
    _revoked = true;
    policy._contexts.remove(this);
    policy._activeContexts.removeWhere((_, value) => identical(value, this));
    for (final callback in _onRevoke.toList()) {
      callback();
    }
    _onRevoke.clear();
  }

  bool _isAdmitted() {
    if (_revoked) return false;
    if (epoch != policy.operationEpoch || cloudEnabled != policy.cloudEnabled) {
      return false;
    }
    if (permit != null) {
      return permit!._allows(
            path,
            policy.operationEpoch,
            policy.cloudEnabled,
          ) &&
          permit!.sha256 == sha256;
    }
    if (unmanaged) {
      return !policy.pendingCloudEnable && policy.allowUnmanagedRoot(path);
    }
    final selected = policy._selectedByPath(path);
    if (selected == null ||
        selected.activationBlocked ||
        selected.identity != identity ||
        selected.sha256 != sha256 ||
        selected.revision != revision) {
      return false;
    }
    return policy.canLoadPath(path);
  }
}

class SourceRuntimePermit {
  SourceRuntimePermit._({
    required this.identity,
    required this.path,
    required this.sha256,
    required this.revision,
    required this.epoch,
    required this.cloudEnabled,
  });

  final TrustedArtifact identity;
  final String path;
  final String sha256;
  final String? revision;
  final int epoch;
  final bool cloudEnabled;
  bool _revoked = false;

  bool _allows(String candidatePath, int currentEpoch, bool currentCloud) =>
      !_revoked &&
      path == candidatePath &&
      epoch == currentEpoch &&
      cloudEnabled == currentCloud;
}

class SourceRuntimeDenied implements Exception {
  const SourceRuntimeDenied(this.message);

  final String message;

  @override
  String toString() => message;
}

class SourceMutationDenied extends SourceRuntimeDenied {
  const SourceMutationDenied(super.message);
}

final sourceRuntimePolicy = SourceRuntimePolicy.instance;
