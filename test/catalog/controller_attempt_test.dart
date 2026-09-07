import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/controller.dart';
import 'package:venera/foundation/catalog/http_client.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/runtime_context.dart';
import 'package:venera/foundation/catalog/runtime_loader.dart';
import 'package:venera/foundation/catalog/store.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';

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
    'controller cancellation leaves a late prepared runtime revoked',
    () async {
      final root = await Directory.systemTemp.createTemp('catalog-attempt-');
      addTearDown(() => root.delete(recursive: true));
      final wasInitialized = App.isInitialized;
      final oldDataPath = wasInitialized ? App.dataPath : null;
      final oldCachePath = wasInitialized ? App.cachePath : null;
      App.dataPath = '${root.path}/data';
      App.cachePath = '${root.path}/cache';
      addTearDown(() {
        if (wasInitialized) {
          App.dataPath = oldDataPath!;
          App.cachePath = oldCachePath!;
        } else {
          App.isInitialized = false;
        }
      });
      appdata.loadError = null;
      appdata.catalogRuntime = null;

      final revision = 'a' * 40;
      final pointer = CatalogPointer(
        catalogId: 'owner/repo',
        revision: revision,
        indexUrl:
            'https://raw.githubusercontent.com/owner/repo/$revision/index.json',
      );
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

      var factoryCalls = 0;
      final preparationStarted = Completer<void>();
      final pendingSource = Completer<Object>();
      ManagedSourceContext? preparingContext;
      final loader = CatalogRuntimeLoader(
        factory: (entry, source, context) {
          factoryCalls++;
          if (factoryCalls == 2) {
            preparingContext = context;
            preparationStarted.complete();
            return pendingSource.future;
          }
          return source;
        },
      );
      final controller = CatalogController(
        store: CatalogStore(Directory('${root.path}/catalog')),
        httpClient: CatalogHttpClient(transport: transport),
        runtimeLoader: loader,
        preferences: SourcePreferences(initial: []),
        appdata: appdata,
        legacyRoot: Directory('${root.path}/comic_source'),
      );

      final initialization = controller.initialize('https://server.example');
      await preparationStarted.future.timeout(const Duration(seconds: 5));
      controller.cancelCurrentAttempt();
      final result = await initialization;
      expect(result, isA<CatalogNeedsInitialization>());
      expect((result as CatalogNeedsInitialization).failure, isNull);
      expect(preparingContext?.phase, ManagedSourcePhase.preparing);

      pendingSource.complete('late source');
      await Future<void>.delayed(Duration.zero);
      expect(preparingContext?.phase, ManagedSourcePhase.revoked);
    },
  );
}
