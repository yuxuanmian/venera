import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

export '../tracking/legacy_source_identity.dart' show LegacySourceIdentity;
import '../tracking/legacy_source_identity.dart';
import 'models.dart';

class LegacyInventory {
  const LegacyInventory({
    required this.matched,
    required this.knownExecutableFiles,
    required this.unknownFiles,
    required this.summary,
  });

  final Map<String, File> matched;
  final List<FileSystemEntity> knownExecutableFiles;
  final List<FileSystemEntity> unknownFiles;
  final List<String> summary;

  Set<String> get matchedKeys => matched.keys.toSet();
}

class LegacyCopyEffect {
  const LegacyCopyEffect({
    required this.source,
    required this.target,
    required this.targetKey,
    required this.bytes,
  });

  final File source;
  final File target;
  final String targetKey;
  final List<int> bytes;
}

/// Legacy discovery is deliberately text/file based. It never invokes the
/// JavaScript parser or evaluates a root script.
class LegacyMigration {
  LegacyMigration(this.root);

  final Directory root;

  Future<LegacyInventory> discover({CatalogIndex? catalog}) async {
    final matched = <String, File>{};
    final known = <FileSystemEntity>[];
    final unknown = <FileSystemEntity>[];
    final summary = <String>[];
    final byFile = <String, CatalogSourceEntry>{};
    for (final entry in catalog?.entries ?? const <CatalogSourceEntry>[]) {
      byFile[entry.fileName.toLowerCase()] = entry;
    }

    final registry = File(
      p.join(root.path, '.managed', 'active-artifacts.json'),
    );
    var registryLoaded = false;
    if (await _regular(registry)) {
      try {
        registryLoaded = await _readRegistry(
          registry,
          root: root,
          matched: matched,
          known: known,
        );
      } catch (_) {
        summary.add('旧 registry 无法读取，已忽略');
      }
      known.add(registry);
    }
    // A valid last-known-good registry is an identity hint only. It is used
    // when the primary registry is missing or malformed, and its artifacts
    // still must be present as root files before they can be matched.
    final lastKnownGood = File('${registry.path}.lkg');
    if (!registryLoaded && await _regular(lastKnownGood)) {
      try {
        registryLoaded = await _readRegistry(
          lastKnownGood,
          root: root,
          matched: matched,
          known: known,
        );
      } catch (_) {
        summary.add('旧 registry LKG 无法读取，已忽略');
      }
      known.add(lastKnownGood);
    }

    if (await root.exists()) {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! File ||
            p.extension(entity.path).toLowerCase() != '.js') {
          continue;
        }
        if (known.contains(entity)) {
          continue;
        }
        final name = p.basename(entity.path);
        final exact = byFile[name.toLowerCase()];
        if (exact != null) {
          matched.putIfAbsent(exact.key, () => entity);
          known.add(entity);
          continue;
        }
        final variant = _variantKey(name);
        if (variant != null) {
          matched.putIfAbsent(variant, () => entity);
          known.add(entity);
          continue;
        }
        try {
          final identity = LegacySourceIdentity.fromBytes(
            await entity.readAsBytes(),
          );
          matched.putIfAbsent(identity.sourceKey, () => entity);
          known.add(entity);
        } catch (_) {
          unknown.add(entity);
          summary.add('未识别旧源：$name');
        }
      }
    }
    return LegacyInventory(
      matched: Map.unmodifiable(matched),
      knownExecutableFiles: List.unmodifiable(known),
      unknownFiles: List.unmodifiable(unknown),
      summary: List.unmodifiable(summary),
    );
  }

  Future<bool> _readRegistry(
    File registry, {
    required Directory root,
    required Map<String, File> matched,
    required List<FileSystemEntity> known,
  }) async {
    final json = jsonDecode(await registry.readAsString());
    final artifacts = json is Map ? json['artifacts'] : null;
    if (artifacts is! List) throw const FormatException('artifacts missing');
    for (final value in artifacts) {
      if (value is! Map) continue;
      final key = value['sourceKey'];
      final fileName = value['fileName'];
      if (key is String &&
          RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key) &&
          fileName is String &&
          _safeFileName(fileName)) {
        final file = File(p.join(root.path, fileName));
        if (await _regular(file)) {
          matched[key] = file;
          known.add(file);
        }
      }
    }
    return true;
  }

  Future<LegacyCopyEffect?> prepareCopyEffect({
    required LegacyInventory inventory,
  }) async {
    final multi = inventory.matched['copy_manga_multi'];
    // The multi-account definition can be the only legacy executable left;
    // its user data still needs the old shared copy_manga identity mapped.
    if (multi == null) return null;
    final source = File(p.join(root.path, 'copy_manga.data'));
    final target = File(p.join(root.path, 'copy_manga_multi.data'));
    if (await target.exists() || !await _regular(source)) return null;
    final bytes = await source.readAsBytes();
    // Only copy a structurally valid user-data object. A malformed legacy
    // file must not become the new variant's persisted state during a
    // migration that otherwise succeeds.
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return null;
      Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
    return LegacyCopyEffect(
      source: source,
      target: target,
      targetKey: 'copy_manga_multi',
      bytes: bytes,
    );
  }

  Future<bool> applyCopyEffect(LegacyCopyEffect effect) async {
    if (await effect.target.exists()) return false;
    await effect.target.parent.create(recursive: true);
    final temp = File(
      '${effect.target.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temp.writeAsBytes(effect.bytes, flush: true);
      if (await effect.target.exists()) return false;
      await temp.rename(effect.target.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
    return true;
  }

  /// Cleanup is called only after a new Runtime and appdata commit succeeded.
  /// It is best effort and never removes user data or unknown files.
  Future<List<String>> cleanupAfterSuccess(LegacyInventory inventory) async {
    final remaining = <String>[];
    final targets = <FileSystemEntity>[...inventory.knownExecutableFiles];
    for (final directoryName in ['.managed', '.custom', '.custom-drafts']) {
      final directory = Directory(p.join(root.path, directoryName));
      try {
        if (!await directory.exists() ||
            await FileSystemEntity.type(directory.path, followLinks: false) !=
                FileSystemEntityType.directory) {
          continue;
        }
        await for (final entity in directory.list(followLinks: false)) {
          if (entity is File && _knownExecutionFile(p.basename(entity.path))) {
            targets.add(entity);
          }
        }
      } catch (_) {
        // A disappearing or inaccessible legacy directory is only a cleanup
        // diagnostic. The Runtime has already been published at this point.
        remaining.add(directory.path);
      }
    }
    for (final target in targets) {
      try {
        if (await target.exists()) {
          await target.delete(recursive: target is Directory);
        }
      } catch (_) {
        remaining.add(target.path);
      }
    }
    return remaining;
  }
}

bool _knownExecutionFile(String name) =>
    name == 'active-artifacts.json' ||
    name == 'active-artifacts.json.lkg' ||
    name.endsWith('.js') ||
    name.endsWith('.tmp') ||
    name.endsWith('.bak');

String? _variantKey(String fileName) {
  if (fileName == 'copy_manga_multi_accounts.js') return 'copy_manga_multi';
  if (fileName == 'copy_manga.js') return 'copy_manga';
  return null;
}

bool _safeFileName(String value) =>
    p.basename(value) == value &&
    value.endsWith('.js') &&
    !value.contains('..') &&
    !value.contains('/') &&
    !value.contains('\\');

Future<bool> _regular(File file) async =>
    await file.exists() &&
    await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.file;
