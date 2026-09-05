import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/tracking/source_revision_store.dart';
import 'package:venera/foundation/tracking/trusted_catalog.dart';

const ownershipRevisionA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const ownershipRevisionB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const ownershipRevisionC = 'cccccccccccccccccccccccccccccccccccccccc';

const ownershipCapable = TrustedArtifact(
  sourceKey: 'fixture_capable',
  fileName: 'fixture_capable.js',
);
const ownershipLocalOnly = TrustedArtifact(
  sourceKey: 'fixture_local_only',
  fileName: 'fixture_local_only.js',
);
const ownershipVariantA = TrustedArtifact(
  sourceKey: 'fixture_variant',
  fileName: 'fixture_variant_a.js',
);
const ownershipVariantB = TrustedArtifact(
  sourceKey: 'fixture_variant',
  fileName: 'fixture_variant_b.js',
);

class CloudOwnershipFixture {
  CloudOwnershipFixture(this.root);

  final Directory root;

  Directory get sourceDirectory => Directory(p.join(root.path, 'comic_source'));

  SourceRevisionStore get store => SourceRevisionStore(sourceDirectory);

  Future<void> create() => sourceDirectory.create(recursive: true);

  Future<void> dispose() async {
    if (await root.exists()) await root.delete(recursive: true);
  }

  String source(
    TrustedArtifact artifact, {
    String label = 'fixture',
    bool withTopLevelCounter = true,
  }) {
    final topLevel = withTopLevelCounter
        ? 'globalThis.__ownershipTopLevel = (globalThis.__ownershipTopLevel || 0) + 1;'
        : '';
    return '''
$topLevel
class FixtureSource extends ComicSource {
  name = "$label";
  key = "${artifact.sourceKey}";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  init() { globalThis.__ownershipInit = (globalThis.__ownershipInit || 0) + 1; }
}
''';
  }

  List<int> scriptBytes(TrustedArtifact artifact, String revision) =>
      utf8.encode(source(artifact, label: revision));

  ActiveArtifact customArtifact(
    TrustedArtifact artifact,
    String relativePath,
    List<int> bytes, {
    bool blocked = false,
  }) => ActiveArtifact(
    sourceKey: artifact.sourceKey,
    fileName: artifact.fileName,
    revision: null,
    relativePath: relativePath,
    origin: ArtifactOrigin.custom,
    sha256: sha256.convert(bytes).toString(),
    activationBlocked: blocked,
  );

  Future<ActiveArtifact> writeManaged(
    TrustedArtifact artifact,
    String revision,
  ) => store.writeManagedArtifact(
    revision,
    artifact.fileName,
    scriptBytes(artifact, revision),
    sourceKey: artifact.sourceKey,
  );

  List<Map<String, dynamic>> indexJson(String revision) => [
    {
      'key': ownershipCapable.sourceKey,
      'fileName': ownershipCapable.fileName,
      'version': revision,
      'cloudTracking': {'scanner': 'scanner.js'},
    },
    {
      'key': ownershipLocalOnly.sourceKey,
      'fileName': ownershipLocalOnly.fileName,
      'version': revision,
    },
    {
      'key': ownershipVariantA.sourceKey,
      'fileName': ownershipVariantA.fileName,
      'version': revision,
      'cloudTracking': {'scanner': 'variant-a.js'},
    },
    {
      'key': ownershipVariantB.sourceKey,
      'fileName': ownershipVariantB.fileName,
      'version': revision,
    },
  ];

  List<int> indexBytes(String revision) =>
      utf8.encode(jsonEncode(indexJson(revision)));

  ActiveArtifactRegistry registry(
    Iterable<ActiveArtifact> artifacts, {
    Iterable<ActiveArtifact> recoverable = const [],
  }) => ActiveArtifactRegistry(
    artifacts: List.unmodifiable(artifacts),
    recoverableArtifacts: List.unmodifiable(recoverable),
  );
}
