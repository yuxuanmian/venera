import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/tracking/source_revision_store.dart';
import 'package:venera/foundation/tracking/source_runtime_policy.dart';

const _parseRevision = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

String _validSource(String key) =>
    '''
class ParseCompletionSource extends ComicSource {
  name = "Parse completion";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  comic = {
    loadInfo(id) {
      return {
        title: "Title",
        subtitle: "Subtitle",
        cover: "https://example.test/cover.jpg",
        description: "Description",
        tags: { genre: ["tag"] },
        recommend: [{title: "Recommended", cover: "cover", id: "recommend-1", tags: [], description: ""}],
        comments: [{userName: "reader", content: "comment", id: "comment-1"}],
      };
    },
    onThumbnailLoad(imageKey) {
      return {headers: {"X-Test": "thumbnail"}, nested: {key: imageKey}};
    },
    onImageLoad(imageKey, comicId, epId) {
      return {headers: {"X-Test": "image"}, nested: {comicId: comicId, ep: epId}};
    },
    loadEp(id, ep) {
      return {images: ["https://example.test/$key/" + id + "/" + ep + ".jpg"], nested: {ok: true}};
    },
  };
}
''';

String _asyncSource(String key) => _validSource(key)
    .replaceFirst(
      'return {\n        title:',
      'return Promise.resolve({\n        title:',
    )
    .replaceFirst('      };\n    },', '      });\n    },');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory sourceDirectory;

  setUpAll(() async {
    await JsEngine().init();
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-parse-completion-');
    sourceDirectory = Directory(p.join(root.path, 'comic_source'))
      ..createSync(recursive: true);
    App.dataPath = root.path;
    App.disposeTracking();
    sourceRuntimePolicy.prepare(
      cloudEnabled: false,
      registry: const ActiveArtifactRegistry(),
      sourceDirectoryPath: sourceDirectory.path,
    );
  });

  tearDown(() async {
    sourceRuntimePolicy.revokeAll();
    App.disposeTracking();
    ComicSourceManager().remove('parse_config_failure');
    ComicSourceManager().remove('parse_data_failure');
    ComicSourceManager().remove('compatibility_probe');
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('failed model construction never registers an active context', () async {
    const key = 'parse_config_failure';
    final source = _validSource(
      key,
    ).replaceFirst('comic = {', 'explore = [{}];\n  comic = {');
    File(p.join(sourceDirectory.path, '$key.js')).writeAsStringSync(source);
    final artifact = ActiveArtifact(
      sourceKey: key,
      fileName: '$key.js',
      revision: null,
      relativePath: '$key.js',
      origin: ArtifactOrigin.custom,
      sha256: sha256.convert(utf8.encode(source)).toString(),
    );
    final registry = ActiveArtifactRegistry(artifacts: [artifact]);
    final store = SourceRevisionStore(sourceDirectory);
    await store.save(registry);
    sourceRuntimePolicy.prepare(
      cloudEnabled: false,
      registry: registry,
      sourceDirectoryPath: sourceDirectory.path,
    );

    await expectLater(
      ComicSourceManager().reload(requiredArtifact: artifact),
      throwsA(anything),
    );
    expect(ComicSource.find(key), isNull);
    expect(sourceRuntimePolicy.hasActiveRuntime(artifact), isFalse);
  });

  test('source data failure never registers an active context', () async {
    const key = 'parse_data_failure';
    final source = _validSource(key);
    File(p.join(sourceDirectory.path, '$key.js')).writeAsStringSync(source);
    File(
      p.join(root.path, 'comic_source', '$key.data'),
    ).writeAsStringSync('{not-json');
    final artifact = ActiveArtifact(
      sourceKey: key,
      fileName: '$key.js',
      revision: null,
      relativePath: '$key.js',
      origin: ArtifactOrigin.custom,
      sha256: sha256.convert(utf8.encode(source)).toString(),
    );
    final registry = ActiveArtifactRegistry(artifacts: [artifact]);
    final store = SourceRevisionStore(sourceDirectory);
    await store.save(registry);
    sourceRuntimePolicy.prepare(
      cloudEnabled: false,
      registry: registry,
      sourceDirectoryPath: sourceDirectory.path,
    );

    await expectLater(
      ComicSourceManager().reload(requiredArtifact: artifact),
      throwsA(isA<FormatException>()),
    );
    expect(ComicSource.find(key), isNull);
    expect(sourceRuntimePolicy.hasActiveRuntime(artifact), isFalse);
  });

  test(
    'a failed non-registering validation preserves the active source',
    () async {
      const key = 'compatibility_probe';
      final source = _validSource(key);
      File(p.join(sourceDirectory.path, '$key.js')).writeAsStringSync(source);
      final artifact = ActiveArtifact(
        sourceKey: key,
        fileName: '$key.js',
        revision: null,
        relativePath: '$key.js',
        origin: ArtifactOrigin.custom,
        sha256: sha256.convert(utf8.encode(source)).toString(),
      );
      final registry = ActiveArtifactRegistry(artifacts: [artifact]);
      await SourceRevisionStore(sourceDirectory).save(registry);
      sourceRuntimePolicy.prepare(
        cloudEnabled: false,
        registry: registry,
        sourceDirectoryPath: sourceDirectory.path,
      );
      await ComicSourceManager().reload(requiredArtifact: artifact);
      final active = ComicSource.find(key)!;
      final failedCandidate = _validSource(
        key,
      ).replaceFirst('comic = {', 'explore = [{}];\n  comic = {');

      await expectLater(
        ComicSourceParser().parse(
          failedCandidate,
          p.join(sourceDirectory.path, 'candidate.js'),
          register: false,
          allowExistingKey: true,
          loadData: false,
          scheduleInit: false,
        ),
        throwsA(anything),
      );
      expect(ComicSource.find(key), same(active));
      expect(
        JsEngine().runCode('ComicSource.sources.$key.comic != null'),
        isTrue,
      );
    },
  );

  for (final asynchronous in [false, true]) {
    test('real source callbacks preserve nested object results '
        '(async: $asynchronous)', () async {
      const key = 'compatibility_probe';
      final source = asynchronous ? _asyncSource(key) : _validSource(key);
      File(p.join(sourceDirectory.path, '$key.js')).writeAsStringSync(source);
      final artifact = ActiveArtifact(
        sourceKey: key,
        fileName: '$key.js',
        revision: null,
        relativePath: '$key.js',
        origin: ArtifactOrigin.custom,
        sha256: sha256.convert(utf8.encode(source)).toString(),
      );
      final registry = ActiveArtifactRegistry(artifacts: [artifact]);
      await SourceRevisionStore(sourceDirectory).save(registry);
      sourceRuntimePolicy.prepare(
        cloudEnabled: false,
        registry: registry,
        sourceDirectoryPath: sourceDirectory.path,
      );
      await ComicSourceManager().reload(requiredArtifact: artifact);

      final loaded = ComicSource.find(key)!;
      final details = (await loaded.loadComicInfo!('comic-1')).data;
      expect(details.title, 'Title');
      expect(details.tags['genre'], ['tag']);
      expect(details.recommend!.single.title, 'Recommended');
      expect(details.comments!.single.content, 'comment');

      final thumbnail = loaded.getThumbnailLoadingConfig!('thumb');
      expect(thumbnail, isA<Map<String, dynamic>>());
      expect(thumbnail['headers'], isA<Map<String, dynamic>>());
      expect(thumbnail['headers']['X-Test'], 'thumbnail');
      final image = await loaded.getImageLoadingConfig!(
        'image',
        'comic-1',
        'ep-1',
      );
      expect(image, isA<Map<String, dynamic>>());
      expect(image['headers']['X-Test'], 'image');
      final pages = (await loaded.loadComicPages!('comic-1', 'ep-1')).data;
      expect(pages.single, contains('compatibility_probe/comic-1/ep-1'));

      final context = sourceRuntimePolicy.contextForRuntimeKey(key)!;
      final wrapped =
          JsEngine().runCode(
                '({empty: {}, nested: {value: 7}, bytes: new Uint8Array([1, 2, 3]).buffer, fn: () => 9})',
                null,
                context,
              )
              as Map<String, dynamic>;
      expect(wrapped, isA<Map<String, dynamic>>());
      expect(wrapped['empty'], isA<Map<String, dynamic>>());
      expect(wrapped['nested']['value'], 7);
      expect(wrapped['bytes'], isA<Uint8List>());
      final function = wrapped['fn'] as JSInvokable;
      expect(function([]), 9);
      sourceRuntimePolicy.requestMode(
        cloudEnabled: false,
        operationEpoch: sourceRuntimePolicy.operationEpoch + 1,
      );
      expect(() => function([]), throwsA(isA<SourceRuntimeDenied>()));
      function.free();
    });
  }

  test('managed pinned runtime uses the same real callback path', () async {
    const key = 'compatibility_probe';
    final source = _validSource(key);
    final store = SourceRevisionStore(sourceDirectory);
    final materialized = await store.writeManagedArtifact(
      _parseRevision,
      '$key.js',
      utf8.encode(source),
      sourceKey: key,
    );
    final artifact = materialized.copyWith(cloudCapable: true);
    final registry = ActiveArtifactRegistry(artifacts: [artifact]);
    await store.save(registry);
    sourceRuntimePolicy.prepare(
      cloudEnabled: true,
      registry: registry,
      sourceDirectoryPath: sourceDirectory.path,
      authorityRevision: _parseRevision,
    );
    await ComicSourceManager().reload(requiredArtifact: artifact);
    final details = (await ComicSource.find(key)!.loadComicInfo!(
      'comic-1',
    )).data;
    expect(details.title, 'Title');
    expect(sourceRuntimePolicy.hasActiveRuntime(artifact), isTrue);
  });
}
