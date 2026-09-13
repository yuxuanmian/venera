import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_result_repository.dart';
import 'package:venera/foundation/scan/sqlite_scan_result_repository.dart';
import 'package:venera/network/app_dio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('failure persistence keeps only bounded safe diagnostics', () async {
    final directory = await Directory.systemTemp.createTemp(
      'venera-scan-privacy-',
    );
    final repository = SqliteScanResultRepository(
      databasePath: '${directory.path}/scan_results.db',
    );
    addTearDown(() async {
      await repository.close();
      if (directory.existsSync()) await directory.delete(recursive: true);
    });

    await repository.ensureOpen();
    final scope = await repository.beginScope(
      sourceKey: 'source',
      producer: ScanProducer.comic,
      scopeKey: 'comic',
      definitionRevision: 'rev',
    );
    final item = ScanItemResult.failed(
      attemptId: scanUuidV5(scope.scopeAttemptId, 'source\u0000comic'),
      scopeAttemptId: scope.scopeAttemptId,
      sourceKey: 'source',
      comicId: 'comic',
      producer: ScanProducer.comic,
      definitionRevision: 'rev',
      observedAt: '2026-09-10T00:00:00.000Z',
      failure: const ScanFailure(
        httpStatus: 403,
        sourceCode: '{"token":"source-code-secret"}',
        exceptionType: 'DioException token=exception-secret',
        message:
            '{"authorization":"Bearer header-secret",'
            '"cookie":"session=cookie-one; other=cookie-two",'
            '"password":"password-secret"} '
            'Basic basic-secret '
            'https://private.example.invalid/path?token=query-secret '
            '<html><body>response-body-secret</body></html>',
        retryAfter: '2026-09-10T12:00:00Z',
      ),
    );
    await repository.saveItem(ScanIngestionContext(scope: scope), item);

    final encoded = jsonEncode(
      (await repository.readLatestItem('source', 'comic'))!.result.toJson(),
    );
    expect(encoded, contains('403'));
    expect(encoded, contains('2026-09-10'));
    for (final secret in [
      'source-code-secret',
      'exception-secret',
      'header-secret',
      'cookie-one',
      'cookie-two',
      'password-secret',
      'basic-secret',
      'query-secret',
      'response-body-secret',
      'private.example.invalid',
    ]) {
      expect(encoded, isNot(contains(secret)));
    }
  });

  test(
    'failure persistence rejects identifier-shaped secrets and body fragments',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'venera-scan-privacy-codes-',
      );
      final repository = SqliteScanResultRepository(
        databasePath: '${directory.path}/scan_results.db',
      );
      addTearDown(() async {
        await repository.close();
        if (directory.existsSync()) await directory.delete(recursive: true);
      });

      await repository.ensureOpen();
      final scope = await repository.beginScope(
        sourceKey: 'source',
        producer: ScanProducer.comic,
        scopeKey: 'comic-codes',
        definitionRevision: 'rev',
      );
      final item = ScanItemResult.failed(
        attemptId: scanUuidV5(scope.scopeAttemptId, 'source\u0000comic-codes'),
        scopeAttemptId: scope.scopeAttemptId,
        sourceKey: 'source',
        comicId: 'comic-codes',
        producer: ScanProducer.comic,
        definitionRevision: 'rev',
        observedAt: '2026-09-10T00:00:00.000Z',
        failure: const ScanFailure(
          httpStatus: 429,
          sourceCode: 'ToKeN:synthetic-secret',
          exceptionType: 'PASSWORD=synthetic-secret',
          message:
              'diagnostic prefix {"opaque":"json-body-secret"} '
              '<svg><title>markup-body-secret</title></svg>',
          retryAfter: '2026-09-10T12:00:00Z',
        ),
      );
      await repository.saveItem(ScanIngestionContext(scope: scope), item);

      final encoded = jsonEncode(
        (await repository.readLatestItem(
          'source',
          'comic-codes',
        ))!.result.toJson(),
      );
      expect(encoded, contains('429'));
      expect(encoded, contains('2026-09-10'));
      for (final secret in [
        'synthetic-secret',
        'json-body-secret',
        'markup-body-secret',
      ]) {
        expect(encoded, isNot(contains(secret)));
      }
      expect(encoded, isNot(contains('ToKeN')));
      expect(encoded, isNot(contains('PASSWORD')));
    },
  );

  test(
    'AppDio scan transport diagnostics never include request secrets',
    () async {
      final previousMuted = Log.isMuted;
      Log.isMuted = false;
      Log.clear();
      addTearDown(() {
        Log.clear();
        Log.isMuted = previousMuted;
      });

      final dio = AppDio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = _PrivacyAdapter(
          headers: const {
            'set-cookie': ['session=response-header-secret'],
          },
          body: jsonEncode({'body': 'response-body-secret'}),
        )
        ..interceptors.add(MyLogInterceptor());
      addTearDown(() => dio.close(force: true));

      final response = await dio.get<Object?>(
        'https://private.example.invalid/path?token=query-secret',
        options: Options(
          headers: const {
            'authorization': 'Bearer header-secret',
            'cookie': 'session=cookie-secret',
          },
          extra: const {'veneraScan': true},
        ),
      );

      expect(response.statusCode, 200);
      final output = Log.logs.map((item) => item.content).join('\n');
      expect(output, contains('Scan GET status=200'));
      for (final secret in [
        'private.example.invalid',
        'query-secret',
        'header-secret',
        'cookie-secret',
        'response-header-secret',
        'response-body-secret',
        'json-body-secret',
        'markup-body-secret',
      ]) {
        expect(output, isNot(contains(secret)));
      }
    },
  );

  test(
    'source authentication save failure keeps credentials out of errors and logs',
    () async {
      if (!_quickJsAvailable) return;
      final directory = await Directory.systemTemp.createTemp(
        'venera-auth-save-privacy-',
      );
      final invalidDataPath = File(
        '${directory.path}${Platform.pathSeparator}password-secret',
      );
      await invalidDataPath.writeAsString('not a directory');
      String? previousDataPath;
      try {
        previousDataPath = App.dataPath;
      } catch (_) {
        // App.dataPath is a late field in an uninitialized test isolate.
      }
      App.dataPath = invalidDataPath.path;
      const key = 'privacy_auth_save_source';
      Log.clear();
      await JsEngine().init();
      final source = await ComicSourceParser().parse(
        '''
class PrivacyAuthSaveSource extends ComicSource {
  name = "Privacy auth save source";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  account = {
    login: async (account, password) => true,
  };
}
''',
        '$key.js',
        loadData: false,
        scheduleInit: false,
      );
      ComicSourceManager().add(source);
      try {
        final result = await source.account!.login!(
          'account-secret',
          'password-secret',
        );
        expect(result.error, isTrue);
        final output = Log.logs.map((item) => item.content).join('\n');
        expect(output, contains('PathExistsException'));
        expect(result.errorMessage, contains('PathExistsException'));
        for (final secret in [
          'account-secret',
          'password-secret',
          invalidDataPath.path,
        ]) {
          expect(output, isNot(contains(secret)));
          expect(result.errorMessage, isNot(contains(secret)));
        }
      } finally {
        ComicSourceManager().remove(key);
        JsEngine().dispose();
        App.dataPath = previousDataPath ?? directory.path;
        if (directory.existsSync()) await directory.delete(recursive: true);
      }
    },
    skip: _quickJsAvailable
        ? null
        : 'flutter_qjs native library is unavailable',
  );
}

class _PrivacyAdapter implements HttpClientAdapter {
  _PrivacyAdapter({required this.headers, required this.body});

  final Map<String, List<String>> headers;
  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody(
      Stream<Uint8List>.value(Uint8List.fromList(utf8.encode(body))),
      200,
      headers: headers,
    );
  }

  @override
  void close({bool force = false}) {}
}

final _quickJsAvailable = _canLoadQuickJs();

bool _canLoadQuickJs() {
  try {
    DynamicLibrary.open('flutter_qjs_plugin.dll');
    return true;
  } catch (_) {
    return false;
  }
}
