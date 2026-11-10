import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/catalog_gate.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/controller.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';
import 'package:venera/foundation/catalog/store.dart';
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
      expect(find.text('ready'), findsNothing);

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
      await tester.pumpAndSettle();

      expect(find.text('ready'), findsOneWidget);
      expect(find.textContaining('配置仓库检查失败'), findsOneWidget);
    },
  );
}
