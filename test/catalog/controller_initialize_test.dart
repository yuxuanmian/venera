import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/controller.dart';
import 'package:venera/foundation/catalog/http_client.dart';
import 'package:venera/foundation/catalog/models.dart';
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
  test(
    'initialization selects legacy keys only when preferences are absent',
    () {
      expect(SourcePreferences(initial: null).enabledSources, isNull);
      expect(SourcePreferences(initial: []).enabledSources, isEmpty);
    },
  );

  for (final selection in <List<String>?>[
    null,
    [],
    ['demo'],
  ]) {
    test(
      'initialize preserves ${selection ?? 'null'} source selection',
      () async {
        final root = await Directory.systemTemp.createTemp('catalog-init-');
        addTearDown(() => root.delete(recursive: true));
        final oldDataPath = App.isInitialized ? App.dataPath : null;
        final oldRuntime = appdata.catalogRuntime;
        final oldEnabled = appdata.settings['enabledSources'];
        final oldLoadError = appdata.loadError;
        App.dataPath = '${root.path}/data';
        appdata.loadError = null;
        appdata.catalogRuntime = null;
        appdata.settings['enabledSources'] = selection;
        addTearDown(() {
          appdata.loadError = oldLoadError;
          appdata.catalogRuntime = oldRuntime;
          appdata.settings['enabledSources'] = oldEnabled;
          if (oldDataPath != null) App.dataPath = oldDataPath;
        });

        final revision = 'a' * 40;
        final pointer = CatalogPointer(
          catalogId: 'owner/repo',
          revision: revision,
          indexUrl:
              'https://raw.githubusercontent.com/owner/repo/$revision/index.json',
        );
        final index = [
          {
            'name': 'Demo',
            'key': 'demo',
            'fileName': 'demo.js',
            'version': '1',
          },
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
        final originalSelection = selection == null
            ? null
            : List<String>.from(selection);
        final preferences = SourcePreferences(initial: selection);
        addTearDown(preferences.dispose);
        final controller = CatalogController(
          store: CatalogStore(Directory('${root.path}/catalog')),
          httpClient: CatalogHttpClient(transport: transport),
          preferences: preferences,
          appdata: appdata,
          legacyRoot: Directory('${root.path}/comic_source'),
        );

        final result = await controller.initialize('https://server.example');

        expect(result, isA<CatalogReady>());
        expect(preferences.enabledSources, selection ?? isEmpty);
        expect(
          selection == null ? null : List<String>.from(selection),
          originalSelection,
        );
        expect(appdata.settings['enabledSources'], selection ?? isEmpty);

        final retry = await controller.recover('https://server.example');
        expect(retry, isA<CatalogReady>());
        expect(
          preferences.enabledSources,
          selection == null ? isEmpty : selection,
        );
      },
    );
  }
}
