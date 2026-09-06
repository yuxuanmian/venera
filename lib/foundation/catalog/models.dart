import 'dart:convert';

import 'package:crypto/crypto.dart';

const catalogSchemaVersion = 1;
const catalogMaxIndexBytes = 2 << 20;
const catalogMaxSourceBytes = 5 << 20;
const catalogMaxTotalSourceBytes = 64 << 20;
const catalogMaxSources = 256;

class CatalogFormatException implements Exception {
  const CatalogFormatException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null ? message : '$message: $cause';
}

class CatalogPointer {
  const CatalogPointer({
    required this.catalogId,
    required this.revision,
    required this.indexUrl,
  });

  final String catalogId;
  final String revision;
  final String indexUrl;

  factory CatalogPointer.fromJson(Map<String, dynamic> json) {
    return CatalogPointer(
      catalogId: _requiredString(json, 'catalogId'),
      revision: _requiredString(json, 'revision'),
      indexUrl: _requiredString(json, 'indexUrl'),
    )..validate();
  }

  /// Decodes the App-facing Authority response. The wire response calls the
  /// revision `activeRevision`; it is deliberately not used elsewhere.
  factory CatalogPointer.fromAuthorityJson(Map<String, dynamic> json) {
    final catalogId = _requiredString(json, 'catalogId');
    final revision = _requiredString(json, 'activeRevision');
    final indexUrl = _requiredString(json, 'indexUrl');
    return CatalogPointer(
      catalogId: catalogId,
      revision: revision,
      indexUrl: indexUrl,
    )..validate();
  }

  Map<String, dynamic> toJson() => {
    'catalogId': catalogId,
    'revision': revision,
    'indexUrl': indexUrl,
  };

  String get identity => '$catalogId@$revision';

  bool sameIdentity(CatalogPointer other) =>
      catalogId == other.catalogId && revision == other.revision;

  void validate() {
    if (!RegExp(r'^[a-z0-9_.-]+/[a-z0-9_.-]+$').hasMatch(catalogId) ||
        catalogId != catalogId.toLowerCase()) {
      throw const CatalogFormatException(
        'catalogId must be lowercase owner/repo',
      );
    }
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(revision)) {
      throw const CatalogFormatException(
        'revision must be a 40-character lowercase SHA-1',
      );
    }
    final uri = Uri.tryParse(indexUrl);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'raw.githubusercontent.com' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw const CatalogFormatException(
        'indexUrl is not a pinned raw GitHub URL',
      );
    }
    final parts = uri.pathSegments;
    final idParts = catalogId.split('/');
    if (parts.length != 4 ||
        parts.last != 'index.json' ||
        parts[0] != idParts[0] ||
        parts[1] != idParts[1] ||
        parts[2] != revision) {
      throw const CatalogFormatException(
        'indexUrl does not match catalog identity',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is CatalogPointer &&
      catalogId == other.catalogId &&
      revision == other.revision &&
      indexUrl == other.indexUrl;

  @override
  int get hashCode => Object.hash(catalogId, revision, indexUrl);
}

class CatalogSourceEntry {
  const CatalogSourceEntry({
    required this.name,
    required this.key,
    required this.fileName,
    required this.version,
    this.description,
  });

  final String name;
  final String key;
  final String fileName;
  final String version;
  final String? description;

  factory CatalogSourceEntry.fromJson(Object? value) {
    if (value is! Map) {
      throw const CatalogFormatException('index entry must be an object');
    }
    final json = Map<String, dynamic>.from(value);
    final description = json['description'];
    if (description != null && description is! String) {
      throw const CatalogFormatException('description must be a string');
    }
    final entry = CatalogSourceEntry(
      name: _requiredString(json, 'name'),
      key: _requiredString(json, 'key'),
      fileName: _requiredString(json, 'fileName'),
      version: _requiredString(json, 'version'),
      description: description as String?,
    );
    entry.validate();
    return entry;
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'fileName': fileName,
    'key': key,
    'version': version,
    if (description != null) 'description': description,
  };

  void validate() {
    if (name.isEmpty || version.isEmpty) {
      throw const CatalogFormatException(
        'source name and version are required',
      );
    }
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key)) {
      throw CatalogFormatException('invalid source key: $key');
    }
    if (!RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]*\.js$').hasMatch(fileName) ||
        fileName.contains('/') ||
        fileName.contains('\\') ||
        fileName.contains('..') ||
        fileName.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      throw CatalogFormatException('invalid source filename: $fileName');
    }
  }
}

class CatalogIndex {
  CatalogIndex(Iterable<CatalogSourceEntry> entries)
    : entries = List.unmodifiable(entries) {
    if (this.entries.length > catalogMaxSources) {
      throw const CatalogFormatException('index contains too many sources');
    }
    final keys = <String>{};
    final files = <String>{};
    for (final entry in this.entries) {
      entry.validate();
      if (!keys.add(entry.key)) {
        throw CatalogFormatException('duplicate source key: ${entry.key}');
      }
      if (!files.add(entry.fileName.toLowerCase())) {
        throw CatalogFormatException(
          'duplicate source filename: ${entry.fileName}',
        );
      }
    }
  }

  final List<CatalogSourceEntry> entries;

  factory CatalogIndex.fromJson(Object? value) {
    if (value is! List) {
      throw const CatalogFormatException('index must be a JSON array');
    }
    return CatalogIndex(value.map(CatalogSourceEntry.fromJson));
  }

  factory CatalogIndex.fromBytes(List<int> bytes) {
    if (bytes.length > catalogMaxIndexBytes) {
      throw const CatalogFormatException('index exceeds maximum size');
    }
    try {
      return CatalogIndex.fromJson(jsonDecode(utf8.decode(bytes)));
    } on CatalogFormatException {
      rethrow;
    } catch (error) {
      throw CatalogFormatException('index is invalid JSON', error);
    }
  }

  List<Map<String, dynamic>> toJson() =>
      entries.map((entry) => entry.toJson()).toList(growable: false);

  Set<String> get keys => entries.map((entry) => entry.key).toSet();

  CatalogSourceEntry? find(String key) => entries
      .cast<CatalogSourceEntry?>()
      .firstWhere((entry) => entry?.key == key, orElse: () => null);
}

class CatalogLastAuthority {
  const CatalogLastAuthority({
    required this.catalog,
    required this.serverUrl,
    required this.checkedAt,
  });

  final CatalogPointer catalog;
  final String serverUrl;
  final DateTime checkedAt;

  factory CatalogLastAuthority.fromJson(Map<String, dynamic> json) =>
      CatalogLastAuthority(
        catalog: CatalogPointer.fromJson(_requiredMap(json, 'catalog')),
        serverUrl: _requiredString(json, 'serverUrl'),
        checkedAt: _parseDate(json, 'checkedAt'),
      );

  Map<String, dynamic> toJson() => {
    'catalog': catalog.toJson(),
    'serverUrl': serverUrl,
    'checkedAt': checkedAt.toUtc().toIso8601String(),
  };
}

class AppCatalogState {
  const AppCatalogState({
    this.schemaVersion = catalogSchemaVersion,
    this.active,
    this.lkg,
    this.lastAuthority,
  });

  final int schemaVersion;
  final CatalogPointer? active;
  final CatalogPointer? lkg;
  final CatalogLastAuthority? lastAuthority;

  factory AppCatalogState.fromJson(Object? value) {
    if (value is! Map) {
      throw const CatalogFormatException('catalogRuntime must be an object');
    }
    final json = Map<String, dynamic>.from(value);
    final schema = json['schemaVersion'];
    if (schema != catalogSchemaVersion) {
      throw const CatalogFormatException('unsupported catalogRuntime schema');
    }
    return AppCatalogState(
      schemaVersion: schema as int,
      active: _optionalPointer(json['active']),
      lkg: _optionalPointer(json['lkg']),
      lastAuthority: _optionalLastAuthority(json['lastAuthority']),
    );
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'active': active?.toJson(),
    'lkg': lkg?.toJson(),
    'lastAuthority': lastAuthority?.toJson(),
  };
}

class CatalogSnapshotFile {
  const CatalogSnapshotFile({
    required this.sourceKey,
    required this.fileName,
    required this.size,
    required this.sha256,
  });

  final String sourceKey;
  final String fileName;
  final int size;
  final String sha256;

  factory CatalogSnapshotFile.fromJson(Object? value) {
    if (value is! Map) {
      throw const CatalogFormatException('snapshot file must be an object');
    }
    final json = Map<String, dynamic>.from(value);
    final result = CatalogSnapshotFile(
      sourceKey: _requiredString(json, 'sourceKey'),
      fileName: _requiredString(json, 'fileName'),
      size: _requiredInt(json, 'size'),
      sha256: _requiredString(json, 'sha256'),
    );
    if (result.size < 0 || !RegExp(r'^[0-9a-f]{64}$').hasMatch(result.sha256)) {
      throw const CatalogFormatException('invalid snapshot file digest');
    }
    return result;
  }

  Map<String, dynamic> toJson() => {
    'sourceKey': sourceKey,
    'fileName': fileName,
    'size': size,
    'sha256': sha256,
  };
}

class CatalogSnapshotManifest {
  const CatalogSnapshotManifest({
    required this.pointer,
    required this.indexSha256,
    required this.files,
    this.schemaVersion = catalogSchemaVersion,
  });

  final int schemaVersion;
  final CatalogPointer pointer;
  final String indexSha256;
  final List<CatalogSnapshotFile> files;

  factory CatalogSnapshotManifest.fromJson(Map<String, dynamic> json) {
    final schema = json['schemaVersion'];
    if (schema != catalogSchemaVersion) {
      throw const CatalogFormatException('unsupported snapshot schema');
    }
    final files = json['files'];
    if (files is! List) {
      throw const CatalogFormatException('snapshot files must be an array');
    }
    final result = CatalogSnapshotManifest(
      schemaVersion: schema as int,
      pointer: CatalogPointer.fromJson(_requiredMap(json, 'catalog')),
      indexSha256: _requiredString(json, 'indexSha256'),
      files: files.map(CatalogSnapshotFile.fromJson).toList(growable: false),
    );
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(result.indexSha256)) {
      throw const CatalogFormatException('invalid index digest');
    }
    return result;
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'catalog': pointer.toJson(),
    'indexSha256': indexSha256,
    'files': files.map((file) => file.toJson()).toList(growable: false),
  };
}

class CatalogSnapshot {
  const CatalogSnapshot({
    required this.manifest,
    required this.indexBytes,
    required this.index,
    required this.rootPath,
  });

  final CatalogSnapshotManifest manifest;
  final List<int> indexBytes;
  final CatalogIndex index;
  final String rootPath;

  String sourcePath(CatalogSnapshotFile file) =>
      '$rootPath/sources/${file.fileName}';
}

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw CatalogFormatException('$key must be a non-empty string');
  }
  return value;
}

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int) throw CatalogFormatException('$key must be an integer');
  return value;
}

Map<String, dynamic> _requiredMap(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! Map) throw CatalogFormatException('$key must be an object');
  return Map<String, dynamic>.from(value);
}

DateTime _parseDate(Map<String, dynamic> json, String key) {
  final value = _requiredString(json, key);
  final date = DateTime.tryParse(value);
  if (date == null) throw CatalogFormatException('$key must be RFC3339');
  return date.toUtc();
}

CatalogPointer? _optionalPointer(Object? value) {
  if (value == null) return null;
  if (value is! Map)
    throw const CatalogFormatException('pointer must be object or null');
  return CatalogPointer.fromJson(Map<String, dynamic>.from(value));
}

CatalogLastAuthority? _optionalLastAuthority(Object? value) {
  if (value == null) return null;
  if (value is! Map)
    throw const CatalogFormatException('lastAuthority must be object or null');
  return CatalogLastAuthority.fromJson(Map<String, dynamic>.from(value));
}
