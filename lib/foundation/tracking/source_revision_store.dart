import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart' as win32;

import 'legacy_source_identity.dart';
import 'trusted_catalog.dart';

typedef LegacySourceKeyResolver = FutureOr<String?> Function(File file);
typedef AtomicFileReplacer = Future<void> Function(File source, File target);

const _migrationReasons = {
  'Source identity could not be verified.',
  'Source identity is not a unique static literal.',
  'Duplicate active source identity.',
};

enum ArtifactOrigin { managedCatalog, custom }

class ActiveArtifact {
  const ActiveArtifact({
    required this.sourceKey,
    required this.fileName,
    required this.revision,
    required this.relativePath,
    required this.origin,
    required this.sha256,
    this.cloudCapable = false,
    this.activationBlocked = false,
  });

  final String sourceKey;
  final String fileName;
  final String? revision;
  final String relativePath;
  final ArtifactOrigin origin;
  final String sha256;

  /// Last trusted catalog declaration for this exact artifact. It is only a
  /// capability hint while the Server authority is unavailable; a live
  /// authority always wins during coordinator alignment.
  final bool cloudCapable;

  /// A selected pointer is not execution permission.  This flag survives
  /// restart and keeps an unverified artifact out of every runtime path until
  /// trusted activation or explicit Local recovery succeeds.
  final bool activationBlocked;

  TrustedArtifact get identity =>
      TrustedArtifact(sourceKey: sourceKey, fileName: fileName);

  factory ActiveArtifact.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('invalid active artifact');
    final sourceKey = value['sourceKey'];
    final fileName = value['fileName'];
    final relativePath = value['relativePath'];
    final originValue = value['origin'];
    final hash = value['sha256'];
    if (sourceKey is! String ||
        sourceKey.trim().isEmpty ||
        fileName is! String ||
        fileName.isEmpty ||
        relativePath is! String ||
        originValue is! String ||
        hash is! String ||
        hash.isEmpty) {
      throw const FormatException('invalid active artifact');
    }
    final origin = switch (originValue) {
      'managed-catalog' => ArtifactOrigin.managedCatalog,
      'custom' => ArtifactOrigin.custom,
      _ => throw const FormatException('invalid artifact origin'),
    };
    final revisionValue = value['revision'];
    final revision = revisionValue == null
        ? null
        : revisionValue is String &&
              TrustedCatalog.revisionPattern.hasMatch(revisionValue)
        ? revisionValue
        : throw const FormatException('invalid artifact revision');
    if (origin == ArtifactOrigin.managedCatalog && revision == null) {
      throw const FormatException('managed artifact requires revision');
    }
    SourceRevisionStore.validateSafeRelativePath(relativePath);
    if (p.basename(fileName) != fileName || !fileName.endsWith('.js')) {
      throw const FormatException('invalid artifact file name');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const FormatException('invalid artifact hash');
    }
    final cloudCapableValue = value['cloudCapable'];
    if (cloudCapableValue != null && cloudCapableValue is! bool) {
      throw const FormatException('invalid artifact capability');
    }
    final activationBlockedValue = value['activationBlocked'];
    if (activationBlockedValue != null && activationBlockedValue is! bool) {
      throw const FormatException('invalid artifact activation state');
    }
    return ActiveArtifact(
      sourceKey: sourceKey.trim(),
      fileName: fileName,
      revision: revision,
      relativePath: relativePath,
      origin: origin,
      sha256: hash,
      cloudCapable: cloudCapableValue == true,
      activationBlocked: activationBlockedValue == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'sourceKey': sourceKey,
    'fileName': fileName,
    'revision': revision,
    'relativePath': relativePath,
    'origin': origin == ArtifactOrigin.managedCatalog
        ? 'managed-catalog'
        : 'custom',
    'sha256': sha256,
    if (cloudCapable) 'cloudCapable': true,
    if (activationBlocked) 'activationBlocked': true,
  };

  ActiveArtifact copyWith({
    String? revision,
    bool clearRevision = false,
    String? relativePath,
    ArtifactOrigin? origin,
    String? sha256,
    bool? cloudCapable,
    bool? activationBlocked,
  }) => ActiveArtifact(
    sourceKey: sourceKey,
    fileName: fileName,
    revision: clearRevision ? null : revision ?? this.revision,
    relativePath: relativePath ?? this.relativePath,
    origin: origin ?? this.origin,
    sha256: sha256 ?? this.sha256,
    cloudCapable: cloudCapable ?? this.cloudCapable,
    activationBlocked: activationBlocked ?? this.activationBlocked,
  );

  @override
  bool operator ==(Object other) =>
      other is ActiveArtifact &&
      other.sourceKey == sourceKey &&
      other.fileName == fileName &&
      other.revision == revision &&
      other.relativePath == relativePath &&
      other.origin == origin &&
      other.sha256 == sha256 &&
      other.cloudCapable == cloudCapable &&
      other.activationBlocked == activationBlocked;

  @override
  int get hashCode => Object.hash(
    sourceKey,
    fileName,
    revision,
    relativePath,
    origin,
    sha256,
    cloudCapable,
    activationBlocked,
  );
}

class ActiveArtifactRegistry {
  const ActiveArtifactRegistry({
    this.schemaVersion = 1,
    this.artifacts = const <ActiveArtifact>[],
    this.recoverableArtifacts = const <ActiveArtifact>[],
    this.migrationDiagnostics = const <String, String>{},
  });

  final int schemaVersion;
  final List<ActiveArtifact> artifacts;
  final List<ActiveArtifact> recoverableArtifacts;
  final Map<String, String> migrationDiagnostics;

  factory ActiveArtifactRegistry.fromJson(Object? value) {
    if (value is! Map ||
        value['schemaVersion'] != 1 ||
        value['artifacts'] is! List) {
      throw const FormatException('invalid active-artifacts registry');
    }
    final artifacts = (value['artifacts'] as List)
        .map(ActiveArtifact.fromJson)
        .toList();
    final seen = <String>{};
    for (final artifact in artifacts) {
      final key = '${artifact.sourceKey}\u0000${artifact.fileName}';
      if (!seen.add(key)) {
        throw const FormatException('duplicate active artifact');
      }
    }
    final recoverableValue = value['recoverableArtifacts'];
    if (recoverableValue != null && recoverableValue is! List) {
      throw const FormatException('invalid recoverable artifacts');
    }
    final recoverableArtifacts =
        (recoverableValue as List?)?.map(ActiveArtifact.fromJson).toList() ??
        <ActiveArtifact>[];
    final recoverableSeen = <String>{};
    for (final artifact in recoverableArtifacts) {
      if (artifact.origin != ArtifactOrigin.custom ||
          artifact.revision != null) {
        throw const FormatException('invalid recoverable artifact origin');
      }
      final key =
          '${artifact.sourceKey}\u0000${artifact.fileName}\u0000${artifact.relativePath}\u0000${artifact.sha256}';
      if (!recoverableSeen.add(key)) {
        throw const FormatException('duplicate recoverable artifact');
      }
    }
    final diagnostics = <String, String>{};
    final diagnosticValue = value['migrationDiagnostics'];
    if (diagnosticValue != null && diagnosticValue is! Map) {
      throw const FormatException('invalid migration diagnostics');
    }
    if (diagnosticValue is Map) {
      for (final entry in diagnosticValue.entries) {
        final name = entry.key;
        if (name is! String ||
            p.basename(name) != name ||
            !name.endsWith('.js') ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
          throw const FormatException('invalid migration diagnostic file');
        }
        SourceRevisionStore.validateSafeRelativePath(name);
        diagnostics[name] = _migrationReasons.contains(entry.value)
            ? entry.value as String
            : 'Source identity could not be verified.';
      }
    }
    return ActiveArtifactRegistry(
      schemaVersion: 1,
      artifacts: List.unmodifiable(artifacts),
      recoverableArtifacts: List.unmodifiable(recoverableArtifacts),
      migrationDiagnostics: Map.unmodifiable(diagnostics),
    );
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'artifacts': artifacts.map((e) => e.toJson()).toList(),
    if (migrationDiagnostics.isNotEmpty)
      'migrationDiagnostics': migrationDiagnostics,
    if (recoverableArtifacts.isNotEmpty)
      'recoverableArtifacts': recoverableArtifacts
          .map((e) => e.toJson())
          .toList(),
  };

  ActiveArtifactRegistry copyWith({
    int? schemaVersion,
    List<ActiveArtifact>? artifacts,
    List<ActiveArtifact>? recoverableArtifacts,
    Map<String, String>? migrationDiagnostics,
  }) => ActiveArtifactRegistry(
    schemaVersion: schemaVersion ?? this.schemaVersion,
    artifacts: List.unmodifiable(artifacts ?? this.artifacts),
    recoverableArtifacts: List.unmodifiable(
      recoverableArtifacts ?? this.recoverableArtifacts,
    ),
    migrationDiagnostics: Map.unmodifiable(
      migrationDiagnostics ?? this.migrationDiagnostics,
    ),
  );

  ActiveArtifact? find(String sourceKey, String fileName) {
    for (final artifact in artifacts) {
      if (artifact.sourceKey == sourceKey && artifact.fileName == fileName) {
        return artifact;
      }
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is ActiveArtifactRegistry &&
      other.schemaVersion == schemaVersion &&
      _listEquals(other.artifacts, artifacts) &&
      _listEquals(other.recoverableArtifacts, recoverableArtifacts) &&
      other.migrationDiagnostics.length == migrationDiagnostics.length &&
      migrationDiagnostics.entries.every(
        (e) => other.migrationDiagnostics[e.key] == e.value,
      );

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    Object.hashAll(artifacts),
    Object.hashAll(recoverableArtifacts),
  );

  static bool _listEquals(
    List<ActiveArtifact> left,
    List<ActiveArtifact> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}

class SourceRevisionStore {
  SourceRevisionStore(this.sourceDirectory, {this.atomicReplace});

  final Directory sourceDirectory;
  final AtomicFileReplacer? atomicReplace;

  Directory get managedDirectory =>
      Directory(p.join(sourceDirectory.path, '.managed'));

  File get registryFile =>
      File(p.join(managedDirectory.path, 'active-artifacts.json'));

  /// Durable copy of the registry that was active before the last pointer
  /// replacement. It is kept beside the pointer so recovery never depends on
  /// a process-local singleton surviving a crash.
  File get lastKnownGoodFile =>
      File(p.join(managedDirectory.path, 'active-artifacts.json.lkg'));

  Future<ActiveArtifactRegistry?> load() async {
    if (!await registryFile.exists()) return null;
    try {
      return ActiveArtifactRegistry.fromJson(
        jsonDecode(await registryFile.readAsString()),
      );
    } catch (error) {
      final recovered = await loadLastKnownGood();
      if (recovered != null) return recovered;
      throw FormatException('active-artifacts registry is invalid: $error');
    }
  }

  Future<ActiveArtifactRegistry?> loadLastKnownGood() async {
    if (!await lastKnownGoodFile.exists()) return null;
    try {
      return ActiveArtifactRegistry.fromJson(
        jsonDecode(await lastKnownGoodFile.readAsString()),
      );
    } catch (_) {
      return null;
    }
  }

  /// Creates a registry for existing root scripts without moving or deleting
  /// them. These entries are custom and remain outside managed revisions.
  Future<ActiveArtifactRegistry> loadOrMigrate({
    LegacySourceKeyResolver? resolveSourceKey,
    bool cloudEnabled = false,
  }) async {
    await sourceDirectory.create(recursive: true);
    final current = await load();
    if (current != null) {
      return _discoverUnregisteredRootSources(
        current,
        resolveSourceKey: resolveSourceKey,
        cloudEnabled: cloudEnabled,
      );
    }
    return _discoverUnregisteredRootSources(
      const ActiveArtifactRegistry(),
      resolveSourceKey: resolveSourceKey,
      cloudEnabled: cloudEnabled,
      persistEmpty: true,
    );
  }

  /// Persists the identity of a legacy root only after the caller has
  /// independently verified it.  This is intentionally a data-only helper:
  /// it never parses or executes JavaScript and never acquires the coordinator
  /// lock.  The caller must hold that lock and [requireCurrent] fences every
  /// asynchronous boundary.
  Future<ActiveArtifactRegistry> registerVerifiedLegacyRoot({
    required String fileName,
    required String sourceKey,
    required List<int> expectedBytes,
    required void Function() requireCurrent,
  }) async {
    requireCurrent();
    if (fileName.isEmpty ||
        fileName != p.basename(fileName) ||
        fileName.contains('/') ||
        fileName.contains('\\') ||
        !fileName.endsWith('.js') ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(fileName)) {
      throw const FormatException('legacy source file name is invalid');
    }
    validateSafeRelativePath(fileName);
    if (sourceKey.isEmpty || !RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(sourceKey)) {
      throw const FormatException('legacy source key is invalid');
    }

    final latest = await load() ?? const ActiveArtifactRegistry();
    requireCurrent();
    final target = fileForRelativePath(fileName);
    final targetType = await FileSystemEntity.type(
      target.path,
      followLinks: false,
    );
    requireCurrent();
    if (targetType == FileSystemEntityType.link) {
      throw const FormatException('legacy source path must not be a link');
    }

    final identity = TrustedArtifact(sourceKey: sourceKey, fileName: fileName);
    if (latest.artifacts.any(
          (artifact) =>
              p.normalize(artifact.relativePath) == p.normalize(fileName),
        ) ||
        latest.recoverableArtifacts.any(
          (artifact) =>
              p.normalize(artifact.relativePath) == p.normalize(fileName),
        )) {
      throw const FormatException('legacy source path is already registered');
    }
    if (latest.artifacts.any((artifact) => artifact.identity == identity) ||
        latest.recoverableArtifacts.any(
          (artifact) => artifact.identity == identity,
        )) {
      throw const FormatException(
        'legacy source identity is already registered',
      );
    }

    final actualBytes = await target.readAsBytes();
    requireCurrent();
    if (!_bytesEqual(actualBytes, expectedBytes)) {
      throw const FormatException(
        'legacy source bytes changed during verification',
      );
    }
    final hash = sha256.convert(actualBytes).toString();
    final active = ActiveArtifact(
      sourceKey: sourceKey,
      fileName: fileName,
      revision: null,
      relativePath: fileName,
      origin: ArtifactOrigin.custom,
      sha256: hash,
      cloudCapable: false,
      activationBlocked: true,
    );
    final recovery = active.copyWith(activationBlocked: false);
    final recoveries = [
      ...latest.recoverableArtifacts,
      if (!latest.recoverableArtifacts.any(
        (artifact) =>
            artifact.sourceKey == recovery.sourceKey &&
            artifact.fileName == recovery.fileName &&
            artifact.relativePath == recovery.relativePath &&
            artifact.sha256 == recovery.sha256,
      ))
        recovery,
    ];
    final diagnostics = Map<String, String>.from(latest.migrationDiagnostics)
      ..remove(fileName);
    final next = latest.copyWith(
      artifacts: [...latest.artifacts, active],
      recoverableArtifacts: recoveries,
      migrationDiagnostics: diagnostics,
    );
    await save(next);
    requireCurrent();
    return next;
  }

  /// Diagnostics from the most recent no-execution legacy discovery pass.
  /// Unresolvable files remain untouched and are intentionally not inserted as
  /// guessed registry entries.
  List<String> migrationDiagnostics = const <String>[];

  Future<ActiveArtifactRegistry> _discoverUnregisteredRootSources(
    ActiveArtifactRegistry registry, {
    required LegacySourceKeyResolver? resolveSourceKey,
    required bool cloudEnabled,
    bool persistEmpty = false,
  }) async {
    migrationDiagnostics = <String>[];
    final diagnostics = <String, String>{};
    void diagnose(String name, String reason) {
      diagnostics[name] = reason;
      migrationDiagnostics.add('$name: $reason');
    }

    final knownPaths = <String>{
      for (final artifact in registry.artifacts) artifact.relativePath,
      for (final artifact in registry.recoverableArtifacts)
        artifact.relativePath,
    };
    final knownIdentities = <TrustedArtifact>{
      for (final artifact in registry.artifacts) artifact.identity,
    };
    final additions = <ActiveArtifact>[];
    for (final entity in sourceDirectory.listSync()) {
      if (entity is! File || !entity.path.endsWith('.js')) continue;
      final fileName = p.basename(entity.path);
      if (knownPaths.contains(fileName)) continue;
      final bytes = await entity.readAsBytes();
      String? sourceKey;
      try {
        sourceKey = cloudEnabled
            ? LegacySourceIdentity.fromBytes(bytes).sourceKey
            : await resolveSourceKey?.call(entity);
      } on FormatException {
        diagnose(fileName, 'Source identity is not a unique static literal.');
        continue;
      } catch (_) {
        diagnose(fileName, 'Source identity could not be verified.');
        continue;
      }
      if (sourceKey == null || sourceKey.trim().isEmpty) {
        diagnose(fileName, 'Source identity could not be verified.');
        continue;
      }
      final artifact = ActiveArtifact(
        sourceKey: sourceKey.trim(),
        fileName: fileName,
        revision: null,
        relativePath: fileName,
        origin: ArtifactOrigin.custom,
        sha256: sha256.convert(bytes).toString(),
      );
      if (knownIdentities.contains(artifact.identity) ||
          additions.any((item) => item.identity == artifact.identity)) {
        diagnose(fileName, 'Duplicate active source identity.');
        continue;
      }
      additions.add(artifact);
    }
    final result = registry.copyWith(
      artifacts: [...registry.artifacts, ...additions],
      migrationDiagnostics: diagnostics,
    );
    if (result == registry && !persistEmpty) return registry;
    await save(result);
    return result;
  }

  Future<void> save(
    ActiveArtifactRegistry registry, {
    bool preserveLastKnownGood = false,
  }) async {
    await managedDirectory.create(recursive: true);
    ActiveArtifactRegistry? previous;
    if (!preserveLastKnownGood && await registryFile.exists()) {
      try {
        previous = ActiveArtifactRegistry.fromJson(
          jsonDecode(await registryFile.readAsString()),
        );
      } catch (_) {
        previous = await loadLastKnownGood();
      }
    }
    if (previous != null) {
      final backupTemp = File(
        p.join(
          managedDirectory.path,
          'active-artifacts.json.lkg.${DateTime.now().microsecondsSinceEpoch}.tmp',
        ),
      );
      await backupTemp.writeAsString(
        jsonEncode(previous.toJson()),
        flush: true,
      );
      try {
        await _replaceAtomically(backupTemp, lastKnownGoodFile);
      } catch (_) {
        await _deleteIfExists(backupTemp);
        rethrow;
      }
    }
    final temp = File(
      p.join(
        managedDirectory.path,
        'active-artifacts.json.${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    await temp.writeAsString(jsonEncode(registry.toJson()), flush: true);
    try {
      await _replaceAtomically(temp, registryFile);
    } catch (_) {
      await _deleteIfExists(temp);
      rethrow;
    }
  }

  /// Restores a previously captured registry as both the active pointer and
  /// the restart-safe recovery copy. Unlike [save], this method must not
  /// preserve the currently selected pointer as LKG: callers use it after an
  /// activation race has proved that the prior runtime is the only safe pair.
  Future<void> restore(ActiveArtifactRegistry registry) async {
    await managedDirectory.create(recursive: true);
    final encoded = jsonEncode(registry.toJson());
    final lkgTemp = File(
      p.join(
        managedDirectory.path,
        'active-artifacts.json.lkg.restore.${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    await lkgTemp.writeAsString(encoded, flush: true);
    try {
      await _replaceAtomically(lkgTemp, lastKnownGoodFile);
    } catch (_) {
      await _deleteIfExists(lkgTemp);
      rethrow;
    }
    final pointerTemp = File(
      p.join(
        managedDirectory.path,
        'active-artifacts.json.restore.${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    await pointerTemp.writeAsString(encoded, flush: true);
    try {
      await _replaceAtomically(pointerTemp, registryFile);
    } catch (_) {
      await _deleteIfExists(pointerTemp);
      rethrow;
    }
  }

  Future<ActiveArtifact> writeManagedArtifact(
    String revision,
    String fileName,
    List<int> bytes, {
    String? sourceKey,
  }) async {
    if (!TrustedCatalog.revisionPattern.hasMatch(revision)) {
      throw const FormatException('revision must be an immutable full commit');
    }
    if (p.basename(fileName) != fileName || !fileName.endsWith('.js')) {
      throw const FormatException('managed artifact file name is invalid');
    }
    final relativePath = p.posix.join('.managed', revision, fileName);
    validateSafeRelativePath(relativePath);
    final target = fileForRelativePath(relativePath);
    await target.parent.create(recursive: true);
    final temp = File(
      '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temp.writeAsBytes(bytes, flush: true);
    try {
      await _replaceAtomically(temp, target);
    } catch (_) {
      await _deleteIfExists(temp);
      rethrow;
    }
    return ActiveArtifact(
      sourceKey: sourceKey ?? p.basenameWithoutExtension(fileName),
      fileName: fileName,
      revision: revision,
      relativePath: relativePath,
      origin: ArtifactOrigin.managedCatalog,
      sha256: sha256.convert(bytes).toString(),
    );
  }

  File fileForRelativePath(String relativePath) {
    validateSafeRelativePath(relativePath);
    final root = p.absolute(sourceDirectory.path);
    final target = p.absolute(p.join(root, relativePath));
    final relative = p.relative(target, from: root);
    if (relative == '..' || relative.startsWith('..${p.separator}')) {
      throw const FormatException('path escapes source directory');
    }
    return File(target);
  }

  Future<List<int>> readBytes(ActiveArtifact artifact) async {
    final file = fileForRelativePath(artifact.relativePath);
    final bytes = await file.readAsBytes();
    final actual = sha256.convert(bytes).toString();
    if (actual != artifact.sha256) {
      throw const FormatException('active artifact hash mismatch');
    }
    return bytes;
  }

  List<int> readBytesSync(ActiveArtifact artifact) {
    final file = fileForRelativePath(artifact.relativePath);
    final bytes = file.readAsBytesSync();
    final actual = sha256.convert(bytes).toString();
    if (actual != artifact.sha256) {
      throw const FormatException('active artifact hash mismatch');
    }
    return bytes;
  }

  /// Replaces an already selected artifact through the same temporary-file
  /// and same-filesystem atomic primitive used by managed activation.
  /// Callers persist the returned hash in the registry only after the bytes
  /// have been written successfully.
  Future<ActiveArtifact> replaceArtifactBytes(
    ActiveArtifact artifact,
    List<int> bytes,
  ) async {
    final target = fileForRelativePath(artifact.relativePath);
    await _writeAtomically(target, bytes);
    return artifact.copyWith(sha256: sha256.convert(bytes).toString());
  }

  Future<ActiveArtifactRegistry> detachForEdit(
    ActiveArtifact artifact,
    ActiveArtifactRegistry registry,
  ) async {
    final bytes = await readBytes(artifact);
    var fileName = artifact.fileName;
    var target = fileForRelativePath(fileName);
    if (await target.exists() &&
        target.path != fileForRelativePath(artifact.relativePath).path) {
      fileName = 'custom_$fileName';
      target = fileForRelativePath(fileName);
    }
    await _writeAtomically(target, bytes);
    final detached = artifact.copyWith(
      clearRevision: true,
      relativePath: fileName,
      origin: ArtifactOrigin.custom,
      cloudCapable: false,
    );
    final artifacts = [
      for (final item in registry.artifacts)
        if (item != artifact) item,
      detached,
    ];
    final result = registry.copyWith(artifacts: artifacts);
    await save(result);
    return result;
  }

  /// Marks one selected artifact as inactive before a Cloud takeover starts
  /// and records the original custom bytes as an explicit recovery version.
  /// The hash is verified before the registry is changed, so an edited or
  /// missing file can never be silently accepted as recovery data.
  Future<ActiveArtifactRegistry> prepareForCloudTakeover(
    TrustedArtifact identity,
  ) async {
    final registry = await load() ?? const ActiveArtifactRegistry();
    final active = registry.find(identity.sourceKey, identity.fileName);
    if (active == null) {
      throw const FormatException('artifact is not active');
    }
    ActiveArtifact? recovery;
    if (active.origin == ArtifactOrigin.custom || active.revision == null) {
      // Custom recovery is user data, so verify its persisted hash before
      // recording the exact path as recoverable.  A missing or changed file
      // is still blocked durably; its bytes are never re-hashed into trust.
      recovery = active.copyWith(
        clearRevision: true,
        origin: ArtifactOrigin.custom,
        cloudCapable: false,
        activationBlocked: false,
      );
      try {
        await readBytes(recovery);
      } catch (_) {
        final blocked = registry.copyWith(
          artifacts: [
            for (final item in registry.artifacts)
              if (item.identity == identity)
                item.copyWith(activationBlocked: true)
              else
                item,
          ],
        );
        await save(blocked);
        rethrow;
      }
    }
    final recoveries = [...registry.recoverableArtifacts];
    final recoverable = recovery;
    if (recoverable != null &&
        !recoveries.any(
          (item) =>
              item.sourceKey == recoverable.sourceKey &&
              item.fileName == recoverable.fileName &&
              item.relativePath == recoverable.relativePath &&
              item.sha256 == recoverable.sha256,
        )) {
      recoveries.add(recoverable);
    }
    final next = registry.copyWith(
      artifacts: [
        for (final item in registry.artifacts)
          if (item.identity == identity)
            item.copyWith(activationBlocked: true)
          else
            item,
      ],
      recoverableArtifacts: recoveries,
    );
    await save(next);
    return next;
  }

  Future<ActiveArtifactRegistry> setActivationBlocked(
    TrustedArtifact identity,
    bool blocked, {
    bool preserveLastKnownGood = false,
  }) async {
    final registry = await load() ?? const ActiveArtifactRegistry();
    final active = registry.find(identity.sourceKey, identity.fileName);
    if (active == null) throw const FormatException('artifact is not active');
    final next = registry.copyWith(
      artifacts: [
        for (final item in registry.artifacts)
          if (item.identity == identity)
            item.copyWith(activationBlocked: blocked)
          else
            item,
      ],
    );
    await save(next, preserveLastKnownGood: preserveLastKnownGood);
    return next;
  }

  Future<ActiveArtifact> writeCustomWorkingCopy(
    ActiveArtifact identity,
    List<int> bytes,
  ) async {
    final safeName = identity.fileName;
    if (p.basename(safeName) != safeName || !safeName.endsWith('.js')) {
      throw const FormatException('custom artifact file name is invalid');
    }
    final relativePath = p.posix.join(
      '.custom',
      '${DateTime.now().microsecondsSinceEpoch}-$safeName',
    );
    validateSafeRelativePath(relativePath);
    final target = fileForRelativePath(relativePath);
    await _writeAtomically(target, bytes);
    return ActiveArtifact(
      sourceKey: identity.sourceKey,
      fileName: identity.fileName,
      revision: null,
      relativePath: relativePath,
      origin: ArtifactOrigin.custom,
      sha256: sha256.convert(bytes).toString(),
      cloudCapable: false,
    );
  }

  static void validateSafeRelativePath(String value) {
    if (value.trim().isEmpty || value.contains('\\') || p.isAbsolute(value)) {
      throw const FormatException('path must be relative');
    }
    final normalized = p.normalize(value);
    if (normalized == '..' || normalized.startsWith('..${p.separator}')) {
      throw const FormatException('path escapes source directory');
    }
  }

  Future<void> _writeAtomically(File target, List<int> bytes) async {
    await target.parent.create(recursive: true);
    final temp = File(
      '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temp.writeAsBytes(bytes, flush: true);
    try {
      await _replaceAtomically(temp, target);
    } catch (_) {
      await _deleteIfExists(temp);
      rethrow;
    }
  }

  Future<void> _replaceAtomically(File source, File target) async {
    if (atomicReplace != null) {
      await atomicReplace!(source, target);
      return;
    }
    if (Platform.isWindows) {
      final sourcePath = source.path.toNativeUtf16();
      final targetPath = target.path.toNativeUtf16();
      try {
        final result = win32.MoveFileEx(
          sourcePath,
          targetPath,
          win32.MOVEFILE_REPLACE_EXISTING | win32.MOVEFILE_WRITE_THROUGH,
        );
        if (result == 0) {
          throw OSError('MoveFileExW failed', win32.GetLastError());
        }
      } finally {
        calloc.free(sourcePath);
        calloc.free(targetPath);
      }
      return;
    }
    // rename is the same-filesystem atomic replacement primitive on POSIX.
    await source.rename(target.path);
  }

  Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  static bool _bytesEqual(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}
