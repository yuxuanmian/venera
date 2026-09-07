import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/catalog_gate.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/controller.dart';
import 'package:venera/foundation/catalog/http_client.dart';
import 'package:venera/foundation/catalog/models.dart';

import 'package:venera/foundation/catalog/runtime_loader.dart';
import 'package:venera/foundation/catalog/store.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/pages/catalog_bootstrap_page.dart';
import 'package:venera/utils/translations.dart';

class _Transport implements CatalogTransport {
  _Transport(this.authority, {this.snapshotError});
  final Object authority;
  final Object? snapshotError;
  @override
  Future<CatalogBytesResponse> getBytes(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    CatalogCancellationToken? cancellation,
  }) async {
    if (uri.path.endsWith('/authority')) {
      if (authority is CatalogBytesResponse) {
        return authority as CatalogBytesResponse;
      }
      throw authority;
    }
    if (snapshotError != null) throw snapshotError!;
    return CatalogBytesResponse(
      200,
      utf8.encode(
        uri.path.endsWith('index.json')
            ? '[{"name":"Demo","key":"demo","fileName":"demo.js","version":"1"}]'
            : 'source',
      ),
    );
  }
}

CatalogBytesResponse _body(int status, Object body) =>
    CatalogBytesResponse(status, utf8.encode(jsonEncode(body)));

CatalogBytesResponse get _authority => _body(200, {
  'catalogId': 'owner/repo',
  'activeRevision': 'a' * 40,
  'indexUrl':
      'https://raw.githubusercontent.com/owner/repo/${'a' * 40}/index.json',
});

class _ThrowingDio extends AppDio {
  _ThrowingDio(this.type);
  final DioExceptionType type;
  @override
  Future<Response<T>> get<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) async => throw DioException(
    requestOptions: RequestOptions(path: path),
    type: type,
  );
}

class _ResultController extends CatalogController {
  _ResultController(this.result, Appdata target)
    : super(
        store: CatalogStore(Directory.systemTemp),
        appdata: target,
        httpClient: CatalogHttpClient(transport: _Transport(_authority)),
      );
  final CatalogStartupResult result;
  @override
  Future<CatalogStartupResult> boot() async => result;
  @override
  Future<CatalogStartupResult> initialize(String serverUrl) async => result;
}

class _ReadOnlyRepairAppdata extends Appdata {
  _ReadOnlyRepairAppdata(Directory root)
    : super.createForTesting(() async => root);

  @override
  Future<PreparedAppDataCommit> prepareCatalogPointerRepair(
    CatalogPointer pointer,
  ) async {
    throw const FileSystemException('read-only');
  }
}

void main() {
  setUpAll(AppTranslation.init);

  for (final useLkg in [false, true]) {
    test('offline authority still boots ${useLkg ? 'LKG' : 'active'}', () async {
      final root = await Directory.systemTemp.createTemp('setup-fallback-');
      final oldPath = App.isInitialized ? App.dataPath : null;
      App.dataPath = root.path;
      final target = _ReadOnlyRepairAppdata(root);
      final store = CatalogStore(Directory('${root.path}/catalog'));
      final online = CatalogHttpClient(transport: _Transport(_authority));
      final pointer = await online.getAuthority('https://server.example');
      final candidate = await online.downloadSnapshot(
        pointer,
        store: store,
        attempt: CatalogAttempt(
          id: 'seed',
          deadline: DateTime.now().add(const Duration(seconds: 5)),
        ),
      );
      await store.promoteCandidate(candidate);
      target.catalogRuntime = AppCatalogState(
        active: useLkg
            ? CatalogPointer(
                catalogId: 'owner/repo',
                revision: 'b' * 40,
                indexUrl:
                    'https://raw.githubusercontent.com/owner/repo/${'b' * 40}/index.json',
              )
            : pointer,
        lkg: useLkg ? pointer : null,
      ).toJson();
      target.settings['serverUrl'] = 'https://server.example';
      target.settings['enabledSources'] = <String>['demo'];
      final controller = CatalogController(
        store: store,
        appdata: target,
        httpClient: CatalogHttpClient(
          transport: _Transport(const SocketException('offline')),
        ),
      );
      addTearDown(() async {
        controller.dispose();
        if (oldPath != null) App.dataPath = oldPath;
        await root.delete(recursive: true);
      });
      final result = await controller.boot();
      expect(result, isA<CatalogReady>());
      expect((result as CatalogReady).usedLocalFallback, isTrue);
      expect(controller.sessionState?.active, pointer);
      expect(target.settings['enabledSources'], ['demo']);
    });
  }

  final cases = <(String, Object, CatalogSetupFailureKind)>[
    ('invalid-url', _authority, CatalogSetupFailureKind.invalidServerAddress),
    (
      'https://server.example',
      const SocketException('private host'),
      CatalogSetupFailureKind.connectionFailed,
    ),
    (
      'https://server.example',
      const HandshakeException('private TLS'),
      CatalogSetupFailureKind.connectionFailed,
    ),
    (
      'https://server.example',
      const HttpException('private HTTP'),
      CatalogSetupFailureKind.connectionFailed,
    ),
    (
      'https://server.example',
      TimeoutException('private timeout'),
      CatalogSetupFailureKind.connectionFailed,
    ),
    (
      'https://server.example',
      _body(404, {}),
      CatalogSetupFailureKind.incompatibleServer,
    ),
    (
      'https://server.example',
      _body(200, {'hello': 'world'}),
      CatalogSetupFailureKind.incompatibleServer,
    ),
    (
      'https://server.example',
      CatalogBytesResponse(200, utf8.encode('<html>private</html>')),
      CatalogSetupFailureKind.incompatibleServer,
    ),
    for (final status in [502, 503, 504])
      (
        'https://server.example',
        _body(status, {}),
        CatalogSetupFailureKind.connectionFailed,
      ),
    (
      'https://server.example',
      _body(503, {
        'error': {
          'code': 'catalog_not_activated',
          'message': 'UNTRUSTED MESSAGE',
        },
      }),
      CatalogSetupFailureKind.catalogNotActivated,
    ),
    (
      'https://server.example',
      _body(503, {
        'error': {'code': 'catalog_state_invalid', 'message': 'private'},
      }),
      CatalogSetupFailureKind.contentPreparationFailed,
    ),
  ];
  for (var i = 0; i < cases.length; i++) {
    final (url, response, kind) = cases[i];
    test('setup classification $i: ${kind.name}', () async {
      final root = await Directory.systemTemp.createTemp('setup-failure-');
      final target = Appdata.createForTesting(() async => root);
      final controller = CatalogController(
        store: CatalogStore(root),
        appdata: target,
        httpClient: CatalogHttpClient(transport: _Transport(response)),
      );
      addTearDown(() async {
        controller.dispose();
        await root.delete(recursive: true);
      });
      final result = await controller.initialize(url);
      expect(result, isA<CatalogNeedsInitialization>());
      expect((result as CatalogNeedsInitialization).failure?.kind, kind);
    });
  }

  test(
    'HTTP preserves structured code without trusting remote message',
    () async {
      final client = CatalogHttpClient(
        transport: _Transport(
          _body(503, {
            'error': {
              'code': 'catalog_not_activated',
              'message': 'UNTRUSTED MESSAGE',
            },
          }),
        ),
      );
      await expectLater(
        client.getAuthority('https://server.example'),
        throwsA(
          isA<CatalogHttpException>()
              .having((e) => e.code, 'code', 'catalog_not_activated')
              .having(
                (e) => e.toString(),
                'details',
                isNot(contains('UNTRUSTED MESSAGE')),
              ),
        ),
      );
    },
  );

  for (final type in [
    DioExceptionType.connectionError,
    DioExceptionType.badCertificate,
    DioExceptionType.unknown,
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
    DioExceptionType.cancel,
  ]) {
    test('Dio normalization ${type.name}', () async {
      final transport = AppDioCatalogTransport(dio: _ThrowingDio(type));
      final code = type == DioExceptionType.cancel
          ? 'cancelled'
          : type.name.endsWith('Timeout')
          ? 'timeout'
          : 'connection_failed';
      await expectLater(
        transport.getBytes(
          Uri.parse('https://server.example'),
          timeout: const Duration(seconds: 1),
          maxBytes: 100,
        ),
        throwsA(
          isA<CatalogHttpException>().having((e) => e.code, 'code', code),
        ),
      );
    });
  }

  for (final phase in ['download', 'runtime', 'commit']) {
    test('$phase failure keeps its stage semantics', () async {
      final root = await Directory.systemTemp.createTemp('setup-stage-');
      final oldPath = App.isInitialized ? App.dataPath : null;
      App.dataPath = root.path;
      final target = Appdata.createForTesting(() async => root);
      if (phase == 'commit') {
        target.atomicReplace = (_, _) async =>
            throw const FileSystemException('private path');
      }
      final controller = CatalogController(
        store: CatalogStore(Directory('${root.path}/catalog')),
        appdata: target,
        httpClient: CatalogHttpClient(
          transport: _Transport(
            _authority,
            snapshotError: phase == 'download'
                ? TimeoutException('download')
                : null,
          ),
        ),
        runtimeLoader: CatalogRuntimeLoader(
          factory: (_, source, _) {
            if (phase == 'runtime') throw StateError('private JS path SHA');
            return source;
          },
        ),
      );
      addTearDown(() async {
        controller.dispose();
        if (oldPath != null) App.dataPath = oldPath;
        await root.delete(recursive: true);
      });
      final result = await controller.initialize('https://server.example');
      if (phase == 'commit') {
        expect(result, isA<CatalogNeedsRecovery>());
      } else {
        expect(
          (result as CatalogNeedsInitialization).failure?.kind,
          CatalogSetupFailureKind.contentPreparationFailed,
        );
      }
      expect(target.catalogRuntime, isNull);
    });
  }

  for (final kind in CatalogSetupFailureKind.values) {
    testWidgets('safe setup UI ${kind.name}', (tester) async {
      final previousLanguage = appdata.settings['language'];
      appdata.settings['language'] = 'zh-CN';
      final target = Appdata.createForTesting(() async => Directory.systemTemp);
      final controller = _ResultController(
        CatalogNeedsInitialization(
          serverDraft: '',
          failure: CatalogSetupFailure(
            kind,
            diagnostic: 'UNTRUSTED MESSAGE SocketException C:/private SHA',
          ),
        ),
        target,
      );
      addTearDown(() {
        appdata.settings['language'] = previousLanguage;
        controller.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: CatalogBootstrapPage(
            controller: controller,
            serverDraft: 'https://server.example',
            onReady: (_) {},
          ),
        ),
      );
      await tester.tap(find.text('连接并初始化'));
      await tester.pumpAndSettle();
      final title = [
        '服务器地址无效',
        '无法连接服务器',
        '不是兼容的 Venera Server',
        '服务器尚未发布漫画源配置',
        '漫画源配置准备失败',
      ][kind.index];
      expect(find.textContaining(title), findsOneWidget);
      expect(find.textContaining('UNTRUSTED'), findsNothing);
      expect(find.textContaining('SocketException'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
    });
  }

  testWidgets('cancelled setup has no failure UI', (tester) async {
    final target = Appdata.createForTesting(() async => Directory.systemTemp);
    final controller = _ResultController(
      const CatalogNeedsInitialization(serverDraft: ''),
      target,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: CatalogBootstrapPage(
          controller: controller,
          serverDraft: 'https://server.example',
          onReady: (_) {},
        ),
      ),
    );
    await tester.tap(find.text('连接并初始化'));
    await tester.pumpAndSettle();
    expect(find.textContaining('初始化未完成'), findsNothing);
    expect(find.textContaining('失败'), findsNothing);
  });

  testWidgets('recovery retains saved server and hides internal error', (
    tester,
  ) async {
    final target = Appdata.createForTesting(() async => Directory.systemTemp);
    target.settings['serverUrl'] = 'https://saved.example';
    final controller = _ResultController(
      const CatalogNeedsRecovery('SECRET C:/private SHA'),
      target,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: CatalogGate(
          controller: controller,
          ready: (_) => const Text('ready'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'https://saved.example',
    );
    expect(find.textContaining('SECRET'), findsNothing);
  });
}
