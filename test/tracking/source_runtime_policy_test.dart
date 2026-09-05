import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/tracking/source_revision_store.dart';
import 'package:venera/foundation/tracking/source_runtime_policy.dart';
import 'package:venera/foundation/tracking/trusted_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  const identity = TrustedArtifact(
    sourceKey: 'runtime_revoke_source',
    fileName: 'runtime_revoke_source.js',
  );
  const source = '''
class RuntimeRevokeSource extends ComicSource {
  name = "Runtime revoke";
  key = "runtime_revoke_source";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  init() {
    globalThis.__runtimeRevokeInitCount =
      (globalThis.__runtimeRevokeInitCount || 0) + 1;
  }
}
''';

  setUpAll(() async {
    await JsEngine().init();
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-runtime-policy-');
    App.dataPath = root.path;
    final bytes = utf8.encode(source);
    final file = File('${root.path}/${identity.fileName}')
      ..writeAsBytesSync(bytes);
    sourceRuntimePolicy.prepare(
      cloudEnabled: false,
      registry: ActiveArtifactRegistry(
        artifacts: [
          ActiveArtifact(
            sourceKey: identity.sourceKey,
            fileName: identity.fileName,
            revision: null,
            relativePath: identity.fileName,
            origin: ArtifactOrigin.custom,
            sha256: sha256.convert(bytes).toString(),
          ),
        ],
      ),
      sourceDirectoryPath: root.path,
    );
    expect(file.existsSync(), isTrue);
  });

  tearDown(() async {
    sourceRuntimePolicy.prepare(
      cloudEnabled: false,
      registry: const ActiveArtifactRegistry(),
      sourceDirectoryPath: null,
    );
    ComicSourceManager().remove(identity.sourceKey);
    sourceRuntimePolicy.unregisterRuntimeContext(identity.sourceKey);
    await root.delete(recursive: true);
  });

  test('revoked source runtime cannot continue delayed JS execution', () async {
    final filePath = '${root.path}/${identity.fileName}';
    await ComicSourceParser().parse(
      source,
      filePath,
      loadData: false,
      scheduleInit: true,
    );

    sourceRuntimePolicy.requestMode(
      cloudEnabled: true,
      operationEpoch: sourceRuntimePolicy.operationEpoch + 1,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(JsEngine().runCode('globalThis.__runtimeRevokeInitCount || 0'), 0);
    expect(
      () => JsEngine().runCode(
        'ComicSource.sources.${identity.sourceKey}.init()',
      ),
      throwsA(isA<SourceRuntimeDenied>()),
    );
  });
}
