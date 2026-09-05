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

const _revision = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

String _source(String key) =>
    '''
class CompatibilityProbe extends ComicSource {
  name = "Compatibility Probe";
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
      return Promise.resolve({headers: {"X-Test": "image"}, nested: {comicId: comicId, ep: epId}});
    },
    loadEp(id, ep) {
      return {images: ["https://example.test/$key/" + id + "/" + ep + ".jpg"], nested: {ok: true}};
    },
  };
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory sourceDirectory;

  setUpAll(() async {
    await JsEngine().init();
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-result-compat-');
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
    ComicSourceManager().remove('compatibility_probe');
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<ActiveArtifact> loadLocalSource() async {
    const key = 'compatibility_probe';
    final source = _source(key);
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
    return artifact;
  }

  test('sync and async production callbacks consume typed results', () async {
    final artifact = await loadLocalSource();
    final loaded = ComicSource.find(artifact.sourceKey)!;

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
    expect(image['headers'], isA<Map<String, dynamic>>());
    expect(image['headers']['X-Test'], 'image');

    final pages = (await loaded.loadComicPages!('comic-1', 'ep-1')).data;
    expect(pages, [
      'https://example.test/compatibility_probe/comic-1/ep-1.jpg',
    ]);

    final context = sourceRuntimePolicy.contextForRuntimeKey(
      artifact.sourceKey,
    )!;
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
    expect((wrapped['bytes'] as Uint8List).toList(), [1, 2, 3]);
    final function = wrapped['fn'] as JSInvokable;
    expect(function([]), 9);
    function.free();
  });

  test('managed pinned activation uses the same exact runtime path', () async {
    const key = 'compatibility_probe';
    final source = _source(key);
    final store = SourceRevisionStore(sourceDirectory);
    final artifact = await store.writeManagedArtifact(
      _revision,
      '$key.js',
      utf8.encode(source),
      sourceKey: key,
    );
    final registry = ActiveArtifactRegistry(
      artifacts: [artifact.copyWith(cloudCapable: true)],
    );
    await store.save(registry);
    sourceRuntimePolicy.prepare(
      cloudEnabled: true,
      registry: registry,
      sourceDirectoryPath: sourceDirectory.path,
      authorityRevision: _revision,
    );

    await ComicSourceManager().reload(
      requiredArtifact: registry.artifacts.single,
    );
    final loaded = ComicSource.find(key)!;
    final details = (await loaded.loadComicInfo!('comic-1')).data;

    expect(details.title, 'Title');
    expect(details.recommend!.single.id, 'recommend-1');
    expect(
      sourceRuntimePolicy.hasActiveRuntime(registry.artifacts.single),
      isTrue,
    );
  });

  test('runtime validation rejects wrong exact artifact identity', () async {
    final artifact = await loadLocalSource();
    final manager = ComicSourceManager();

    manager.requireLoadedArtifact(artifact);
    expect(
      () => manager.requireLoadedArtifact(
        artifact.copyWith(relativePath: 'different-path.js'),
      ),
      throwsStateError,
    );
    expect(
      () => manager.requireLoadedArtifact(
        ActiveArtifact(
          sourceKey: artifact.sourceKey,
          fileName: 'same-key-variant.js',
          revision: artifact.revision,
          relativePath: 'same-key-variant.js',
          origin: artifact.origin,
          sha256: artifact.sha256,
        ),
      ),
      throwsStateError,
    );

    expect(
      sourceRuntimePolicy.hasActiveRuntime(
        artifact.copyWith(
          sha256:
              '0000000000000000000000000000000000000000000000000000000000000000',
        ),
      ),
      isFalse,
    );
    expect(
      sourceRuntimePolicy.hasActiveRuntime(
        artifact.copyWith(relativePath: 'different-path.js'),
      ),
      isFalse,
    );
    expect(
      sourceRuntimePolicy.hasActiveRuntime(
        ActiveArtifact(
          sourceKey: artifact.sourceKey,
          fileName: 'same-key-variant.js',
          revision: artifact.revision,
          relativePath: 'same-key-variant.js',
          origin: artifact.origin,
          sha256: artifact.sha256,
        ),
      ),
      isFalse,
    );
  });
}
