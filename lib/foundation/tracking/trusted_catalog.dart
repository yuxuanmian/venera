import 'package:path/path.dart' as p;

/// Operator-maintained catalog authority used for Cloud source activation.
/// The App accepts only immutable commit revisions and URLs rooted at the
/// configured repository; a source script cannot choose a Cloud origin.
class TrustedCatalog {
  const TrustedCatalog({
    this.catalogId = maintainedCatalogId,
    this.owner = 'yuxuanmian',
    this.repository = 'venera-configs',
  });

  static const maintainedCatalogId = 'yuxuanmian/venera-configs';
  static const rawHost = 'raw.githubusercontent.com';
  static const githubHost = 'github.com';

  final String catalogId;
  final String owner;
  final String repository;

  static final revisionPattern = RegExp(r'^[0-9a-f]{40,64}$');

  bool isTrustedCatalog(String value) => value == catalogId;

  bool isValidRevision(String value) => revisionPattern.hasMatch(value);

  Uri indexUri(String revision) {
    _checkRevision(revision);
    return _rawUri(revision, 'index.json');
  }

  Uri artifactUri(String revision, String relativePath) {
    _checkRevision(revision);
    final safePath = safeRelativePath(relativePath);
    return _rawUri(revision, safePath);
  }

  /// Returns the ref segment from a maintained raw GitHub artifact URL. The
  /// ref may be a branch for a user-facing catalog URL; callers must resolve
  /// it to a full commit before materializing executable content.
  String? referenceFromArtifactUri(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.host != rawHost ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    final segments = uri.pathSegments;
    if (segments.length != 4 ||
        segments[0] != owner ||
        segments[1] != repository ||
        segments[3].isEmpty) {
      return null;
    }
    return segments[2].isEmpty ? null : segments[2];
  }

  /// Returns the immutable commit when [uri] already uses one, and verifies
  /// that it addresses exactly [relativePath].
  String? pinnedRevisionFromArtifactUri(Uri uri, String relativePath) {
    final reference = referenceFromArtifactUri(uri);
    if (reference == null || !isValidRevision(reference)) return null;
    final expected = artifactUri(reference, relativePath);
    return expected == uri ? reference : null;
  }

  /// The resolver endpoint returns metadata only (a commit SHA), never
  /// executable source. It is kept separate from [isAllowedUri] because raw
  /// source fetches are restricted to [rawHost].
  Uri commitResolverUri(String reference) {
    if (reference.trim().isEmpty || reference.contains('?')) {
      throw const FormatException('catalog reference is invalid');
    }
    return Uri.https(
      'api.github.com',
      '/repos/$owner/$repository/commits/${Uri.encodeComponent(reference)}',
    );
  }

  bool isAllowedUri(Uri uri, {String? revision, String? relativePath}) {
    if (uri.scheme != 'https' ||
        uri.host != rawHost ||
        uri.hasQuery ||
        uri.hasFragment) {
      return false;
    }
    final expected = revision == null || relativePath == null
        ? null
        : artifactUri(revision, relativePath);
    if (expected != null) return uri == expected;
    return uri.pathSegments.length >= 4 &&
        uri.pathSegments[0] == owner &&
        uri.pathSegments[1] == repository;
  }

  CatalogIndex parseIndex(Object? value) {
    if (value is! List) {
      throw const FormatException('catalog index must be an array');
    }
    final entries = value.map(CatalogIndexEntry.fromJson).toList();
    final seen = <TrustedArtifact>{};
    for (final entry in entries) {
      if (!seen.add(entry.artifact)) {
        throw const FormatException('catalog contains duplicate artifact');
      }
    }
    return CatalogIndex(entries: List.unmodifiable(entries));
  }

  /// Normalizes a catalog-relative path and rejects absolute/traversal forms.
  static String safeRelativePath(String value) {
    if (value.trim().isEmpty || value.contains('\\') || value.startsWith('/')) {
      throw const FormatException('catalog path must be relative');
    }
    final normalized = p.posix.normalize(value);
    if (normalized == '.' ||
        normalized == '..' ||
        normalized.startsWith('../')) {
      throw const FormatException('catalog path escapes checkout');
    }
    return normalized;
  }

  Uri _rawUri(String revision, String relativePath) => Uri.https(
    rawHost,
    '/$owner/$repository/$revision/${safeRelativePath(relativePath)}',
  );

  void _checkRevision(String revision) {
    if (!isValidRevision(revision)) {
      throw const FormatException('revision must be an immutable full commit');
    }
  }
}

class TrustedArtifact {
  const TrustedArtifact({required this.sourceKey, required this.fileName});

  final String sourceKey;
  final String fileName;

  String get relativePath => fileName;

  factory TrustedArtifact.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('invalid catalog artifact');
    final sourceKey = value['sourceKey'];
    final fileName = value['fileName'];
    if (sourceKey is! String ||
        sourceKey.trim().isEmpty ||
        fileName is! String ||
        fileName.trim().isEmpty ||
        fileName != p.basename(fileName) ||
        !fileName.endsWith('.js')) {
      throw const FormatException('invalid catalog artifact');
    }
    return TrustedArtifact(sourceKey: sourceKey.trim(), fileName: fileName);
  }

  Map<String, dynamic> toJson() => {
    'sourceKey': sourceKey,
    'fileName': fileName,
  };

  @override
  bool operator ==(Object other) =>
      other is TrustedArtifact &&
      other.sourceKey == sourceKey &&
      other.fileName == fileName;

  @override
  int get hashCode => Object.hash(sourceKey, fileName);
}

/// A catalog entry is the only trusted source of the exact sourceKey/fileName
/// pair used for activation. The optional hash and runtime fields are
/// validated when present so newer catalogs can tighten their contract
/// without changing the public authority shape.
class CatalogIndexEntry {
  const CatalogIndexEntry({
    required this.artifact,
    this.version,
    this.sha256,
    this.scanner,
    this.parserVersion,
    this.runtime,
  });

  final TrustedArtifact artifact;
  final String? version;
  final String? sha256;
  final String? scanner;
  final String? parserVersion;
  final String? runtime;

  bool get cloudCapable => scanner != null;

  factory CatalogIndexEntry.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('invalid catalog index entry');
    }
    final key = value['key'];
    final fileName = value['fileName'];
    if (key is! String || fileName is! String) {
      throw const FormatException('catalog entry identity is invalid');
    }
    final artifact = TrustedArtifact.fromJson({
      'sourceKey': key,
      'fileName': fileName,
    });
    final rawCloudTracking = value['cloudTracking'];
    String? scanner;
    if (rawCloudTracking != null) {
      if (rawCloudTracking is! Map || rawCloudTracking['scanner'] is! String) {
        throw const FormatException('catalog cloudTracking is invalid');
      }
      scanner = TrustedCatalog.safeRelativePath(
        rawCloudTracking['scanner'] as String,
      );
    }
    String? sha256;
    if (value['sha256'] != null) {
      if (value['sha256'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(value['sha256'] as String)) {
        throw const FormatException('catalog artifact hash is invalid');
      }
      sha256 = value['sha256'] as String;
    }
    String? parserVersion;
    if (value['parserVersion'] != null) {
      if (value['parserVersion'] is! String ||
          (value['parserVersion'] as String).trim().isEmpty) {
        throw const FormatException('catalog parser version is invalid');
      }
      parserVersion = value['parserVersion'] as String;
    }
    String? runtime;
    if (value['runtime'] != null) {
      if (value['runtime'] is! String ||
          (value['runtime'] as String).trim().isEmpty) {
        throw const FormatException('catalog runtime is invalid');
      }
      runtime = value['runtime'] as String;
    }
    String? version;
    if (value['version'] != null) {
      if (value['version'] is! String ||
          (value['version'] as String).trim().isEmpty) {
        throw const FormatException('catalog version is invalid');
      }
      version = value['version'] as String;
    }
    return CatalogIndexEntry(
      artifact: artifact,
      version: version,
      sha256: sha256,
      scanner: scanner,
      parserVersion: parserVersion,
      runtime: runtime,
    );
  }

  Map<String, dynamic> toJson() => {
    'key': artifact.sourceKey,
    'fileName': artifact.fileName,
    if (version != null) 'version': version,
    if (sha256 != null) 'sha256': sha256,
    if (scanner != null) 'cloudTracking': {'scanner': scanner},
    if (parserVersion != null) 'parserVersion': parserVersion,
    if (runtime != null) 'runtime': runtime,
  };
}

class CatalogIndex {
  const CatalogIndex({required this.entries});

  final List<CatalogIndexEntry> entries;

  CatalogIndexEntry? findByArtifact(TrustedArtifact artifact) {
    for (final entry in entries) {
      if (entry.artifact == artifact) return entry;
    }
    return null;
  }

  CatalogIndexEntry? findByFileName(String fileName) {
    final matches = entries
        .where((entry) => entry.artifact.fileName == fileName)
        .toList(growable: false);
    return matches.length == 1 ? matches.single : null;
  }

  Map<String, dynamic> toJson() => {
    'entries': entries.map((entry) => entry.toJson()).toList(),
  };
}

class TrustedAuthority {
  const TrustedAuthority({
    required this.catalogId,
    required this.activeRevision,
    required this.artifacts,
    this.generation,
  });

  final String catalogId;
  final String activeRevision;
  final List<TrustedArtifact> artifacts;
  final int? generation;

  factory TrustedAuthority.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('invalid tracking authority');
    }
    final catalogId = value['catalogId'];
    final revision = value['activeRevision'];
    final rawArtifacts = value['artifacts'];
    if (catalogId is! String || revision is! String || rawArtifacts is! List) {
      throw const FormatException('invalid tracking authority');
    }
    final artifacts = rawArtifacts.map(TrustedArtifact.fromJson).toList();
    final seen = <TrustedArtifact>{};
    for (final artifact in artifacts) {
      if (!seen.add(artifact)) {
        throw const FormatException(
          'tracking authority contains duplicate artifact',
        );
      }
    }
    final result = TrustedAuthority(
      catalogId: catalogId,
      activeRevision: revision,
      artifacts: List.unmodifiable(artifacts),
      generation: value['generation'] is int
          ? value['generation'] as int
          : null,
    );
    if (!TrustedCatalog.revisionPattern.hasMatch(result.activeRevision)) {
      throw const FormatException('tracking authority revision is invalid');
    }
    return result;
  }

  Map<String, dynamic> toJson() => {
    'catalogId': catalogId,
    'activeRevision': activeRevision,
    'artifacts': artifacts.map((e) => e.toJson()).toList(),
    if (generation != null) 'generation': generation,
  };

  bool contains(TrustedArtifact artifact) => artifacts.contains(artifact);
}
