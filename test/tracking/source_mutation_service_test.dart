import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/network/cookie_jar.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/tracking/cloud_tracking_coordinator.dart';
import 'package:venera/foundation/tracking/source_mutation_service.dart';
import 'package:venera/foundation/tracking/source_revision_store.dart';
import 'package:venera/foundation/tracking/source_runtime_policy.dart';
import 'package:venera/foundation/tracking/trusted_catalog.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late NetworkFavoriteCacheManager favorites;
  late CloudTrackingCoordinator coordinator;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-mutation-gate-');
    favorites = NetworkFavoriteCacheManager.forTesting();
    coordinator = CloudTrackingCoordinator(
      favorites: favorites,
      sourceDirectory: root,
    );
    sourceRuntimePolicy.prepare(
      cloudEnabled: true,
      registry: const ActiveArtifactRegistry(),
      sourceDirectoryPath: root.path,
    );
    sourceRuntimePolicy.requestMode(cloudEnabled: true, operationEpoch: 1);
  });

  tearDown(() async {
    SingleInstanceCookieJar.instance?.dispose();
    SingleInstanceCookieJar.instance = null;
    coordinator.dispose();
    sourceRuntimePolicy.revokeAll();
    sourceRuntimePolicy.cloudEnabled = false;
    sourceRuntimePolicy.pendingCloudEnable = false;
    sourceRuntimePolicy.admissionReady = true;
    sourceRuntimePolicy.registry = null;
    sourceRuntimePolicy.sourceDirectoryPath = null;
    await root.delete(recursive: true);
  });

  test(
    'shared mutation service rejects direct custom writes while Cloud owns runtimes',
    () async {
      final service = SourceMutationService(
        store: SourceRevisionStore(root),
        coordinator: coordinator,
      );

      await expectLater(
        service.addCustom('class Source extends ComicSource {}', 'source.js'),
        throwsA(isA<SourceMutationDenied>()),
      );
      await expectLater(
        service.openEditor(
          const TrustedArtifact(sourceKey: 'source', fileName: 'source.js'),
        ),
        throwsA(isA<SourceMutationDenied>()),
      );
      expect(await root.list().toList(), isEmpty);
    },
  );

  const script = '''
class ExecutionProbe extends ComicSource {
  name = "Execution probe";
  key = "execution_probe";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  ping() { return 42; }
  init() { if (globalThis.report) report("init"); }
}
''';

  Future<ActiveArtifact> prepareProbe({bool candidate = false}) async {
    App.dataPath = root.path;
    await JsEngine().init();
    final bytes = utf8.encode(script);
    final artifact = ActiveArtifact(
      sourceKey: 'execution_probe',
      fileName: 'probe.js',
      revision: null,
      relativePath: 'probe.js',
      origin: ArtifactOrigin.custom,
      sha256: sha256.convert(bytes).toString(),
      activationBlocked: candidate,
    );
    await File('${root.path}/probe.js').writeAsBytes(bytes);
    sourceRuntimePolicy.prepare(
      cloudEnabled: false,
      registry: ActiveArtifactRegistry(artifacts: [artifact]),
      sourceDirectoryPath: root.path,
    );
    return artifact;
  }

  for (final reject in [false, true]) {
    test(
      'destroyed QuickJS domain never resumes pending Promise (reject: $reject)',
      () async {
        await prepareProbe();
        await ComicSourceParser().parse(
          script,
          '${root.path}/probe.js',
          loadData: false,
          scheduleInit: false,
        );
        final context = sourceRuntimePolicy.contextForRuntimeKey(
          'execution_probe',
        )!;
        final host = Completer<void>();
        final events = <String>[];
        final install =
            JsEngine().runCode(
                  '(wait, report) => { globalThis.wait = wait; globalThis.report = report; }',
                  null,
                  context,
                )
                as JSInvokable;
        install([() => host.future, (String event) => events.add(event)]);
        install.free();
        final saved =
            JsEngine().runCode('() => report("saved")', null, context)
                as JSInvokable;
        final pending =
            JsEngine().runCode(
                  '''(async () => {
        try { await wait(); report("then"); }
        catch (_) { report("catch"); }
        finally { report("finally"); }
      })()''',
                  null,
                  context,
                )
                as Future;
        final rejected = expectLater(
          pending,
          throwsA(isA<SourceRuntimeDenied>()),
        );
        JsEngine().runCode(
          'setTimeout(() => report("timer"), 25)',
          null,
          context,
        );
        sourceRuntimePolicy.requestMode(cloudEnabled: true, operationEpoch: 1);
        if (reject) {
          host.completeError(StateError('pending host failure'));
        } else {
          host.complete();
        }
        await rejected;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(events, isEmpty);
        expect(() => saved([]), throwsA(isA<SourceRuntimeDenied>()));
        saved.free();
        sourceRuntimePolicy.prepare(
          cloudEnabled: false,
          registry: const ActiveArtifactRegistry(),
        );
        expect(
          () =>
              JsEngine().runCode('ComicSource.sources.execution_probe.ping()'),
          throwsA(isA<SourceRuntimeDenied>()),
        );
        expect(JsEngine().runCode('1 + 1'), 2);
      },
    );
  }

  test(
    'candidate handoff keeps real methods and delayed init alive after permit release',
    () async {
      final artifact = await prepareProbe(candidate: true);
      final permit = sourceRuntimePolicy.issueCandidatePermit(
        identity: artifact.identity,
        path: '${root.path}/probe.js',
        sha256: artifact.sha256,
        revision: null,
      );
      await ComicSourceParser().parse(
        script,
        '${root.path}/probe.js',
        loadData: false,
        runtimePermit: permit,
      );
      final context = sourceRuntimePolicy.contextForRuntimeKey(
        'execution_probe',
      )!;
      final events = <String>[];
      final install =
          JsEngine().runCode(
                '(report) => { globalThis.report = report; }',
                null,
                context,
              )
              as JSInvokable;
      install([(String event) => events.add(event)]);
      install.free();
      sourceRuntimePolicy.updateRegistry(
        ActiveArtifactRegistry(
          artifacts: [artifact.copyWith(activationBlocked: false)],
        ),
      );
      sourceRuntimePolicy.promoteRuntime(artifact.identity);
      sourceRuntimePolicy.revoke(permit);
      expect(
        sourceRuntimePolicy.permitForPath('${root.path}/probe.js'),
        isNull,
      );
      expect(
        JsEngine().runCode('ComicSource.sources.execution_probe.ping()'),
        42,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(events, ['init']);
      // A failed same-key validation must not replace the active lookup.
      final validation = sourceRuntimePolicy.issueCandidatePermit(
        identity: artifact.identity,
        path: '${root.path}/probe.js',
        sha256: artifact.sha256,
        revision: null,
      );
      await ComicSourceParser().parse(
        script,
        '${root.path}/probe.js',
        register: false,
        allowExistingKey: true,
        loadData: false,
        scheduleInit: false,
        runtimePermit: validation,
      );
      sourceRuntimePolicy.revoke(validation);
      expect(
        sourceRuntimePolicy.contextForRuntimeKey('execution_probe'),
        same(context),
      );
      expect(
        JsEngine().runCode('ComicSource.sources.execution_probe.ping()'),
        42,
      );
    },
  );

  test('source compute is cancelled with its owning execution domain', () async {
    await prepareProbe();
    await ComicSourceParser().parse(
      script,
      '${root.path}/probe.js',
      loadData: false,
      scheduleInit: false,
    );
    final context = sourceRuntimePolicy.contextForRuntimeKey(
      'execution_probe',
    )!;
    final pending =
        JsEngine().runCode(
              'compute("async () => { await new Promise(r => setTimeout(r, 5000)); return 42; }")',
              null,
              context,
            )
            as Future;
    final rejected = expectLater(pending, throwsA(isA<SourceRuntimeDenied>()));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    sourceRuntimePolicy.requestMode(cloudEnabled: true, operationEpoch: 1);
    await rejected;
  });

  test(
    'Cloud enable destroys continuations of an already pending real HTTP request',
    () => HttpOverrides.runWithHttpOverrides(() async {
      await prepareProbe();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      SingleInstanceCookieJar.instance = SingleInstanceCookieJar(
        '${root.path}/cookie.db',
      );
      addTearDown(() {
        SingleInstanceCookieJar.instance?.dispose();
        SingleInstanceCookieJar.instance = null;
      });
      final received = Completer<HttpRequest>();
      var requests = 0;
      server.listen((request) {
        requests++;
        if (!received.isCompleted) received.complete(request);
      });
      await ComicSourceParser().parse(
        script,
        '${root.path}/probe.js',
        loadData: false,
        scheduleInit: false,
      );
      final context = sourceRuntimePolicy.contextForRuntimeKey(
        'execution_probe',
      )!;
      final events = <String>[];
      final install =
          JsEngine().runCode(
                '(report) => { globalThis.report = report; }',
                null,
                context,
              )
              as JSInvokable;
      install([(String event) => events.add(event)]);
      install.free();
      final pending =
          JsEngine().runCode(
                '''Network.sendRequest("GET", "http://127.0.0.1:${server.port}/pending",
      {"http_client": "dart:io"})
      .then(() => report("then")).catch(() => report("catch")).finally(() => report("finally"))''',
                null,
                context,
              )
              as Future;
      final rejected = expectLater(
        pending,
        throwsA(isA<SourceRuntimeDenied>()),
      );
      final request = await received.future.timeout(const Duration(seconds: 5));
      sourceRuntimePolicy.requestMode(cloudEnabled: true, operationEpoch: 1);
      request.response.write('late response');
      try {
        await request.response.close();
      } catch (_) {}
      await rejected;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(events, isEmpty);
      expect(requests, 1);
    }, _RealHttpOverrides()),
  );

  test(
    'real custom install, edit and explicit recovery publish callable runtimes',
    () async {
      App.dataPath = root.path;
      await JsEngine().init();
      final previousMode = appdata.settings['cloudTrackingEnabled'];
      appdata.settings['cloudTrackingEnabled'] = false;
      addTearDown(() {
        appdata.settings['cloudTrackingEnabled'] = previousMode;
      });
      final directory = Directory('${root.path}/comic_source')..createSync();
      final store = SourceRevisionStore(directory);
      final local = CloudTrackingCoordinator(
        favorites: favorites,
        sourceDirectory: directory,
      );
      addTearDown(local.dispose);
      addTearDown(() => ComicSourceManager().remove('execution_probe'));
      sourceRuntimePolicy.prepare(
        cloudEnabled: false,
        registry: const ActiveArtifactRegistry(),
        sourceDirectoryPath: directory.path,
      );
      final service = SourceMutationService(store: store, coordinator: local);
      final installed = await service.addCustom(script, 'probe.js');
      expect(
        JsEngine().runCode('ComicSource.sources.execution_probe.ping()'),
        42,
      );
      final session = await service.openEditor(installed.identity);
      expect(
        await service.commitBuffer(
          session,
          script.replaceFirst('return 42', 'return 99'),
        ),
        isTrue,
      );
      expect(
        JsEngine().runCode('ComicSource.sources.execution_probe.ping()'),
        99,
      );
      final recovery = (await store.load())!.recoverableArtifacts.single;
      await service.restoreCustom(recovery);
      expect(
        JsEngine().runCode('ComicSource.sources.execution_probe.ping()'),
        42,
      );
    },
  );
}
