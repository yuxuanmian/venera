import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/full_scan_planner.dart';
import 'package:venera/foundation/scan/scan_debug_service.dart';
import 'package:venera/foundation/scan/target_provider.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(AppTranslation.init);

  test('debug translations cover the three supported language paths', () {
    const keys = [
      'Raw Scan Result',
      'No persisted scan result',
      'No scan result',
      'Copy Scan Result',
      'Scan already running',
      'Persisted items',
      'Scope Status',
      'Scan storage error',
      'Scan execution error',
      'Clear All Judgment Data',
      'Judgment data cleared',
      'Scan evidence is kept',
    ];
    for (final locale in ['zh_CN', 'zh_TW']) {
      final values = AppTranslation.translations[locale]!;
      for (final key in keys) {
        expect(values[key], isNotNull, reason: '$locale is missing $key');
      }
    }

    final previousLanguage = appdata.settings['language'];
    addTearDown(() => appdata.settings['language'] = previousLanguage);
    appdata.settings['language'] = 'en-US';
    expect('Raw Scan Result'.tl, 'Raw Scan Result');
    expect('Persisted items'.tl, 'Persisted items');
    appdata.settings['language'] = 'zh-CN';
    expect('Raw Scan Result'.tl, '原始扫描结果');
    appdata.settings['language'] = 'zh-TW';
    expect('Raw Scan Result'.tl, '原始掃描結果');
  });

  testWidgets('Debug page exposes an explicit empty persisted-result state', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1;

    await tester.pumpWidget(
      MaterialApp(
        home: ComicDebugPage(
          sourceKey: 'missing-source',
          comicId: 'missing-comic',
          scanRepository: FakeScanResultRepository(),
          favoriteCache: _EmptyCache(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Raw Scan Result'), findsOneWidget);
    expect(find.text('No persisted scan result'), findsOneWidget);
    expect(find.text('Follow-up State'), findsOneWidget);
  });

  testWidgets('the original desktop Debug menu drives a persisted scan', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final source = makeScanTestSource('menu-source');
    final adapter = FakeScanAdapter(sourceKey: source.key);
    final repository = FakeScanResultRepository();
    final service = ScanDebugService(
      repository: repository,
      targetProvider: FakeTargetProvider(
        ScanTargetSnapshot(
          works: [
            ScanWorkSpec.comic(
              source: source,
              adapter: adapter,
              comicId: 'menu-comic',
            ),
          ],
          cacheGeneration: 0,
          skippedSources: const [
            ScanSourceSkip(
              sourceKey: 'unavailable-source',
              reason: ScanSourceSkipReason.absent,
            ),
          ],
        ),
      ),
    );
    final previousService = scanDebugService;
    scanDebugService = service;
    addTearDown(() async {
      scanDebugService = previousService;
      await repository.close();
    });

    await _pumpWindow(tester);
    await tester.tap(find.text('Debug'));
    await tester.pumpAndSettle();
    for (final label in [
      'Clear Favorites Cache',
      'Clear All Judgment Data',
      'Force Scan All Comics',
      'Random Refresh Comics',
    ]) {
      expect(find.text(label.tl), findsOneWidget);
    }

    await tester.tap(find.text('Force Scan All Comics'.tl));
    await tester.pumpAndSettle();

    expect(service.isRunning, isFalse);
    expect(repository.items, hasLength(1));
    final stored = repository.items.values.single.result;
    expect(stored.sourceKey, source.key);
    expect(stored.comicId, 'menu-comic');
    await tester.pump(const Duration(seconds: 3));

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: ComicDebugPage(
          sourceKey: source.key,
          comicId: 'menu-comic',
          scanRepository: repository,
          favoriteCache: _EmptyCache(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Raw Scan Result'.tl), findsOneWidget);
    expect(find.text('Updated At'.tl), findsOneWidget);
    expect(find.text('2026-09-10'), findsOneWidget);
  });

  testWidgets('re-entry is reported and closing the progress dialog cancels', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    final source = makeScanTestSource('cancel-source');
    final started = Completer<void>();
    final adapter = FakeScanAdapter(
      sourceKey: source.key,
      comicLoader: (_, lease) {
        if (!started.isCompleted) started.complete();
        final pending = Completer<Object?>();
        lease.addCloseListener(() {
          if (!pending.isCompleted) {
            pending.complete(const {
              'observation': {
                'update': {'latestChapterId': 'must-not-commit'},
              },
            });
          }
        });
        return pending.future;
      },
    );
    final repository = FakeScanResultRepository();
    final service = ScanDebugService(
      repository: repository,
      targetProvider: FakeTargetProvider(
        ScanTargetSnapshot(
          works: [
            ScanWorkSpec.comic(
              source: source,
              adapter: adapter,
              comicId: 'cancel-comic',
            ),
          ],
          cacheGeneration: 0,
        ),
      ),
    );
    final previousService = scanDebugService;
    scanDebugService = service;
    addTearDown(() async {
      if (service.isRunning) service.cancel();
      scanDebugService = previousService;
      await repository.close();
    });

    await _pumpWindow(tester);
    await tester.tap(find.text('Debug'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Force Scan All Comics'.tl));
    await tester.pump();
    await started.future;
    await tester.pump();
    expect(find.text('Cancel'.tl), findsOneWidget);

    // The same real menu sheet can be opened above the loading route. The
    // second selection must only report re-entry and must not reset progress.
    final sheet = showDebugMenuSheet();
    await tester.pumpAndSettle();
    // Clear favorites, clear judgment data, force scan, rerun judgment,
    // random refresh.
    expect(find.byType(ListTile), findsNWidgets(5));
    // The sheet is intentionally anchored at the bottom of the oversized
    // test viewport. Invoke the real tile callback so this assertion remains
    // about menu wiring rather than pixel hit-testing.
    tester.widget<ListTile>(find.byType(ListTile).at(2)).onTap!();
    await sheet;
    await tester.pump();
    expect(service.isRunning, isTrue);
    expect(service.progress.value.discoveredWorks, 1);

    // System/back dismissal is routed through the same cancellation callback;
    // the loading route remains until the scan has unwound.
    final popHandled = await tester.binding.handlePopRoute();
    expect(popHandled, isTrue);
    expect(service.progress.value.phase, isNot(ScanProgressPhase.running));
    await tester.pumpAndSettle();
    expect(service.isRunning, isFalse);
    expect(repository.items, isEmpty);
    expect(
      (await repository.readLatestScope(
        source.key,
        ScanProducer.comic,
        'cancel-comic',
      ))!.status,
      ScanScopeStatus.canceled,
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the Debug menu clears judgment state and keeps the evidence', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;

    // The entry reaches the **product** judgment service, so this drives the
    // real singleton against a temporary app data directory rather than a
    // parallel store the menu would never touch.
    //
    // Everything filesystem-shaped here is the **synchronous** API on purpose:
    // a `testWidgets` body runs inside fake async, where the real `dart:io`
    // futures (`Directory.systemTemp.createTemp`, `Directory.delete`) never
    // complete and the test simply hangs.  The repository's own calls are fine
    // — it uses the synchronous `sqlite3` package, so its awaits are microtask
    // hops.
    final tempDirectory = Directory.systemTemp.createTempSync('venera-debug-');
    // `App.dataPath` is `late` and this file never initialises it, so there is
    // no previous value to restore.
    App.dataPath = tempDirectory.path;
    addTearDown(() async {
      await judgmentService.repository.close();
      try {
        tempDirectory.deleteSync(recursive: true);
      } on PathAccessException {
        // Windows may release a native SQLite handle just after dispose.
      } on PathNotFoundException {
        // Already gone.
      }
    });

    final repository = judgmentService.repository;
    await repository.ensureOpen();
    await repository.applyBatch([
      JudgmentState(
        sourceKey: 'menu-source',
        comicId: 'menu-comic',
        lastDecision: JudgmentConclusion.changed,
        lastReason: JudgmentReason.later,
        decidedAtMs: 1,
        hasNewUpdate: true,
        algorithmVersion: judgmentAlgorithmVersion,
      ),
    ]);
    expect(
      await repository.readSnapshot(),
      isNotEmpty,
      reason: 'the entry is only meaningful if there is something to clear',
    );

    await _pumpWindow(tester);
    await tester.tap(find.text('Debug'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear All Judgment Data'.tl));
    await tester.pump(const Duration(milliseconds: 1));

    expect(
      find.textContaining('Judgment data cleared'),
      findsOneWidget,
      reason: 'the entry reports what it did',
    );
    expect(
      find.textContaining('Scan evidence is kept'),
      findsOneWidget,
      reason: 'U4.1: the evidence surviving is the point of the entry',
    );
    expect(await repository.readSnapshot(), isEmpty);

    await tester.pump(const Duration(seconds: 2));
  });
}

Future<void> _pumpWindow(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: App.rootNavigatorKey,
      home: const SizedBox.shrink(),
      builder: (context, child) => OverlayWidget(WindowFrame(child!)),
    ),
  );
  await tester.pump();
}

class _EmptyCache extends NetworkFavoriteCacheManager {
  _EmptyCache() : super.forTesting();

  @override
  Set<String> getKnownFolderIds(String sourceKey, String comicId) => {};

  @override
  List<NetworkFavoriteFolder> getAllCachedFolders() => const [];
}
