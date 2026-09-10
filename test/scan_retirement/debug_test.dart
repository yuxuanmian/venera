import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_update_availability.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_debug_service.dart';
import 'package:venera/foundation/scan/scan_result_repository.dart';
import 'package:venera/foundation/scan/target_provider.dart';
import 'package:venera/foundation/tracking/diagnostics.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/utils/translations.dart';

import 'fixtures.dart';
import '../scan_kernel/fakes.dart' as scan_fakes;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RetirementFixture fixture;

  setUpAll(() async {
    await AppTranslation.init();
  });

  setUp(() async {
    fixture = await createRetirementFixture();
    trackingDiagnostics.clear();
    FollowUpdatesService.cancelChecking();
  });

  tearDown(() async {
    ComicSourceManager().remove(retirementSourceA);
    await fixture.dispose();
  });

  void registerSource(RetirementFakeSource fake, {FavoriteData? data}) {
    final manager = ComicSourceManager();
    manager.remove(fake.sourceKey);
    manager.add(fake.buildComicSource(favoriteData: data));
  }

  Future<void> pumpDebug(WidgetTester tester, ComicDebugPage page) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: page,
        builder: (context, child) => OverlayWidget(WindowFrame(child!)),
      ),
    );
    await tester.pump();
  }

  Future<void> pumpWindow(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: const SizedBox.shrink(),
        builder: (context, child) => OverlayWidget(WindowFrame(child!)),
      ),
    );
    await tester.pump();
  }

  int unavailableMessageCount(WidgetTester tester) =>
      find.text(followUpdateScannerUnavailableMessage.tl).evaluate().length;

  Future<void> expectFreshFeedback(
    WidgetTester tester,
    Future<void> Function() trigger,
  ) async {
    final before = unavailableMessageCount(tester);
    await trigger();
    await tester.pump(const Duration(milliseconds: 1));
    expect(unavailableMessageCount(tester), greaterThan(before));
    expect(FollowUpdatesService.taskRunning.value, isFalse);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  }

  Future<void> scrollToEnd(WidgetTester tester) async {
    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pump();
  }

  testWidgets('Debug Recheck reports unavailable without a loading state', (
    tester,
  ) async {
    final beforeState = snapshotRetirementState(fixture.databasePath);
    await pumpDebug(
      tester,
      const ComicDebugPage(sourceKey: retirementSourceA, comicId: 'retire-a'),
    );

    for (var i = 0; i < 10; i++) {
      await expectFreshFeedback(
        tester,
        () => tester.tap(find.text('Recheck Now'.tl)),
      );
    }

    expect(find.text(followUpdateScannerUnavailableMessage.tl), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(snapshotRetirementState(fixture.databasePath), beforeState);
    await scrollToEnd(tester);
    expect(find.text('No trace in this session'.tl), findsOneWidget);
  });

  testWidgets(
    'desktop debug menu and mobile sheet keep retired handlers unavailable',
    (tester) async {
      final beforeState = snapshotRetirementState(fixture.databasePath);
      await pumpWindow(tester);
      const forceScanLabel = 'Force Scan All Comics';
      final retiredEntries = ['Clear Baselines'.tl, 'Random Refresh Comics'.tl];

      for (final entry in retiredEntries) {
        for (var i = 0; i < 10; i++) {
          await tester.tap(find.text('Debug'));
          await tester.pumpAndSettle();
          expect(find.text(entry), findsOneWidget);
          await expectFreshFeedback(tester, () => tester.tap(find.text(entry)));
        }
      }

      for (final entry in retiredEntries) {
        for (var i = 0; i < 10; i++) {
          final sheet = showDebugMenuSheet();
          await tester.pumpAndSettle();
          expect(find.text(entry), findsOneWidget);
          await expectFreshFeedback(tester, () => tester.tap(find.text(entry)));
          await sheet;
        }
      }

      // 004 deliberately authorizes only this existing menu item. Its full
      // execution path is covered by scan_kernel service/widget tests; this
      // retirement regression only protects the other two handlers.
      await tester.tap(find.text('Debug'));
      await tester.pumpAndSettle();
      expect(find.text(forceScanLabel.tl), findsOneWidget);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      expect(snapshotRetirementState(fixture.databasePath), beforeState);
      expect(FollowUpdatesService.taskRunning.value, isFalse);
    },
  );

  testWidgets('clear favorites cancels scan before invalidating its cache', (
    tester,
  ) async {
    final beforeState = snapshotRetirementState(fixture.databasePath);
    final repository = scan_fakes.FakeScanResultRepository();
    final existingScope = await repository.beginScope(
      sourceKey: 'scan-source',
      producer: ScanProducer.comic,
      scopeKey: 'scan-comic',
      definitionRevision: 'rev',
    );
    final existingItem = ScanItemResult.observed(
      attemptId: scanUuidV5(
        existingScope.scopeAttemptId,
        'scan-source\u0000scan-comic',
      ),
      scopeAttemptId: existingScope.scopeAttemptId,
      sourceKey: 'scan-source',
      comicId: 'scan-comic',
      producer: ScanProducer.comic,
      definitionRevision: 'rev',
      observedAt: '2026-09-10T00:00:00.000Z',
      observation: ScanObservation(
        update: UpdateDescriptor(latestChapterId: 'existing-scan-result'),
      ),
    );
    await repository.saveItem(
      ScanIngestionContext(scope: existingScope),
      existingItem,
    );
    await repository.finishScope(
      ScanIngestionContext(scope: existingScope),
      ScanScopeStatus.completed,
    );

    final provider = _CacheBlockingTargetProvider(fixture.cache);
    final service = ScanDebugService(
      repository: repository,
      targetProvider: provider,
    );
    final previousService = scanDebugService;
    scanDebugService = service;
    addTearDown(() async {
      if (service.isRunning) service.cancel();
      scanDebugService = previousService;
      await repository.close();
    });

    await pumpWindow(tester);
    final running = service.startFullScan();
    await provider.started.future;
    final generation = fixture.cache.cacheGeneration;

    await tester.tap(find.text('Debug'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear Favorites Cache'.tl));
    await tester.pump();
    expect(fixture.cache.cacheGeneration, generation + 1);
    final afterClearState = snapshotRetirementState(fixture.databasePath);
    expect(
      afterClearState['comic_check_state'],
      beforeState['comic_check_state'],
    );
    expect(afterClearState['scan_queue'], beforeState['scan_queue']);
    expect(
      afterClearState['follow_update_run'],
      beforeState['follow_update_run'],
    );
    expect(afterClearState['favorite_update_scan_state'], isEmpty);

    provider.release.complete();
    final summary = await running.timeout(const Duration(seconds: 5));
    expect(summary.disposition, FullScanDisposition.canceled);
    expect(service.isRunning, isFalse);
    expect(repository.items, contains('scan-source\u0000scan-comic'));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Debug copy actions preserve history and redact sensitive data', (
    tester,
  ) async {
    var copiedText = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText.add(
              (call.arguments as Map<Object?, Object?>)['text'] as String,
            );
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    trackingDiagnostics.record(
      TrackingDiagnosticTrace(
        sourceKey: retirementSourceA,
        fileName: 'retirement.js',
        comicId: 'retire-a',
        at: fixtureNow,
        runtime: const {
          'authorization': 'Bearer secret-authorization',
          'visible': 'historical-runtime',
        },
        rawObservation: const {
          'token': 'secret-token',
          'url': 'https://private.example/trace?cookie=secret-cookie',
          'visible': 'historical-observation',
        },
        presentation: const {'visible': 'historical-presentation'},
      ),
    );
    final details = ComicDetails.fromJson({
      'title': 'Historical copy target',
      'subtitle': 'History',
      'cover': 'https://private.example/cover.jpg?token=secret-cover',
      'description':
          'authorization=secret-description https://private.example/body',
      'tags': {
        'token': ['secret-tag'],
        'genre': ['historical'],
      },
      'chapters': {'1': 'Chapter 1'},
      'sourceKey': retirementSourceA,
      'comicId': 'retire-a',
      'url': 'https://private.example/comic?cookie=secret-url-cookie',
    });
    final beforeState = snapshotRetirementState(fixture.databasePath);

    await pumpDebug(
      tester,
      ComicDebugPage(
        sourceKey: retirementSourceA,
        comicId: 'retire-a',
        details: details,
      ),
    );

    await tester.tap(find.text('Copy JSON'.tl));
    await tester.pump(const Duration(milliseconds: 1));
    expect(copiedText, hasLength(1));
    final jsonText = copiedText.single;
    expect(jsonText, contains('Historical copy target'));
    expect(jsonText, contains('comicId'));
    for (final secret in [
      'secret-cover',
      'secret-description',
      'secret-tag',
      'secret-url-cookie',
      'private.example',
    ]) {
      expect(jsonText, isNot(contains(secret)));
    }

    await tester.tap(find.text('Copy Tracking Trace'.tl));
    await tester.pump(const Duration(milliseconds: 1));
    expect(copiedText, hasLength(2));
    final traceText = copiedText.last;
    expect(traceText, contains('historical-runtime'));
    expect(traceText, contains('historical-observation'));
    for (final secret in [
      'secret-authorization',
      'secret-token',
      'secret-cookie',
      'private.example',
    ]) {
      expect(traceText, isNot(contains(secret)));
    }
    expect(snapshotRetirementState(fixture.databasePath), beforeState);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('list timing fields are labeled as historical values', (
    tester,
  ) async {
    final source = RetirementFakeSource(sourceKey: retirementSourceA);
    registerSource(source, data: source.numberedData(withUpdateCheck: true));

    await pumpDebug(
      tester,
      const ComicDebugPage(sourceKey: retirementSourceA, comicId: 'retire-b'),
    );

    expect(find.text('Historical List Scan Interval'.tl), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Historical Next List Check'.tl),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Historical Next List Check'.tl), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Historical List Retry After'.tl),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Historical List Retry After'.tl), findsOneWidget);
    expect(find.text('Next Automatic List Scan'.tl), findsNothing);
    expect(find.text('Ready'.tl), findsNothing);
    expect(find.text('In Cooldown'.tl), findsNothing);
  });

  testWidgets('detail timing fields are labeled as historical values', (
    tester,
  ) async {
    final source = RetirementFakeSource(sourceKey: retirementSourceA);
    registerSource(source);

    await pumpDebug(
      tester,
      const ComicDebugPage(sourceKey: retirementSourceA, comicId: 'retire-a'),
    );

    expect(find.text('Historical Next Check Time'.tl), findsOneWidget);
    expect(find.text('Next Check Time'.tl), findsNothing);
    expect(find.text('Ready'.tl), findsNothing);
    expect(find.text('In Cooldown'.tl), findsNothing);
  });
}

class _CacheBlockingTargetProvider extends ScanTargetProvider {
  _CacheBlockingTargetProvider(this.scanCache)
    : super(cache: scanCache, sources: () => const []);

  final NetworkFavoriteCacheManager scanCache;
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<ScanTargetSnapshot> snapshot() async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return ScanTargetSnapshot(
      works: const [],
      cacheGeneration: scanCache.cacheGeneration,
    );
  }
}
