import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/controller.dart';
import 'package:venera/foundation/catalog/http_client.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/runtime_loader.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';
import 'package:venera/foundation/catalog/store.dart';

class _Transport implements CatalogTransport {
  _Transport(this.responses);

  final Map<String, CatalogBytesResponse> responses;

  @override
  Future<CatalogBytesResponse> getBytes(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    CatalogCancellationToken? cancellation,
  }) async {
    final response = responses[uri.toString()];
    if (response == null) throw StateError('missing response for $uri');
    return response;
  }
}

void main() {
  test('startup result types make initialization and recovery explicit', () {
    expect(
      const CatalogNeedsInitialization(serverDraft: ''),
      isA<CatalogStartupResult>(),
    );
    expect(
      const CatalogNeedsRecovery('bad state'),
      isA<CatalogStartupResult>(),
    );
    expect(SourcePreferences.normalizeOrPrevious('bad', ['kept']), ['kept']);
    expect(CatalogIndex.fromJson([]).entries, isEmpty);
  });

  test('same-revision damaged cache is rebuilt from the authority', () async {
    final root = await Directory.systemTemp.createTemp('catalog-boot-repair-');
    addTearDown(() => root.delete(recursive: true));
    final oldDataPath = App.isInitialized ? App.dataPath : null;
    final oldRuntime = appdata.catalogRuntime;
    final oldServer = appdata.settings['serverUrl'];
    final oldEnabled = appdata.settings['enabledSources'];
    App.dataPath = '${root.path}/data';
    appdata.catalogRuntime = null;
    appdata.loadError = null;
    appdata.settings['serverUrl'] = 'https://server.example';
    appdata.settings['enabledSources'] = <String>[];
    addTearDown(() {
      appdata.catalogRuntime = oldRuntime;
      appdata.settings['serverUrl'] = oldServer;
      appdata.settings['enabledSources'] = oldEnabled;
      if (oldDataPath != null) App.dataPath = oldDataPath;
    });

    final revision = 'c' * 40;
    final pointer = CatalogPointer(
      catalogId: 'owner/repo',
      revision: revision,
      indexUrl:
          'https://raw.githubusercontent.com/owner/repo/$revision/index.json',
    );
    appdata.catalogRuntime = AppCatalogState(active: pointer).toJson();
    final store = CatalogStore(Directory('${root.path}/catalog'));
    final damaged = store.snapshotDirectory(pointer);
    await damaged.create(recursive: true);
    await File('${damaged.path}/snapshot.json').writeAsString('{broken');
    final index = [
      {'name': 'Demo', 'key': 'demo', 'fileName': 'demo.js', 'version': '1'},
    ];
    final transport = _Transport({
      'https://server.example/api/catalog/authority': CatalogBytesResponse(
        200,
        utf8.encode(
          jsonEncode({
            'catalogId': pointer.catalogId,
            'activeRevision': revision,
            'indexUrl': pointer.indexUrl,
          }),
        ),
      ),
      pointer.indexUrl: CatalogBytesResponse(
        200,
        utf8.encode(jsonEncode(index)),
      ),
      'https://raw.githubusercontent.com/owner/repo/$revision/demo.js':
          CatalogBytesResponse(200, utf8.encode('source')),
    });
    final controller = CatalogController(
      store: store,
      httpClient: CatalogHttpClient(transport: transport),
      runtimeLoader: CatalogRuntimeLoader(),
      preferences: SourcePreferences(initial: []),
      appdata: appdata,
      legacyRoot: Directory('${root.path}/comic_source'),
    );
    addTearDown(controller.preferences.dispose);

    final result = await controller.boot();

    expect(result, isA<CatalogReady>());
    expect((await store.readSnapshot(pointer))?.index.keys, {'demo'});
    expect(await damaged.exists(), isTrue);
  });
}
