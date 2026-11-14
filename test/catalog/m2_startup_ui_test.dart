import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/catalog_gate.dart';
import 'package:venera/components/startup_logo.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/controller.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';
import 'package:venera/foundation/catalog/store.dart';
import 'package:venera/pages/catalog_bootstrap_page.dart';
import 'package:venera/utils/translations.dart';

class _GateController extends CatalogController {
  _GateController(this.result, {CatalogPointer? active})
    : super(
        store: CatalogStore(Directory.systemTemp),
        preferences: SourcePreferences(initial: const []),
        appdata: Appdata.createForTesting(() async => Directory.systemTemp)
          ..catalogRuntime = AppCatalogState(active: active).toJson(),
      );

  final Future<CatalogStartupResult> result;

  @override
  Future<CatalogStartupResult> boot() => result;
}

void main() {
  setUpAll(AppTranslation.init);

  testWidgets('first use shows preparation while the initial boot is pending', (
    tester,
  ) async {
    final boot = Completer<CatalogStartupResult>();
    final controller = _GateController(boot.future);
    addTearDown(() {
      controller.preferences.dispose();
      controller.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: CatalogGate(
          controller: controller,
          ready: (_) => const Scaffold(body: Text('ready')),
        ),
      ),
    );

    expect(find.text('正在检查漫画源配置'), findsOneWidget);
    boot.complete(const CatalogNeedsInitialization());
    await tester.pumpAndSettle();
    expect(find.text('正在检查漫画源配置'), findsNothing);
  });

  testWidgets(
    'returning launch skips setup and announces fallback when ready',
    (tester) async {
      final pointer = CatalogRepositorySource.defaults.pointerForRevision(
        'a' * 40,
      );
      final index = CatalogIndex.fromJson(const []);
      final snapshot = CatalogSnapshot(
        manifest: CatalogSnapshotManifest(
          pointer: pointer,
          indexSha256: '0' * 64,
          files: const [],
        ),
        indexBytes: const [],
        index: index,
        rootPath: Directory.systemTemp.path,
      );
      final boot = Completer<CatalogStartupResult>();
      final release = Completer<void>();
      final controller = _GateController(boot.future, active: pointer);
      addTearDown(() {
        controller.preferences.dispose();
        controller.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: CatalogGate(
            controller: controller,
            ready: (_) => const Scaffold(body: Text('ready')),
            onReady: () => release.future,
          ),
        ),
      );
      expect(find.text('正在检查漫画源配置'), findsNothing);
      expect(find.byType(StartupLogo), findsOneWidget);
      expect(find.text('正在准备漫画源'), findsNothing);
      expect(find.text('ready'), findsNothing);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      boot.complete(
        CatalogReady(
          snapshot: snapshot,
          usedLocalFallback: true,
          localFallbackReason: CatalogLocalFallbackReason.repositoryCheckFailed,
        ),
      );
      await tester.pump();
      expect(find.text('正在使用本地版本'), findsNothing);

      release.complete();
      await tester.pump();
      expect(find.text('ready'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(StartupLogo),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle();

      expect(find.text('ready'), findsOneWidget);
      expect(find.textContaining('配置仓库检查失败'), findsOneWidget);
    },
  );

  for (final outcome in ['recovery', 'exception', 'timeout']) {
    testWidgets('catalog $outcome leaves the logo', (tester) async {
      final boot = Completer<CatalogStartupResult>();
      final pointer = CatalogRepositorySource.defaults.pointerForRevision(
        'a' * 40,
      );
      final controller = _GateController(boot.future, active: pointer);
      addTearDown(() {
        controller.preferences.dispose();
        controller.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: CatalogGate(
            controller: controller,
            ready: (_) => const Text('ready'),
          ),
        ),
      );
      switch (outcome) {
        case 'recovery':
          boot.complete(const CatalogNeedsRecovery('invalid snapshot'));
        case 'exception':
          boot.completeError(StateError('cannot load config'));
        case 'timeout':
          await tester.pump(const Duration(seconds: 100));
      }
      await tester.pumpAndSettle();
      if (outcome == 'recovery') {
        expect(find.byType(CatalogBootstrapPage), findsOneWidget);
      } else {
        expect(find.textContaining('Please close and reopen'), findsOneWidget);
      }
      expect(find.byType(StartupLogo), findsNothing);
      expect(find.text('ready'), findsNothing);
    });
  }

  testWidgets('local service timeout rejects a late readiness result', (
    tester,
  ) async {
    final pointer = CatalogRepositorySource.defaults.pointerForRevision(
      'b' * 40,
    );
    final snapshot = CatalogSnapshot(
      manifest: CatalogSnapshotManifest(
        pointer: pointer,
        indexSha256: '0' * 64,
        files: const [],
      ),
      indexBytes: const [],
      index: CatalogIndex.fromJson(const []),
      rootPath: Directory.systemTemp.path,
    );
    final services = Completer<void>();
    final controller = _GateController(
      Future.value(CatalogReady(snapshot: snapshot)),
      active: pointer,
    );
    addTearDown(() {
      controller.preferences.dispose();
      controller.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: CatalogGate(
          controller: controller,
          ready: (_) => const Text('ready'),
          onReady: () => services.future,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(find.textContaining('Please close and reopen'), findsOneWidget);
    expect(find.byType(StartupLogo), findsNothing);

    services.complete();
    await tester.pumpAndSettle();
    expect(find.text('ready'), findsNothing);
  });
}
