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
  _Transport({this.snapshotError});
  final Object? snapshotError;
  @override
  Future<CatalogBytesResponse> getBytes(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    CatalogCancellationToken? cancellation,
  }) async {
    if (uri.toString() ==
        'https://api.github.com/repos/yuxuanmian/venera-configs/git/ref/heads/yxm') {
      return _body(200, {
        'ref': 'refs/heads/yxm',
        'object': {'type': 'commit', 'sha': 'a' * 40},
      });
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

class _AlwaysThrowsTransport implements CatalogTransport {
  const _AlwaysThrowsTransport(this.error);

  final Object error;

  @override
  Future<CatalogBytesResponse> getBytes(
    Uri uri, {
    required Duration timeout,
    required int maxBytes,
    CatalogCancellationToken? cancellation,
  }) async => throw error;
}

CatalogBytesResponse _body(int status, Object body) =>
    CatalogBytesResponse(status, utf8.encode(jsonEncode(body)));

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
        httpClient: CatalogHttpClient(transport: _Transport()),
      );
  final CatalogStartupResult result;
  @override
  Future<CatalogStartupResult> boot() async => result;
  @override
  Future<CatalogStartupResult> initializeRepository(
    CatalogRepositorySource source,
  ) async => result;
  @override
  Future<CatalogStartupResult> recoverRepository(
    CatalogRepositorySource source,
  ) async => result;
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
    test(
      'offline repository check still boots ${useLkg ? 'LKG' : 'active'}',
      () async {
        final root = await Directory.systemTemp.createTemp('setup-fallback-');
        final oldPath = App.isInitialized ? App.dataPath : null;
        App.dataPath = root.path;
        final target = _ReadOnlyRepairAppdata(root);
        final store = CatalogStore(Directory('${root.path}/catalog'));
        final pointer = CatalogRepositorySource.defaults.pointerForRevision(
          'a' * 40,
        );
        final online = CatalogHttpClient(transport: _Transport());
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
            transport: const _AlwaysThrowsTransport(SocketException('offline')),
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
      },
    );
  }

  final repositoryCases =
      <(Object, CatalogSetupFailureKind, CatalogSetupStage)>[
        (
          const CatalogRepositorySourceException(
            'invalid_repository_url',
            'invalid',
          ),
          CatalogSetupFailureKind.invalidRepositorySource,
          CatalogSetupStage.repositoryHead,
        ),
        (
          const SocketException('private host'),
          CatalogSetupFailureKind.connectionFailed,
          CatalogSetupStage.repositoryHead,
        ),
        (
          const CatalogHttpException('head_query_failed', 'private'),
          CatalogSetupFailureKind.repositoryHeadUnavailable,
          CatalogSetupStage.repositoryHead,
        ),
        (
          const CatalogHttpException('invalid_head_response', 'private'),
          CatalogSetupFailureKind.invalidRepositoryHead,
          CatalogSetupStage.repositoryHead,
        ),
      ];
  for (var i = 0; i < repositoryCases.length; i++) {
    final (error, kind, stage) = repositoryCases[i];
    test('repository setup classification $i: ${kind.name}', () {
      final failure = CatalogSetupFailure.fromError(error, stage);
      expect(failure?.kind, kind);
      expect(failure?.diagnostic, isNot(contains('private')));
    });
  }

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
      final result = await controller.initializeRepository(
        CatalogRepositorySource.defaults,
      );
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
          repositorySource: CatalogRepositorySource.defaults,
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
            repositorySource: CatalogRepositorySource.defaults,
            onReady: (_) {},
          ),
        ),
      );
      await tester.tap(find.text('重试准备'));
      await tester.pumpAndSettle();
      final title = switch (kind) {
        CatalogSetupFailureKind.connectionFailed => '无法连接配置仓库',
        CatalogSetupFailureKind.contentPreparationFailed => '漫画源配置准备失败',
        CatalogSetupFailureKind.invalidRepositorySource => '配置来源无效',
        CatalogSetupFailureKind.repositoryHeadUnavailable => '无法获取配置分支的最新版本',
        CatalogSetupFailureKind.invalidRepositoryHead => '配置仓库返回的分支信息无效',
        CatalogSetupFailureKind.storageUnavailable => '无法保存或读取本地配置',
        CatalogSetupFailureKind.operationInProgress => '另一个配置操作正在进行',
        CatalogSetupFailureKind.cancelled => '配置操作已取消',
      };
      expect(find.textContaining(title), findsOneWidget);
      expect(find.textContaining('UNTRUSTED'), findsNothing);
      expect(find.textContaining('SocketException'), findsNothing);
      expect(find.byType(TextField), findsNWidgets(2));
    });
  }

  testWidgets('cancelled setup has no failure UI', (tester) async {
    final target = Appdata.createForTesting(() async => Directory.systemTemp);
    final controller = _ResultController(
      const CatalogNeedsInitialization(),
      target,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: CatalogBootstrapPage(
          controller: controller,
          repositorySource: CatalogRepositorySource.defaults,
          onReady: (_) {},
        ),
      ),
    );
    await tester.tap(find.text('重试准备'));
    await tester.pumpAndSettle();
    expect(find.textContaining('初始化未完成'), findsNothing);
    expect(find.textContaining('失败'), findsNothing);
  });

  testWidgets('recovery retains saved repository and hides internal error', (
    tester,
  ) async {
    final target = Appdata.createForTesting(() async => Directory.systemTemp);
    final source = CatalogRepositorySource(branch: 'saved-branch');
    target.settings['catalogRepositoryUrl'] = source.repositoryUrl;
    target.settings['catalogRepositoryBranch'] = source.branch;
    final controller = _ResultController(
      CatalogNeedsRecovery('SECRET C:/private SHA', repositorySource: source),
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
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .map((field) => field.controller!.text)
        .toList();
    expect(fields, [source.repositoryUrl, 'saved-branch']);
    expect(find.textContaining('SECRET'), findsNothing);
  });
}
