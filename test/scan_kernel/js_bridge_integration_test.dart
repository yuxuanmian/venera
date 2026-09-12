import 'dart:async';
import 'dart:ffi';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as file_path;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/runtime_context.dart';
import 'package:venera/foundation/catalog/runtime_loader.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/scan/execution_guard.dart';
import 'package:venera/foundation/scan/full_scan_planner.dart';
import 'package:venera/foundation/scan/js_source_adapter.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_call_lease.dart';
import 'package:venera/foundation/scan/scan_emission.dart';
import 'package:venera/foundation/scan/scan_executor.dart';
import 'package:venera/foundation/scan/scan_limits.dart';
import 'package:venera/foundation/scan/scan_result_repository.dart';
import 'package:venera/foundation/scan/sqlite_scan_result_repository.dart';
import 'package:venera/foundation/scan/source_adapter.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/network/cookie_jar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dataDirectory;
  const key = 'scan_bridge_integration_case';

  setUpAll(() async {
    dataDirectory = await Directory.systemTemp.createTemp(
      'venera-scan-bridge-',
    );
    App.dataPath = dataDirectory.path;
    if (!_quickJsAvailable) return;
    await JsEngine().init();
  });

  tearDownAll(() async {
    ComicSourceManager().remove(key);
    JsEngine().dispose();
    if (dataDirectory.existsSync()) await dataDirectory.delete(recursive: true);
  });

  test(
    'parsed source scan callback crosses the real QuickJS bridge',
    () async {
      if (!_quickJsAvailable) return;
      final source = await ComicSourceParser().parse(
        '''
class ScanBridgeIntegrationSource extends ComicSource {
  name = "Scan bridge integration";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  scan = {
    primary: "comic",
    comic: {
      fieldSource: {latestChapterId: "comic.id"},
      load: async (id, request) => {
        const response = await request({
          method: "GET",
          url: "https://example.invalid/" + id,
        });
        return {observation: {update: {latestChapterId: response.body}}};
      },
    },
  };
}
''',
        '$key.js',
        loadData: false,
        scheduleInit: false,
      );

      expect(source.scan, isNotNull);
      final requests = <ScanHttpRequest>[];
      final adapter = JsScanSourceAdapter(
        sourceKey: source.key,
        definitionRevision: source.version,
        capabilities: source.scan!,
        requestFactory: (lease) => (request) async {
          requests.add(ScanHttpRequest.fromJson(request));
          return const {
            'ok': true,
            'response': {
              'status': 200,
              'headers': <String, String>{},
              'body': 'bridge-chapter',
            },
          };
        },
      );
      final lease = ScanCallLease(
        guard: ScanExecutionGuard(
          sourceKey: source.key,
          sourceInstance: source,
          cacheGeneration: 0,
        ),
      );

      final result = await adapter.loadComic('comic-1', lease) as Map;

      expect(result['observation'], isA<Map>());
      expect(
        (result['observation'] as Map)['update']['latestChapterId'],
        'bridge-chapter',
      );
      expect(requests.single.method, 'GET');
      expect(requests.single.url, 'https://example.invalid/comic-1');
      expect(lease.isClosed, isTrue);
    },
    skip: _quickJsAvailable
        ? null
        : 'flutter_qjs native library is unavailable',
  );

  test(
    'shipped Picacg and Manwa scripts cross the real QuickJS bridge',
    () async {
      if (!_quickJsAvailable) return;
      final configsDirectory = _findConfigsDirectory();
      expect(configsDirectory, isNotNull);

      final sourceFiles = <String, String>{
        'picacg': 'picacg.js',
        'manwa': 'manwa.js',
      };
      for (final entry in sourceFiles.entries) {
        final file = File(file_path.join(configsDirectory!.path, entry.value));
        final source = await ComicSourceParser().parse(
          await file.readAsString(),
          file.path,
          loadData: false,
          scheduleInit: false,
        );
        try {
          ComicSourceManager().add(source);
          expect(source.key, entry.key);
          expect(source.scan, isNotNull);
          final requests = <ScanHttpRequest>[];
          final adapter = JsScanSourceAdapter(
            sourceKey: source.key,
            definitionRevision: source.version,
            capabilities: source.scan!,
            requestFactory: (lease) => (request) async {
              requests.add(ScanHttpRequest.fromJson(request));
              if (entry.key == 'picacg') {
                return const {
                  'ok': true,
                  'response': {
                    'status': 200,
                    'headers': <String, String>{},
                    'body':
                        '{"data":{"comic":{"_id":"bridge-picacg",'
                        '"updated_at":"2026-09-10T12:30:45.123Z"}}}',
                  },
                };
              }
              return const {
                'ok': true,
                'response': {
                  'status': 200,
                  'headers': <String, String>{},
                  'body':
                      '{"err":0,"books":[{"id":"bridge-manwa",'
                      '"last_chapter":{"id":"chapter-1"},'
                      '"is_new":false,"full_is_new":false}]}',
                },
              };
            },
          );
          final guard = ScanExecutionGuard(
            sourceKey: source.key,
            sourceInstance: source,
            cacheGeneration: 0,
          );

          if (entry.key == 'picacg') {
            final result =
                await adapter.loadComic(
                      'bridge-picacg',
                      ScanCallLease(guard: guard),
                    )
                    as Map;
            expect(result['observation'], isA<Map>());
            expect(requests.single.method, 'GET');
            expect(requests.single.url, contains('/comics/bridge-picacg'));
          } else {
            final result =
                await adapter.loadCollection(
                      'default',
                      null,
                      ScanCallLease(guard: guard),
                    )
                    as Map;
            expect(result['items'], isA<List>());
            expect((result['items'] as List).single['comicId'], 'bridge-manwa');
            expect(requests.single.method, 'GET');
            expect(requests.single.url, contains('getfavors?page=0'));
          }
        } finally {
          ComicSourceManager().remove(source.key);
        }
      }
    },
    skip: _quickJsAvailable
        ? null
        : 'flutter_qjs native library is unavailable',
  );

  test(
    'collection failure envelopes preserve status across Parser and QuickJS',
    () async {
      if (!_quickJsAvailable) return;
      const failureKey = 'scan_collection_failure_bridge';
      final source = await ComicSourceParser().parse(
        '''
class CollectionFailureBridgeSource extends ComicSource {
  name = "Collection failure bridge";
  key = "$failureKey";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  scan = {
    primary: "collection",
    collection: {
      fieldSource: {latestChapterId: "book.last_chapter.id"},
      load: async (key, cursor, request) => {
        if (key === "failure") {
          return {failure: {httpStatus: 403, sourceCode: "ERR_REMOTE", message: "permission denied"}};
        }
        if (key === "missing") return {items: []};
        return {failure: {httpStatus: 403}, items: [], next: null};
      },
    },
  };
}
''',
        '$failureKey.js',
        loadData: false,
        scheduleInit: false,
      );
      final guard = ScanExecutionGuard(
        sourceKey: source.key,
        sourceInstance: source,
        cacheGeneration: 0,
      );

      final failure =
          await JsScanSourceAdapter(
                sourceKey: source.key,
                definitionRevision: source.version,
                capabilities: source.scan!,
                requestFactory: (_) =>
                    (_) async => const {
                      'ok': true,
                      'response': {
                        'status': 200,
                        'headers': <String, String>{},
                        'body': '',
                      },
                    },
              ).loadCollection('failure', null, ScanCallLease(guard: guard))
              as Map;
      expect(failure['failure'], isA<Map>());
      expect((failure['failure'] as Map)['httpStatus'], 403);
      expect((failure['failure'] as Map)['sourceCode'], 'ERR_REMOTE');
      expect(failure.containsKey('next'), isFalse);

      for (final key in ['missing', 'mixed']) {
        final result =
            await JsScanSourceAdapter(
                  sourceKey: source.key,
                  definitionRevision: source.version,
                  capabilities: source.scan!,
                  requestFactory: (_) =>
                      (_) async => const {
                        'ok': true,
                        'response': {
                          'status': 200,
                          'headers': <String, String>{},
                          'body': '',
                        },
                      },
                ).loadCollection(key, null, ScanCallLease(guard: guard))
                as Map;
        expect(result['failure'], isA<Map>());
        expect(result.containsKey('items'), isFalse);
        expect(result.containsKey('next'), isFalse);
      }
    },
    skip: _quickJsAvailable
        ? null
        : 'flutter_qjs native library is unavailable',
  );

  test(
    'real Parser sanitizes credential-shaped failure fields before SQLite',
    () async {
      if (!_quickJsAvailable) return;
      const privacyKey = 'scan_privacy_parser_bridge';
      final source = await ComicSourceParser().parse(
        '''
class ScanPrivacyParserBridge extends ComicSource {
  name = "Scan privacy parser bridge";
  key = "$privacyKey";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  scan = {
    primary: "comic",
    comic: {
      fieldSource: {latestChapterId: "comic.id"},
      load: async (id, request) => ({failure: {
        httpStatus: 403,
        sourceCode: "token:synthetic-secret",
        exceptionType: "PASSWORD=synthetic-secret",
        message: "diagnostic prefix {\\"opaque\\":\\"json-body-secret\\"} <svg><title>markup-body-secret</title></svg>",
      }}),
    },
  };
}
''',
        '$privacyKey.js',
        loadData: false,
        scheduleInit: false,
      );
      final manager = ComicSourceManager();
      manager.add(source);
      final directory = await Directory.systemTemp.createTemp(
        'venera-scan-privacy-bridge-',
      );
      final repository = SqliteScanResultRepository(
        databasePath: file_path.join(directory.path, 'scan_results.db'),
      );
      addTearDown(() async {
        manager.remove(privacyKey);
        await repository.close();
        if (directory.existsSync()) await directory.delete(recursive: true);
      });

      final adapter = JsScanSourceAdapter(
        sourceKey: source.key,
        definitionRevision: source.version,
        capabilities: source.scan!,
        requestFactory: (_) =>
            (_) async => throw StateError('network used'),
      );
      final guard = ScanExecutionGuard(
        sourceKey: source.key,
        sourceInstance: source,
        cacheGeneration: 0,
      );
      final consumer = ScanEmissionConsumer(repository: repository);
      final outcome = await ScanExecutor(repository: repository).execute(
        ScanWorkSpec.comic(
          source: source,
          adapter: adapter,
          comicId: 'privacy-comic',
        ).toWork(guard),
        emit: (emission, context) => consumer.consume(emission, context),
      );

      expect(outcome.status, ScanWorkOutcomeStatus.failed);
      expect(outcome.persistedItems, 1);
      final stored = await repository.readLatestItem(
        privacyKey,
        'privacy-comic',
      );
      expect(stored, isNotNull);
      final encoded = jsonEncode(stored!.result.toJson());
      expect(encoded, contains('403'));
      expect(encoded, isNot(contains('synthetic-secret')));
      expect(encoded, isNot(contains('json-body-secret')));
      expect(encoded, isNot(contains('markup-body-secret')));
      expect(stored.result.failure!.sourceCode, isNull);
      expect(stored.result.failure!.exceptionType, isNull);
      expect(stored.result.failure!.message, '<body redacted>');
    },
    skip: _quickJsAvailable
        ? null
        : 'flutter_qjs native library is unavailable',
  );

  test(
    'shipped Manwa preserves source failures and verifies IDs only',
    () async {
      if (!_quickJsAvailable) return;
      final configsDirectory = _findConfigsDirectory();
      expect(configsDirectory, isNotNull);
      final file = File(file_path.join(configsDirectory!.path, 'manwa.js'));
      final sourceCode = (await file.readAsString()).replaceFirst(
        '    // Debug scan state is deliberately local to this Source instance.  It is',
        '''    saveData(dataKey, data) {
        return sendMessage({
            method: "save_data",
            key: this.key,
            data_key: dataKey,
            data: data,
        }).then(() => new Promise((resolve) => setTimeout(resolve, 50)))
    }

    // Debug scan state is deliberately local to this Source instance.  It is''',
      );
      final source = await ComicSourceParser().parse(
        sourceCode,
        file.path,
        loadData: false,
        scheduleInit: false,
      );
      final manager = ComicSourceManager();
      manager.add(source);
      addTearDown(() => manager.remove(source.key));
      final guard = ScanExecutionGuard(
        sourceKey: source.key,
        sourceInstance: source,
        cacheGeneration: 0,
      );

      final failure =
          await JsScanSourceAdapter(
                sourceKey: source.key,
                definitionRevision: source.version,
                capabilities: source.scan!,
                requestFactory: (_) =>
                    (_) async => const {
                      'ok': false,
                      'failure': {
                        'httpStatus': 403,
                        'sourceCode': 'ERR_REMOTE',
                        'message': 'permission denied',
                      },
                    },
              ).loadCollection('default', null, ScanCallLease(guard: guard))
              as Map;
      expect((failure['failure'] as Map)['httpStatus'], 403);
      expect((failure['failure'] as Map)['sourceCode'], 'ERR_REMOTE');
      expect(failure.containsKey('next'), isFalse);

      var requestCount = 0;
      final verifyAdapter = JsScanSourceAdapter(
        sourceKey: source.key,
        definitionRevision: source.version,
        capabilities: source.scan!,
        requestFactory: (_) => (_) async {
          requestCount++;
          final books = requestCount == 1
              ? const [
                  {
                    'id': 'stable-id',
                    'book_name': 'Stable',
                    'last_chapter': {'id': 'chapter-1'},
                    'is_new': false,
                    'full_is_new': false,
                  },
                ]
              : const [
                  {'id': 'changed-id'},
                ];
          return {
            'ok': true,
            'response': {
              'status': 200,
              'headers': <String, String>{},
              'body': jsonEncode({'err': 0, 'books': books}),
            },
          };
        },
      );
      final first =
          await verifyAdapter.loadCollection(
                'default',
                null,
                ScanCallLease(guard: guard),
              )
              as Map;
      expect((first['items'] as List).single['comicId'], 'stable-id');
      final verified =
          await verifyAdapter.loadCollection(
                'default',
                first['next'],
                ScanCallLease(guard: guard),
              )
              as Map;
      expect(
        (verified['failure'] as Map)['message'],
        'Manwa favorites changed during scan',
      );
      expect(verified.containsKey('items'), isFalse);
    },
    skip: _quickJsAvailable
        ? null
        : 'flutter_qjs native library is unavailable',
  );

  test(
    'real Manwa verify failure keeps the committed SQLite prefix',
    () async {
      if (!_quickJsAvailable) return;
      final configsDirectory = _findConfigsDirectory();
      expect(configsDirectory, isNotNull);
      final file = File(file_path.join(configsDirectory!.path, 'manwa.js'));
      final sourceCode = (await file.readAsString()).replaceFirst(
        '    // Debug scan state is deliberately local to this Source instance.  It is',
        '''    saveData(dataKey, data) {
        return sendMessage({
            method: "save_data",
            key: this.key,
            data_key: dataKey,
            data: data,
        }).then(() => new Promise((resolve) => setTimeout(resolve, 50)))
    }

    // Debug scan state is deliberately local to this Source instance.  It is''',
      );
      final source = await ComicSourceParser().parse(
        sourceCode,
        file.path,
        loadData: false,
        scheduleInit: false,
      );
      final manager = ComicSourceManager();
      manager.add(source);
      final directory = await Directory.systemTemp.createTemp(
        'venera-manwa-verify-',
      );
      final repository = SqliteScanResultRepository(
        databasePath: file_path.join(directory.path, 'scan_results.db'),
      );
      addTearDown(() async {
        manager.remove(source.key);
        await repository.close();
        if (directory.existsSync()) await directory.delete(recursive: true);
      });
      var requestCount = 0;
      final adapter = JsScanSourceAdapter(
        sourceKey: source.key,
        definitionRevision: source.version,
        capabilities: source.scan!,
        requestFactory: (_) => (_) async {
          requestCount++;
          final books = requestCount == 1
              ? const [
                  {
                    'id': 'prefix-id',
                    'book_name': 'Prefix',
                    'last_chapter': {'id': 'chapter-1'},
                    'is_new': false,
                    'full_is_new': false,
                  },
                ]
              : const [
                  {'id': 'different-id'},
                ];
          return {
            'ok': true,
            'response': {
              'status': 200,
              'headers': <String, String>{},
              'body': jsonEncode({'err': 0, 'books': books}),
            },
          };
        },
      );
      final guard = ScanExecutionGuard(
        sourceKey: source.key,
        sourceInstance: source,
        cacheGeneration: 0,
      );
      final consumer = ScanEmissionConsumer(repository: repository);
      final outcome = await ScanExecutor(repository: repository).execute(
        ScanWorkSpec.collection(
          source: source,
          adapter: adapter,
          collectionKey: 'default',
        ).toWork(guard),
        emit: (emission, context) => consumer.consume(emission, context),
      );

      expect(outcome.status, ScanWorkOutcomeStatus.failed);
      expect(outcome.persistedItems, 1);
      expect(
        await repository.readLatestItem(source.key, 'prefix-id'),
        isNotNull,
      );
      final scope = await repository.readLatestScope(
        source.key,
        ScanProducer.collection,
        'default',
      );
      expect(scope!.status, ScanScopeStatus.failed);
      expect(scope.itemCount, 1);
      expect(requestCount, 2);
    },
    skip: _quickJsAvailable
        ? null
        : 'flutter_qjs native library is unavailable',
  );

  test(
    'real QuickJS Picacg save_data remains in the shared refresh promise',
    () async {
      if (!_quickJsAvailable) return;
      final configsDirectory = _findConfigsDirectory();
      expect(configsDirectory, isNotNull);
      final file = File(file_path.join(configsDirectory!.path, 'picacg.js'));
      final sourceCode = (await file.readAsString()).replaceFirst(
        '    // Debug scan state is deliberately local to this Source instance.  It is',
        '''    saveData(dataKey, data) {
        return sendMessage({
            method: "save_data",
            key: this.key,
            data_key: dataKey,
            data: data,
        }).then(() => new Promise((resolve) => setTimeout(resolve, 50)))
    }

    // Debug scan state is deliberately local to this Source instance.  It is''',
      );
      final source = await ComicSourceParser().parse(
        sourceCode,
        file.path,
        loadData: false,
        scheduleInit: false,
      );
      source.data = <String, dynamic>{
        'account': ['user@example.test', 'password'],
        'token': 'old-token',
      };
      final manager = ComicSourceManager();
      manager.add(source);
      addTearDown(() => manager.remove(source.key));

      var getCount = 0;
      var postCount = 0;
      final adapter = JsScanSourceAdapter(
        sourceKey: source.key,
        definitionRevision: source.version,
        capabilities: source.scan!,
        requestFactory: (_) => (request) async {
          final parsed = ScanHttpRequest.fromJson(request);
          if (parsed.method == 'POST') {
            postCount++;
            return const {
              'ok': true,
              'response': {
                'status': 200,
                'headers': <String, String>{},
                'body': '{"data":{"token":"new-token"}}',
              },
            };
          }
          getCount++;
          if (getCount <= 2) {
            return const {
              'ok': true,
              'response': {
                'status': 401,
                'headers': <String, String>{},
                'body': '',
              },
            };
          }
          final id = Uri.parse(parsed.url).pathSegments.last;
          return {
            'ok': true,
            'response': {
              'status': 200,
              'headers': <String, String>{},
              'body': jsonEncode({
                'data': {
                  'comic': {'_id': id, 'updated_at': '2026-09-10'},
                },
              }),
            },
          };
        },
      );
      final guard = ScanExecutionGuard(
        sourceKey: source.key,
        sourceInstance: source,
        cacheGeneration: 0,
      );
      final first = adapter.loadComic(
        'bridge-picacg',
        ScanCallLease(guard: guard),
      );
      await Future<void>.delayed(const Duration(milliseconds: 15));
      final second = adapter.loadComic(
        'bridge-picacg-2',
        ScanCallLease(guard: guard),
      );
      final results = await Future.wait([first, second]);

      expect(
        results.every((value) => value is Map && value['observation'] != null),
        isTrue,
      );
      expect(postCount, 1);
      expect(getCount, 4);
      expect(source.data['token'], 'new-token');
    },
    skip: _quickJsAvailable
        ? null
        : 'flutter_qjs native library is unavailable',
  );

  test(
    'real QuickJS same-token refresh advances generation before a late 401',
    () async {
      if (!_quickJsAvailable) return;
      final configsDirectory = _findConfigsDirectory();
      expect(configsDirectory, isNotNull);
      final file = File(file_path.join(configsDirectory!.path, 'picacg.js'));
      final sourceCode = (await file.readAsString()).replaceFirst(
        '    // Debug scan state is deliberately local to this Source instance.  It is',
        '''    saveData(dataKey, data) {
        return sendMessage({
            method: "save_data",
            key: this.key,
            data_key: dataKey,
            data: data,
        }).then(() => new Promise((resolve) => setTimeout(resolve, 50)))
    }

    // Debug scan state is deliberately local to this Source instance.  It is''',
      );
      final source = await ComicSourceParser().parse(
        sourceCode,
        file.path,
        loadData: false,
        scheduleInit: false,
      );
      source.data = <String, dynamic>{
        'account': ['user@example.test', 'password'],
        'token': 'old-token',
      };
      final manager = ComicSourceManager();
      manager.add(source);
      addTearDown(() => manager.remove(source.key));

      final postStarted = Completer<void>();
      final late401Started = Completer<void>();
      final late401Gate = Completer<void>();
      final counts = <String, int>{};
      var postCount = 0;
      final adapter = JsScanSourceAdapter(
        sourceKey: source.key,
        definitionRevision: source.version,
        capabilities: source.scan!,
        requestFactory: (_) => (request) async {
          final parsed = ScanHttpRequest.fromJson(request);
          if (parsed.method == 'POST') {
            postCount++;
            if (!postStarted.isCompleted) postStarted.complete();
            return const {
              'ok': true,
              'response': {
                'status': 200,
                'headers': <String, String>{},
                'body': '{"data":{"token":"old-token"}}',
              },
            };
          }
          final id = Uri.parse(parsed.url).pathSegments.last;
          final count = (counts[id] ?? 0) + 1;
          counts[id] = count;
          if (id == 'same-late' && count == 1) {
            if (!late401Started.isCompleted) late401Started.complete();
            await late401Gate.future;
            return const {
              'ok': true,
              'response': {
                'status': 401,
                'headers': <String, String>{},
                'body': '',
              },
            };
          }
          if (count == 1) {
            return const {
              'ok': true,
              'response': {
                'status': 401,
                'headers': <String, String>{},
                'body': '',
              },
            };
          }
          return {
            'ok': true,
            'response': {
              'status': 200,
              'headers': <String, String>{},
              'body': jsonEncode({
                'data': {
                  'comic': {'_id': id, 'updated_at': '2026-09-10'},
                },
              }),
            },
          };
        },
      );
      final guard = ScanExecutionGuard(
        sourceKey: source.key,
        sourceInstance: source,
        cacheGeneration: 0,
      );
      final creator = adapter.loadComic(
        'same-creator',
        ScanCallLease(guard: guard),
      );
      await postStarted.future;
      final late = adapter.loadComic('same-late', ScanCallLease(guard: guard));
      await late401Started.future;

      final creatorResult = await creator as Map;
      expect(creatorResult['observation'], isA<Map>());
      expect(
        JsEngine().runCode(
          'ComicSource.sources.picacg._scanAuthState.generation',
        ),
        1,
      );
      expect(
        JsEngine().runCode('ComicSource.sources.picacg._scanAuthState.refresh'),
        isNull,
      );
      expect(postCount, 1);

      late401Gate.complete();
      final lateResult = await late as Map;
      expect(lateResult['observation'], isA<Map>());
      expect(counts['same-creator'], 2);
      expect(counts['same-late'], 2);
      expect(postCount, 1);
    },
    skip: _quickJsAvailable
        ? null
        : 'flutter_qjs native library is unavailable',
  );

  test(
    'real Host Picacg refresh timeout and waiter cancellation are isolated',
    () async {
      if (!_quickJsAvailable) return;
      final configsDirectory = _findConfigsDirectory();
      expect(configsDirectory, isNotNull);
      final file = File(file_path.join(configsDirectory!.path, 'picacg.js'));
      final oldProxy = appdata.settings['proxy'];
      appdata.settings['proxy'] = 'direct';
      final cookieDirectory = await Directory.systemTemp.createTemp(
        'venera-picacg-host-',
      );
      SingleInstanceCookieJar(
        file_path.join(cookieDirectory.path, 'cookies.db'),
      );
      final cache = NetworkCacheManager.instance;
      cache.clear();
      addTearDown(() {
        appdata.settings['proxy'] = oldProxy;
        cache.clear();
        SingleInstanceCookieJar.instance?.dispose();
        if (cookieDirectory.existsSync()) {
          cookieDirectory.deleteSync(recursive: true);
        }
      });

      Future<void> withSource(Future<void> Function(ComicSource) body) async {
        final source = await ComicSourceParser().parse(
          await file.readAsString(),
          file.path,
          loadData: false,
          scheduleInit: false,
        );
        source.data = <String, dynamic>{
          'account': ['user@example.test', 'password'],
          'token': 'old-token',
          'settings': {'base_url': 'https://pica.example.invalid'},
        };
        final manager = ComicSourceManager();
        manager.add(source);
        try {
          await body(source);
        } finally {
          manager.remove(source.key);
        }
      }

      await withSource((source) async {
        final context = _publishedContext('picacg-host-timeout');
        final first = _HostTestAdapter(status: 401);
        final creator = _HostTestAdapter.pending();
        final plan = <_HostTestAdapter>[first, creator];
        final engine = JsEngine();
        engine.setScanIoAdapterFactoryForTesting((_) => plan.removeAt(0));
        final limits = const ScanLimits(
          jsCallTimeout: Duration(seconds: 1),
          // Keep enough scheduling slack when the complete scan_kernel suite
          // is running alongside Widget tests; the pending adapter still
          // makes this an unambiguous request-timeout case.
          requestTimeout: Duration(milliseconds: 100),
        );
        final adapter = _hostPicacgAdapter(source, context, limits);
        final lease = ScanCallLease(
          guard: _hostGuard(source, context),
          timeout: const Duration(seconds: 1),
        );

        final result = await adapter.loadComic('host-timeout', lease) as Map;

        expect(
          (result['failure'] as Map)['exceptionType'],
          'ScanRequestTimeout',
        );
        expect(first.request?.method, 'GET');
        expect(creator.request?.method, 'POST');
        expect(creator.canceled, isTrue);
        expect(plan, isEmpty);
        expect(context.revokeListenerCount, 0);
        context.revoke();
        engine.setScanIoAdapterFactoryForTesting(null);
      });

      await withSource((source) async {
        final context = _publishedContext('picacg-host-control');
        final first = _HostTestAdapter(status: 401);
        final creator = _HostTestAdapter.pending();
        final plan = <_HostTestAdapter>[first, creator];
        final engine = JsEngine();
        engine.setScanIoAdapterFactoryForTesting((_) => plan.removeAt(0));
        final adapter = _hostPicacgAdapter(
          source,
          context,
          const ScanLimits(
            jsCallTimeout: Duration(seconds: 1),
            requestTimeout: Duration(seconds: 1),
          ),
        );
        final lease = ScanCallLease(
          guard: _hostGuard(source, context),
          timeout: const Duration(seconds: 1),
        );
        final work = adapter.loadComic('host-control', lease);
        await creator.started.future;

        lease.close(
          reason: ScanLeaseCloseReason.controlCanceled,
          controlReason: ScanControlReason.userCanceled,
        );
        await expectLater(
          work,
          throwsA(
            isA<ScanControlException>().having(
              (error) => error.reason,
              'reason',
              ScanControlReason.userCanceled,
            ),
          ),
        );

        expect(creator.canceled, isTrue);
        expect(plan, isEmpty);
        await _waitForNoRevokeListeners(context);
        expect(context.revokeListenerCount, 0);
        context.revoke();
        engine.setScanIoAdapterFactoryForTesting(null);
      });

      await withSource((source) async {
        final context = _publishedContext('picacg-host-waiter');
        final first = _HostTestAdapter(status: 401);
        final second = _HostTestAdapter(status: 401);
        final creator = _HostTestAdapter.pending();
        final retry = _HostTestAdapter(
          status: 200,
          body: jsonEncode({
            'data': {
              'comic': {'_id': 'host-creator', 'updated_at': '2026-09-10'},
            },
          }),
        );
        final plan = <_HostTestAdapter>[first, second, creator, retry];
        final engine = JsEngine();
        engine.setScanIoAdapterFactoryForTesting((_) => plan.removeAt(0));
        final limits = const ScanLimits(
          jsCallTimeout: Duration(seconds: 1),
          requestTimeout: Duration(seconds: 1),
        );
        final adapter = _hostPicacgAdapter(source, context, limits);
        final creatorLease = ScanCallLease(
          guard: _hostGuard(source, context),
          timeout: const Duration(seconds: 1),
        );
        final waiterLease = ScanCallLease(
          guard: _hostGuard(source, context),
          timeout: const Duration(seconds: 1),
        );
        final creatorWork = adapter.loadComic('host-creator', creatorLease);
        final waiterWork = adapter.loadComic('host-waiter', waiterLease);
        await creator.started.future;
        await second.started.future;

        waiterLease.close(
          reason: ScanLeaseCloseReason.controlCanceled,
          controlReason: ScanControlReason.userCanceled,
        );
        await expectLater(
          waiterWork,
          throwsA(
            isA<ScanControlException>().having(
              (error) => error.reason,
              'reason',
              ScanControlReason.userCanceled,
            ),
          ),
        );

        creator.complete(
          status: 200,
          body: '{"data":{"token":"shared-token"}}',
        );
        final creatorResult = await creatorWork as Map;

        expect(creatorResult['observation'], isA<Map>());
        expect(creator.canceled, isFalse);
        expect(plan, isEmpty);
        expect(
          [
            first.request,
            second.request,
            creator.request,
            retry.request,
          ].map((request) => request?.method).toList(),
          ['GET', 'GET', 'POST', 'GET'],
        );
        expect(context.revokeListenerCount, 0);
        context.revoke();
        engine.setScanIoAdapterFactoryForTesting(null);
      });
    },
    skip: _quickJsAvailable
        ? null
        : 'flutter_qjs native library is unavailable',
  );

  test(
    'real Host Picacg ignores a late 401 after token or account changes',
    () async {
      if (!_quickJsAvailable) return;
      final configsDirectory = _findConfigsDirectory();
      expect(configsDirectory, isNotNull);
      final file = File(file_path.join(configsDirectory!.path, 'picacg.js'));
      final oldProxy = appdata.settings['proxy'];
      appdata.settings['proxy'] = 'direct';
      final cookieDirectory = await Directory.systemTemp.createTemp(
        'venera-picacg-race-',
      );
      SingleInstanceCookieJar(
        file_path.join(cookieDirectory.path, 'cookies.db'),
      );
      final engine = JsEngine();
      final cache = NetworkCacheManager.instance;
      cache.clear();
      addTearDown(() {
        appdata.settings['proxy'] = oldProxy;
        cache.clear();
        engine.setScanIoAdapterFactoryForTesting(null);
        SingleInstanceCookieJar.instance?.dispose();
        if (cookieDirectory.existsSync()) {
          cookieDirectory.deleteSync(recursive: true);
        }
      });

      Future<ComicSource> createSource() async {
        final source = await ComicSourceParser().parse(
          await file.readAsString(),
          file.path,
          loadData: false,
          scheduleInit: false,
        );
        source.data = <String, dynamic>{
          'account': ['user@example.test', 'password'],
          'token': 'old-token',
          'settings': {'base_url': 'https://pica.example.invalid'},
        };
        ComicSourceManager().add(source);
        return source;
      }

      final tokenContext = _publishedContext('picacg-host-token-race');
      final tokenSource = await createSource();
      try {
        final first = _HostTestAdapter(
          status: 401,
          onFetch: (_) => tokenSource.data['token'] = 'ordinary-token',
        );
        final retry = _HostTestAdapter(
          status: 200,
          body: jsonEncode({
            'data': {
              'comic': {'_id': 'token-race', 'updated_at': '2026-09-10'},
            },
          }),
        );
        final plan = <_HostTestAdapter>[first, retry];
        engine.setScanIoAdapterFactoryForTesting((_) => plan.removeAt(0));
        final limits = const ScanLimits(requestTimeout: Duration(seconds: 1));
        final result =
            await _hostPicacgAdapter(
                  tokenSource,
                  tokenContext,
                  limits,
                ).loadComic(
                  'token-race',
                  ScanCallLease(guard: _hostGuard(tokenSource, tokenContext)),
                )
                as Map;

        expect(result['observation'], isA<Map>());
        expect(first.request?.headers['authorization'], 'old-token');
        expect(retry.request?.headers['authorization'], 'ordinary-token');
        expect(plan, isEmpty);
      } finally {
        ComicSourceManager().remove(tokenSource.key);
        tokenContext.revoke();
      }

      final accountContext = _publishedContext('picacg-host-account-race');
      final accountSource = await createSource();
      try {
        final first = _HostTestAdapter(
          status: 401,
          onFetch: (_) => accountSource.data['account'] = [
            'new@example.test',
            'new-password',
          ],
        );
        final plan = <_HostTestAdapter>[first];
        engine.setScanIoAdapterFactoryForTesting((_) => plan.removeAt(0));
        final result =
            await _hostPicacgAdapter(
                  accountSource,
                  accountContext,
                  const ScanLimits(),
                ).loadComic(
                  'account-race',
                  ScanCallLease(
                    guard: _hostGuard(accountSource, accountContext),
                  ),
                )
                as Map;

        expect(
          (result['failure'] as Map)['message'],
          'Picacg account is unavailable',
        );
        expect(first.request?.method, 'GET');
        expect(plan, isEmpty);
      } finally {
        ComicSourceManager().remove(accountSource.key);
        accountContext.revoke();
      }
    },
    skip: _quickJsAvailable
        ? null
        : 'flutter_qjs native library is unavailable',
  );

  test(
    'real managed Picacg parser binds context across publish and replacement',
    () async {
      if (!_quickJsAvailable) return;
      final configsDirectory = _findConfigsDirectory();
      expect(configsDirectory, isNotNull);
      final file = File(file_path.join(configsDirectory!.path, 'picacg.js'));
      final manager = ComicSourceManager();
      final previousSources = manager.all();
      final oldProxy = appdata.settings['proxy'];
      appdata.settings['proxy'] = 'direct';
      final cookieDirectory = await Directory.systemTemp.createTemp(
        'venera-managed-picacg-',
      );
      SingleInstanceCookieJar(
        file_path.join(cookieDirectory.path, 'cookies.db'),
      );
      final engine = JsEngine();
      final oldResponse = _HostTestAdapter(
        status: 200,
        body: jsonEncode({
          'data': {
            'comic': {'_id': 'managed-old', 'updated_at': '2026-09-10'},
          },
        }),
      );
      final newResponse = _HostTestAdapter(
        status: 200,
        body: jsonEncode({
          'data': {
            'comic': {'_id': 'managed-new', 'updated_at': '2026-09-10'},
          },
        }),
      );
      final plan = <_HostTestAdapter>[oldResponse, newResponse];
      engine.setScanIoAdapterFactoryForTesting((_) => plan.removeAt(0));
      final repositoryDirectory = await Directory.systemTemp.createTemp(
        'venera-managed-picacg-db-',
      );
      final repository = SqliteScanResultRepository(
        databasePath: file_path.join(
          repositoryDirectory.path,
          'scan_results.db',
        ),
      );
      _ManagedPicacgFixture? oldFixture;
      _ManagedPicacgFixture? replacementFixture;
      try {
        final sourceCode = await file.readAsString();
        final data = <String, dynamic>{
          'account': <String>['user@example.test', 'password'],
          'token': 'old-token',
          'settings': <String, dynamic>{
            'base_url': 'https://pica.example.invalid',
          },
        };
        oldFixture = await _prepareManagedPicacg(
          sourceCode: sourceCode,
          data: data,
        );
        final old = oldFixture;
        expect(old.context.phase, ManagedSourcePhase.preparing);
        expect(old.source.runtimeContext, same(old.context));

        final limits = const ScanLimits(
          jsCallTimeout: Duration(seconds: 1),
          requestTimeout: Duration(seconds: 1),
        );
        final oldAdapter = _hostPicacgAdapter(old.source, old.context, limits);
        expect(oldAdapter.runtimeContext, same(old.source.runtimeContext));
        await expectLater(
          oldAdapter.loadComic(
            'pre-publish',
            ScanCallLease(guard: _hostGuard(old.source, old.context)),
          ),
          throwsA(isA<ScanControlException>()),
        );
        expect(plan, hasLength(2));

        old.runtime.publish();
        expect(old.context.phase, ManagedSourcePhase.published);
        expect(manager.find('picacg'), same(old.source));

        final consumer = ScanEmissionConsumer(repository: repository);
        final executor = ScanExecutor(repository: repository, limits: limits);
        final oldOutcome = await executor.execute(
          ScanWorkSpec.comic(
            source: old.source,
            adapter: oldAdapter,
            comicId: 'managed-old',
          ).toWork(_hostGuard(old.source, old.context)),
          emit: (emission, context) => consumer.consume(emission, context),
        );
        expect(oldOutcome.status, ScanWorkOutcomeStatus.completed);
        expect(oldResponse.request?.method, 'GET');

        replacementFixture = await _prepareManagedPicacg(
          sourceCode: sourceCode,
          data: data,
        );
        final replacement = replacementFixture;
        expect(replacement.context.phase, ManagedSourcePhase.preparing);
        replacement.runtime.publish();
        expect(replacement.source.runtimeContext, same(replacement.context));
        expect(manager.find('picacg'), same(replacement.source));
        old.runtime.dispose();
        expect(old.context.phase, ManagedSourcePhase.revoked);

        final lateOldWork = ScanWorkSpec.comic(
          source: old.source,
          adapter: oldAdapter,
          comicId: 'managed-late',
        ).toWork(_hostGuard(old.source, old.context));
        await expectLater(
          executor.execute(
            lateOldWork,
            emit: (emission, context) => consumer.consume(emission, context),
          ),
          throwsA(isA<ScanControlException>()),
        );

        final newAdapter = _hostPicacgAdapter(
          replacement.source,
          replacement.context,
          limits,
        );
        final newOutcome = await executor.execute(
          ScanWorkSpec.comic(
            source: replacement.source,
            adapter: newAdapter,
            comicId: 'managed-new',
          ).toWork(_hostGuard(replacement.source, replacement.context)),
          emit: (emission, context) => consumer.consume(emission, context),
        );
        expect(newOutcome.status, ScanWorkOutcomeStatus.completed);
        expect(newResponse.request?.method, 'GET');
        expect(plan, isEmpty);
        expect(
          await repository.readLatestItem('picacg', 'managed-old'),
          isNotNull,
        );
        expect(
          await repository.readLatestItem('picacg', 'managed-late'),
          isNull,
        );
        expect(
          await repository.readLatestItem('picacg', 'managed-new'),
          isNotNull,
        );
      } finally {
        final replacement = replacementFixture;
        final old = oldFixture;
        if (replacement != null) replacement.runtime.dispose();
        if (old != null) old.runtime.dispose();
        manager.installPreparedSources(previousSources);
        engine.setScanIoAdapterFactoryForTesting(null);
        await repository.close();
        if (repositoryDirectory.existsSync()) {
          await repositoryDirectory.delete(recursive: true);
        }
        if (replacement != null && replacement.root.existsSync()) {
          await replacement.root.delete(recursive: true);
        }
        if (old != null && old.root.existsSync()) {
          await old.root.delete(recursive: true);
        }
        appdata.settings['proxy'] = oldProxy;
        SingleInstanceCookieJar.instance?.dispose();
        if (cookieDirectory.existsSync()) {
          await cookieDirectory.delete(recursive: true);
        }
      }
    },
    skip: _quickJsAvailable
        ? null
        : 'flutter_qjs native library is unavailable',
  );

  test(
    'real managed Picacg creator stop leaves a valid waiter as failure',
    () async {
      if (!_quickJsAvailable) return;
      final configsDirectory = _findConfigsDirectory();
      expect(configsDirectory, isNotNull);
      final file = File(file_path.join(configsDirectory!.path, 'picacg.js'));
      final sourceCode = await file.readAsString();
      final data = <String, dynamic>{
        'account': <String>['user@example.test', 'password'],
        'token': 'old-token',
        'settings': <String, dynamic>{
          'base_url': 'https://pica.example.invalid',
        },
      };
      final manager = ComicSourceManager();
      final previousSources = manager.all();
      final oldProxy = appdata.settings['proxy'];
      appdata.settings['proxy'] = 'direct';
      final cookieDirectory = await Directory.systemTemp.createTemp(
        'venera-managed-picacg-race-',
      );
      SingleInstanceCookieJar(
        file_path.join(cookieDirectory.path, 'cookies.db'),
      );
      final engine = JsEngine();
      Future<void> seedCommittedResult(ScanResultRepository repository) async {
        final scope = await repository.beginScope(
          sourceKey: 'picacg',
          producer: ScanProducer.comic,
          scopeKey: 'keep',
          definitionRevision: 'rev',
        );
        final item = ScanItemResult.observed(
          attemptId: scanUuidV5(scope.scopeAttemptId, 'keep'),
          scopeAttemptId: scope.scopeAttemptId,
          sourceKey: 'picacg',
          comicId: 'keep',
          producer: ScanProducer.comic,
          definitionRevision: 'rev',
          observedAt: '2026-09-10T00:00:00.000Z',
          observation: ScanObservation(
            update: UpdateDescriptor(latestChapterId: 'kept'),
          ),
        );
        final context = ScanIngestionContext(scope: scope);
        await repository.saveItem(context, item);
        await repository.finishScope(context, ScanScopeStatus.completed);
      }

      try {
        for (final mode in [
          ScanLeaseCloseReason.deadline,
          ScanLeaseCloseReason.controlCanceled,
        ]) {
          final databaseDirectory = await Directory.systemTemp.createTemp(
            'venera-managed-picacg-race-db-',
          );
          final repository = SqliteScanResultRepository(
            databasePath: file_path.join(
              databaseDirectory.path,
              'scan_results.db',
            ),
          );
          _ManagedPicacgFixture? fixture;
          try {
            fixture = await _prepareManagedPicacg(
              sourceCode: sourceCode,
              data: data,
            );
            final managed = fixture;
            managed.runtime.publish();
            final baselineListeners = managed.context.revokeListenerCount;
            await seedCommittedResult(repository);

            final first = _HostTestAdapter(status: 401);
            final second = _HostTestAdapter(status: 401);
            final creatorRequest = _HostTestAdapter.pending();
            final plan = <_HostTestAdapter>[first, creatorRequest, second];
            engine.setScanIoAdapterFactoryForTesting((_) => plan.removeAt(0));
            final limits = const ScanLimits(
              jsCallTimeout: Duration(seconds: 1),
              requestTimeout: Duration(seconds: 1),
            );
            final adapter = _hostPicacgAdapter(
              managed.source,
              managed.context,
              limits,
            );
            final leases = <ScanCallLease>[];
            final executor = ScanExecutor(
              repository: repository,
              limits: limits,
              onLeaseCreated: leases.add,
            );
            final consumer = ScanEmissionConsumer(repository: repository);
            final creatorWork = ScanWorkSpec.comic(
              source: managed.source,
              adapter: adapter,
              comicId: 'creator-${mode.name}',
            ).toWork(_hostGuard(managed.source, managed.context));
            final waiterWork = ScanWorkSpec.comic(
              source: managed.source,
              adapter: adapter,
              comicId: 'waiter-${mode.name}',
            ).toWork(_hostGuard(managed.source, managed.context));

            final creator = executor.execute(
              creatorWork,
              emit: (emission, context) => consumer.consume(emission, context),
            );
            await _waitForLeaseCount(leases, 1);
            await first.started.future;
            await creatorRequest.started.future;

            final waiter = executor.execute(
              waiterWork,
              emit: (emission, context) => consumer.consume(emission, context),
            );
            await _waitForLeaseCount(leases, 2);
            await second.started.future;
            await Future<void>.delayed(const Duration(milliseconds: 1));

            final creatorLease = leases.first;
            if (mode == ScanLeaseCloseReason.deadline) {
              creatorLease.close(reason: ScanLeaseCloseReason.deadline);
            } else {
              creatorLease.close(
                reason: ScanLeaseCloseReason.controlCanceled,
                controlReason: ScanControlReason.userCanceled,
              );
            }
            final outcomes = await Future.wait([creator, waiter]);
            final creatorOutcome = outcomes[0];
            final waiterOutcome = outcomes[1];

            expect(creatorRequest.canceled, isTrue);
            expect(plan, isEmpty);
            expect(waiterOutcome.status, ScanWorkOutcomeStatus.failed);
            expect(waiterOutcome.persistedItems, 1);
            expect(waiterOutcome.failure, isNotNull);
            expect(
              creatorOutcome.status,
              mode == ScanLeaseCloseReason.deadline
                  ? ScanWorkOutcomeStatus.failed
                  : ScanWorkOutcomeStatus.canceled,
            );
            expect(
              creatorOutcome.persistedItems,
              mode == ScanLeaseCloseReason.deadline ? 1 : 0,
            );
            if (mode == ScanLeaseCloseReason.deadline) {
              expect(creatorOutcome.failure?.exceptionType, 'ScanCallTimeout');
              expect(
                (await repository.readLatestItem(
                  'picacg',
                  'creator-${mode.name}',
                ))!.result.failure?.exceptionType,
                'ScanCallTimeout',
              );
            } else {
              expect(
                await repository.readLatestItem(
                  'picacg',
                  'creator-${mode.name}',
                ),
                isNull,
              );
            }
            expect(
              await repository.readLatestItem('picacg', 'waiter-${mode.name}'),
              isNotNull,
            );
            expect(
              await repository.readLatestItem('picacg', 'unrelated'),
              isNull,
            );
            expect(managed.context.revokeListenerCount, baselineListeners);

            expect(
              await repository.readLatestItem('picacg', 'keep'),
              isNotNull,
            );
          } finally {
            final managed = fixture;
            if (managed != null) managed.runtime.dispose();
            manager.installPreparedSources(previousSources);
            engine.setScanIoAdapterFactoryForTesting(null);
            await repository.close();
            if (databaseDirectory.existsSync()) {
              await databaseDirectory.delete(recursive: true);
            }
            if (managed != null && managed.root.existsSync()) {
              await managed.root.delete(recursive: true);
            }
          }
        }
      } finally {
        manager.installPreparedSources(previousSources);
        engine.setScanIoAdapterFactoryForTesting(null);
        appdata.settings['proxy'] = oldProxy;
        SingleInstanceCookieJar.instance?.dispose();
        if (cookieDirectory.existsSync()) {
          await cookieDirectory.delete(recursive: true);
        }
      }
    },
    skip: _quickJsAvailable
        ? null
        : 'flutter_qjs native library is unavailable',
  );
}

class _ManagedPicacgFixture {
  const _ManagedPicacgFixture({
    required this.root,
    required this.runtime,
    required this.source,
    required this.context,
  });

  final Directory root;
  final PreparedRuntime runtime;
  final ComicSource source;
  final ManagedSourceContext context;
}

Future<_ManagedPicacgFixture> _prepareManagedPicacg({
  required String sourceCode,
  required Map<String, dynamic> data,
}) async {
  final root = await Directory.systemTemp.createTemp(
    'venera-managed-picacg-source-',
  );
  final sources = Directory(file_path.join(root.path, 'sources'));
  await sources.create(recursive: true);
  final sourceBytes = Uint8List.fromList(utf8.encode(sourceCode));
  final sourceFile = File(file_path.join(sources.path, 'picacg.js'));
  await sourceFile.writeAsBytes(sourceBytes);
  final entry = CatalogSourceEntry(
    name: 'Picacg',
    key: 'picacg',
    fileName: 'picacg.js',
    version: '1.0.7',
  );
  final indexBytes = utf8.encode(jsonEncode([entry.toJson()]));
  final revision = 'a' * 40;
  final pointer = CatalogPointer(
    catalogId: 'owner/repo',
    revision: revision,
    indexUrl:
        'https://raw.githubusercontent.com/owner/repo/$revision/index.json',
  );
  final snapshot = CatalogSnapshot(
    manifest: CatalogSnapshotManifest(
      pointer: pointer,
      indexSha256: sha256Hex(indexBytes),
      files: [
        CatalogSnapshotFile(
          sourceKey: 'picacg',
          fileName: 'picacg.js',
          size: sourceBytes.length,
          sha256: sha256Hex(sourceBytes),
        ),
      ],
    ),
    indexBytes: indexBytes,
    index: CatalogIndex([entry]),
    rootPath: root.path,
  );
  final manager = ComicSourceManager();
  final previousSources = manager.all();
  final runtime = await CatalogRuntimeLoader.forComicSources().prepare(
    snapshot,
    sourceData: {'picacg': data},
    onPublish: (prepared) {
      manager.installPreparedSources([
        ...previousSources.where((source) => source.key != 'picacg'),
        ...prepared.map((value) => value.value as ComicSource),
      ]);
    },
  );
  final prepared = runtime.sources.single;
  return _ManagedPicacgFixture(
    root: root,
    runtime: runtime,
    source: prepared.value as ComicSource,
    context: prepared.context,
  );
}

Future<void> _waitForLeaseCount(List<ScanCallLease> leases, int count) async {
  for (var attempt = 0; attempt < 100 && leases.length < count; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  if (leases.length < count) {
    throw StateError('expected $count scan leases, got ${leases.length}');
  }
}

JsScanSourceAdapter _hostPicacgAdapter(
  ComicSource source,
  ManagedSourceContext context,
  ScanLimits limits,
) => JsScanSourceAdapter(
  sourceKey: source.key,
  definitionRevision: source.version,
  capabilities: source.scan!,
  runtimeContext: context,
  limits: limits,
  requestFactory: (lease) =>
      (request) => JsEngine().requestForScan(
        request,
        context,
        lease: lease,
        limits: limits,
      ),
);

ScanExecutionGuard _hostGuard(
  ComicSource source,
  ManagedSourceContext context,
) => ScanExecutionGuard(
  sourceKey: source.key,
  sourceInstance: source,
  runtimeContext: context,
  cacheGeneration: 0,
);

ManagedSourceContext _publishedContext(String key) {
  final snapshot = CatalogSnapshot(
    manifest: CatalogSnapshotManifest(
      pointer: CatalogPointer(
        catalogId: 'owner/repo',
        revision: 'a' * 40,
        indexUrl:
            'https://raw.githubusercontent.com/owner/repo/${'a' * 40}/index.json',
      ),
      indexSha256: '0' * 64,
      files: const [],
    ),
    indexBytes: const [],
    index: CatalogIndex.fromJson([]),
    rootPath: Directory.systemTemp.path,
  );
  final context = ManagedSourceContext(snapshot: snapshot, sourceKey: key);
  context.publish();
  return context;
}

Future<void> _waitForNoRevokeListeners(ManagedSourceContext context) async {
  for (
    var attempt = 0;
    attempt < 100 && context.revokeListenerCount != 0;
    attempt++
  ) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Directory? _findConfigsDirectory() {
  var current = Directory.current;
  for (var depth = 0; depth < 4; depth++) {
    final candidate = Directory(file_path.join(current.path, 'venera-configs'));
    if (candidate.existsSync()) return candidate;
    current = current.parent;
  }
  return null;
}

class _HostTestAdapter implements HttpClientAdapter {
  _HostTestAdapter({this.status = 200, this.body = '', this.onFetch})
    : pending = false;

  _HostTestAdapter.pending()
    : status = 200,
      body = '',
      onFetch = null,
      pending = true;

  final int status;
  final String body;
  final void Function(RequestOptions options)? onFetch;
  final bool pending;
  final started = Completer<void>();
  RequestOptions? request;
  bool canceled = false;
  Completer<ResponseBody>? _pendingResponse;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    if (!started.isCompleted) started.complete();
    onFetch?.call(options);
    if (pending) {
      final response = Completer<ResponseBody>();
      _pendingResponse = response;
      cancelFuture?.then((_) {
        canceled = true;
        if (!response.isCompleted) {
          response.completeError(
            DioException(
              requestOptions: options,
              type: DioExceptionType.cancel,
            ),
          );
        }
      });
      return response.future;
    }
    return _response();
  }

  void complete({required int status, required String body}) {
    final response = _pendingResponse;
    if (response == null || response.isCompleted) return;
    response.complete(
      ResponseBody(
        Stream<Uint8List>.value(Uint8List.fromList(utf8.encode(body))),
        status,
      ),
    );
  }

  Future<ResponseBody> _response() async => ResponseBody(
    Stream<Uint8List>.value(Uint8List.fromList(utf8.encode(body))),
    status,
  );

  @override
  void close({bool force = false}) {}
}

final bool _quickJsAvailable = _canLoadQuickJs();

bool _canLoadQuickJs() {
  try {
    DynamicLibrary.open('flutter_qjs_plugin.dll');
    return true;
  } catch (_) {
    return false;
  }
}
