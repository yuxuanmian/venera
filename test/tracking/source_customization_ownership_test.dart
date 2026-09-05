import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/tracking/cloud_tracking_coordinator.dart';
import 'package:venera/foundation/tracking/source_mutation_service.dart';
import 'package:venera/foundation/tracking/source_revision_store.dart';
import 'package:venera/foundation/tracking/source_runtime_policy.dart';
import 'package:venera/foundation/tracking/trusted_catalog.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const identity = TrustedArtifact(
    sourceKey: 'custom_ownership',
    fileName: 'custom_ownership.js',
  );
  const source = '''
class CustomOwnership extends ComicSource {
  name = "Custom Ownership";
  key = "custom_ownership";
  version = "1.0.0";
  minAppVersion = "1.0.0";
}
''';

  late Directory root;
  late SourceRevisionStore store;
  late CloudTrackingCoordinator coordinator;
  late ActiveArtifact active;

  setUpAll(() async {
    await AppTranslation.init();
    await JsEngine().init();
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-custom-ownership-');
    App.dataPath = root.path;
    store = SourceRevisionStore(root);
    final bytes = utf8.encode(source);
    active = ActiveArtifact(
      sourceKey: identity.sourceKey,
      fileName: identity.fileName,
      revision: null,
      relativePath: identity.fileName,
      origin: ArtifactOrigin.custom,
      sha256: sha256.convert(bytes).toString(),
    );
    await File('${root.path}/${identity.fileName}').writeAsBytes(bytes);
    await store.save(ActiveArtifactRegistry(artifacts: [active]));
    coordinator = CloudTrackingCoordinator(
      favorites: NetworkFavoriteCacheManager.forTesting(),
      sourceDirectory: root,
    );
    sourceRuntimePolicy.prepare(
      cloudEnabled: false,
      registry: ActiveArtifactRegistry(artifacts: [active]),
      sourceDirectoryPath: root.path,
    );
  });

  tearDown(() async {
    coordinator.dispose();
    sourceRuntimePolicy
      ..revokeAll()
      ..cloudEnabled = false
      ..pendingCloudEnable = false
      ..admissionReady = true
      ..operationEpoch = 0
      ..registry = null
      ..sourceDirectoryPath = null;
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('unchanged editor commit is side-effect free', () async {
    final service = SourceMutationService(
      store: store,
      coordinator: coordinator,
    );
    final session = await service.openEditor(identity);
    final generation = coordinator.generations.generation;

    expect(await service.commitBuffer(session, source), isFalse);
    expect(coordinator.generations.generation, generation);
    expect(await File(session.draftPath).exists(), isFalse);
    expect(
      await File('${root.path}/${identity.fileName}').readAsString(),
      source,
    );
    expect(await store.load(), ActiveArtifactRegistry(artifacts: [active]));
  });

  for (final width in [390.0, 1200.0]) {
    testWidgets(
      'persisted unresolved source diagnostic is visible at width $width',
      (tester) async {
        final previousPath = App.dataPath;
        App.dataPath = root.path;
        addTearDown(() {
          App.dataPath = previousPath;
        });
        final diagnosticsStore = SourceRevisionStore(
          Directory('${root.path}/comic_source'),
        );
        await tester.runAsync(
          () => diagnosticsStore.save(
            const ActiveArtifactRegistry(
              migrationDiagnostics: {
                'unresolved.js':
                    'Source identity is not a unique static literal.',
              },
            ),
          ),
        );
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(() async {
          await tester.pumpWidget(const MaterialApp(home: ComicSourcePage()));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();
        expect(find.text('unresolved.js'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  test(
    'enabling Cloud after opening keeps the active file and draft isolated',
    () async {
      final service = SourceMutationService(
        store: store,
        coordinator: coordinator,
      );
      final session = await service.openEditor(identity);
      sourceRuntimePolicy.requestMode(cloudEnabled: true, operationEpoch: 1);

      await expectLater(
        service.commitBuffer(
          session,
          source.replaceFirst('custom_ownership', 'changed'),
        ),
        throwsA(isA<SourceMutationDenied>()),
      );
      expect(
        await File('${root.path}/${identity.fileName}').readAsString(),
        source,
      );
      expect(await store.load(), ActiveArtifactRegistry(artifacts: [active]));
      expect(await File(session.draftPath).exists(), isTrue);
      await service.cancel(session);
    },
  );

  test(
    'Cloud mode change during blocked reload restores the prior selection',
    () async {
      final reloadStarted = Completer<void>();
      final allowReload = Completer<void>();
      final service = SourceMutationService(
        store: store,
        coordinator: coordinator,
        runtimeReloader: (_) async {
          reloadStarted.complete();
          await allowReload.future;
        },
      );
      final session = await service.openEditor(identity);
      final commit = service.commitBuffer(
        session,
        source.replaceFirst('Custom Ownership', 'Custom Ownership Changed'),
      );
      await reloadStarted.future;

      sourceRuntimePolicy.requestMode(
        cloudEnabled: true,
        operationEpoch: sourceRuntimePolicy.operationEpoch + 1,
      );
      allowReload.complete();

      await expectLater(commit, throwsA(isA<SourceMutationDenied>()));
      final restored = await store.load();
      expect(restored, isNotNull);
      expect(restored!.find(identity.sourceKey, identity.fileName), active);
      expect(
        await File('${root.path}/${identity.fileName}').readAsString(),
        source,
      );
      expect(await File(session.draftPath).exists(), isTrue);
      await service.cancel(session);
    },
  );

  test(
    'Cloud-on shared mutation service rejects every custom entry point',
    () async {
      final recoveryBytes = utf8.encode(
        source.replaceFirst('Custom Ownership', 'Recovered Custom Ownership'),
      );
      final recovery = active.copyWith(
        relativePath: '.custom/recovery-custom.js',
        sha256: sha256.convert(recoveryBytes).toString(),
      );
      final recoveryFile = store.fileForRelativePath(recovery.relativePath);
      await recoveryFile.parent.create(recursive: true);
      await recoveryFile.writeAsBytes(recoveryBytes, flush: true);
      final before = (await store.load())!;
      final withRecovery = before.copyWith(recoverableArtifacts: [recovery]);
      await store.save(withRecovery);
      final beforeBytes = await File(
        '${root.path}/${identity.fileName}',
      ).readAsBytes();
      final beforeCloudFlag = appdata.settings['cloudTrackingEnabled'];
      sourceRuntimePolicy.requestMode(cloudEnabled: true, operationEpoch: 1);
      final service = SourceMutationService(
        store: store,
        coordinator: coordinator,
        runtimeReloader: (_) async {},
      );

      final attempts = <Future<void> Function()>[
        () async {
          await service.updateCustom(identity, utf8.encode(source));
        },
        () async {
          await service.addCustom(source, 'new_custom.js');
        },
        () async {
          await service.restoreCustom(recovery);
        },
      ];
      for (final attempt in attempts) {
        await expectLater(attempt(), throwsA(isA<SourceMutationDenied>()));
      }

      expect(
        await File('${root.path}/${identity.fileName}').readAsBytes(),
        beforeBytes,
      );
      expect(await store.load(), withRecovery);
      expect(appdata.settings['cloudTrackingEnabled'], beforeCloudFlag);
      expect(sourceRuntimePolicy.operationEpoch, 1);
      expect(await File('${root.path}/new_custom.js').exists(), isFalse);
    },
  );

  test(
    'Cloud-off shared mutation service commits a validated custom update',
    () async {
      final service = SourceMutationService(
        store: store,
        coordinator: coordinator,
        runtimeReloader: (_) async {},
      );
      final changed = source.replaceFirst(
        'Custom Ownership',
        'Updated Custom Ownership',
      );
      final result = await service.updateCustom(identity, utf8.encode(changed));

      expect(result.origin, ArtifactOrigin.custom);
      expect(result.revision, isNull);
      expect(result.activationBlocked, isFalse);
      expect(result.relativePath, startsWith('.custom/'));
      expect(await store.readBytes(result), utf8.encode(changed));
      expect(
        await File('${root.path}/${identity.fileName}').readAsString(),
        source,
      );
      expect(coordinator.generations.current(identity)?.revision, 'local');
    },
  );

  testWidgets('Cloud-on source picker callback stops at the shared UI gate', (
    tester,
  ) async {
    App.dataPath = root.path;
    App.disposeTracking();
    sourceRuntimePolicy.prepare(
      cloudEnabled: true,
      registry: ActiveArtifactRegistry(artifacts: [active]),
      sourceDirectoryPath: root.path,
    );
    try {
      await tester.pumpWidget(
        const MaterialApp(
          home: OverlayWidget(Scaffold(body: ComicSourcePage())),
        ),
      );
      await tester.pumpAndSettle();
      final scrollable = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Use a config file'.tl),
        400,
        scrollable: scrollable,
      );
      await tester.tap(find.text('Use a config file'.tl));
      await tester.pump();

      expect(
        find.text(
          'Turn off Cloud before editing or installing a custom source.'.tl,
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3));
    } finally {
      App.disposeTracking();
    }
  });
}
