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
import 'package:venera/foundation/follow_updates_service.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_debug_service.dart';
import 'package:venera/foundation/scan/scan_result_repository.dart';
import 'package:venera/foundation/scan/target_provider.dart';
import 'package:venera/foundation/schedule/sqlite_schedule_repository.dart';
import 'package:venera/foundation/tracking/diagnostics.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
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
    expect(FollowUpdatesService.taskRunning, isFalse);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  }

  /// A viewport tall enough to lay out the whole Debug list.
  ///
  /// `ListView(children: …)` only builds the children inside its viewport, so a
  /// "this label is absent" assertion made on a short viewport can pass simply
  /// because the row was never built.  The two block-related tests therefore
  /// render the full page.
  void useTallViewport(WidgetTester tester) {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
  }

  /// A read-only, empty schedule store.
  ///
  /// The page's default is the app-owned singleton, which resolves
  /// `App.dataPath` — a path this fixture does not establish.  Injecting an
  /// in-memory store keeps these tests about the page rather than about startup
  /// wiring, and an empty store is exactly the "no check record" shape (D4).
  SqliteScheduleRepository emptyScheduleStore() {
    final repository = SqliteScheduleRepository(databasePath: ':memory:');
    addTearDown(repository.close);
    return repository;
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

    // D6: the entry keeps producing its "unavailable" feedback on every use.
    // The message is feedback rather than chrome, so it is not required to
    // still be on screen once the action is no longer being used — which is why
    // the loop above asserts a *fresh* appearance per tap rather than mere
    // presence here.
    expect(find.text('Recheck Now'.tl), findsWidgets);
    expect(FollowUpdatesService.taskRunning, isFalse);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(snapshotRetirementState(fixture.databasePath), beforeState);
    await tester.scrollUntilVisible(
      find.text('No trace in this session'.tl),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('No trace in this session'.tl), findsOneWidget);
  });

  testWidgets(
    'desktop debug menu and mobile sheet keep retired handlers unavailable',
    (tester) async {
      final beforeState = snapshotRetirementState(fixture.databasePath);
      await pumpWindow(tester);
      const forceScanLabel = 'Force Scan All Comics';
      final retiredEntries = ['Random Refresh Comics'.tl];

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
      // retirement regression only protects the other handlers.
      await tester.tap(find.text('Debug'));
      await tester.pumpAndSettle();
      expect(find.text(forceScanLabel.tl), findsOneWidget);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      expect(snapshotRetirementState(fixture.databasePath), beforeState);
      expect(FollowUpdatesService.taskRunning, isFalse);
    },
  );

  testWidgets('the retired and mislabelled debug entries are gone', (
    tester,
  ) async {
    // The retired "Clear Baselines" item is **gone**, not merely inert: its slot
    // now carries the judgment-clear entry, which does something.  Its old label
    // must not come back, and neither may the misleading "Clear Observation
    // Facts" label, whose entry performed the same judgment clear under the name
    // of the thing it preserves.  Both keys stay in the translation asset so
    // these guards mean something: a missing key would make `.tl` fall back to
    // the key itself and `findsNothing` would pass for the wrong reason.
    const retired = ['Clear Baselines', 'Clear Observation Facts'];
    const replacement = 'Clear All Judgment Data';

    Future<void> expectMenuSurfaces(Future<void> Function() dismiss) async {
      for (final label in retired) {
        expect(find.text(label.tl), findsNothing, reason: label);
      }
      expect(find.text(replacement.tl), findsOneWidget);
      await dismiss();
      await tester.pumpAndSettle();
    }

    await pumpWindow(tester);

    await tester.tap(find.text('Debug'));
    await tester.pumpAndSettle();
    await expectMenuSurfaces(() async {
      await tester.binding.handlePopRoute();
    });

    final sheet = showDebugMenuSheet();
    await tester.pumpAndSettle();
    await expectMenuSurfaces(() async {
      await tester.binding.handlePopRoute();
    });
    await sheet;

    expect(FollowUpdatesService.taskRunning, isFalse);
    expect(snapshotRetirementState(fixture.databasePath), isNotEmpty);
  });

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

  /// Every label the two retired Debug blocks used to render.
  ///
  /// Two labels the old blocks also carried are deliberately **not** here
  /// because an existing block still owns them and Contract D1 forbids changing
  /// those blocks: `Has New Update` belongs to the Judgment block, and
  /// `Update Check Strategy` belongs to Source Info (where it describes the old
  /// source declaration, a different fact from the 004 scan capability).
  const retiredBlockLabels = <String>[
    'Last Check Time',
    'Historical Next Check Time',
    'Last Effective Activity Time',
    'Baseline Time',
    'Source Activity Time',
    'Hot Window Active',
    'Hot Window Source',
    'Hot Window Until',
    'Manual Hot Enabled',
    'Update Marker',
    'Last Update Time',
    'Check Failures',
    'Not Found Hits',
    'Source is_new',
    'Source full_is_new',
    'Marker Value',
    'Historical List Scan Interval',
    'Last List Scan Attempt',
    'Last Successful List Scan',
    'Historical Next List Check',
    'Historical List Retry After',
    'List Check Failures',
    'Last Snapshot Pages / Comics',
    'Next Automatic List Scan',
  ];

  /// The two block titles and the historical disclaimer (Contract D5).
  const retiredBlockChrome = <String>[
    'Displayed scan state is historical',
    'Follow-up State',
    'Not tracked by follow-up scans',
  ];

  testWidgets('the retired historical blocks are gone for every source kind', (
    tester,
  ) async {
    // FR-013 / D7.  Run for both source shapes, because the old code chose
    // between the two blocks on `favoriteData.updateCheck`; that branch is gone,
    // so neither shape may show either block any more.
    useTallViewport(tester);
    for (final withUpdateCheck in <bool>[false, true]) {
      final source = RetirementFakeSource(sourceKey: retirementSourceA);
      registerSource(
        source,
        data: withUpdateCheck
            ? source.numberedData(withUpdateCheck: true)
            : null,
      );

      await pumpDebug(
        tester,
        ComicDebugPage(
          key: ValueKey('retired-$withUpdateCheck'),
          sourceKey: retirementSourceA,
          comicId: 'retire-a',
          scheduleRepository: emptyScheduleStore(),
        ),
      );
      await tester.pumpAndSettle();

      for (final label in retiredBlockLabels) {
        expect(
          find.text(label.tl),
          findsNothing,
          reason: 'retired label "$label" (updateCheck=$withUpdateCheck)',
        );
      }
      for (final label in retiredBlockChrome) {
        expect(
          find.text(label.tl),
          findsNothing,
          reason:
              'retired block chrome "$label" (updateCheck=$withUpdateCheck)',
        );
      }
      // Both new blocks are present for this comic, which has no stored record
      // in the injected test setup, so they render their explicit defaults.
      expect(find.text('Schedule'.tl), findsOneWidget);
      expect(find.text('Collection Scope'.tl), findsOneWidget);

      // T077: the two Source Info rows are the **last** reader of the retired
      // `favoriteData.updateCheck` declaration, so both branches are pinned
      // here.  Removing that declaration from the sources (005 FR-045) must fail
      // this expectation loudly instead of silently flipping the labels.
      expect(
        find.text('Update Check Strategy'.tl),
        findsOneWidget,
        reason:
            'Source Info keeps the retired-strategy row '
            '(updateCheck=$withUpdateCheck)',
      );
      expect(
        find.text(
          (withUpdateCheck ? 'Favorite list snapshot' : 'Comic details').tl,
        ),
        findsOneWidget,
        reason:
            'the row states what the retired declaration implies '
            '(updateCheck=$withUpdateCheck)',
      );
    }
  });

  testWidgets('the unavailable message is action feedback, not a block title', (
    tester,
  ) async {
    // D5 keeps the "scanner unavailable" text on the action entry only, and D6
    // keeps that entry's feedback.  Before any tap the text must not be on the
    // page, which is what makes it feedback rather than chrome.
    final source = RetirementFakeSource(sourceKey: retirementSourceA);
    registerSource(source);
    await pumpDebug(
      tester,
      const ComicDebugPage(sourceKey: retirementSourceA, comicId: 'retire-a'),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(followUpdateScannerUnavailableMessage.tl),
      findsNothing,
      reason: 'the message must not be a block title any more',
    );

    await expectFreshFeedback(
      tester,
      () => tester.tap(find.text('Recheck Now'.tl)),
    );
    expect(FollowUpdatesService.taskRunning, isFalse);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('detail timing fields are no longer labeled as historical', (
    tester,
  ) async {
    useTallViewport(tester);
    final source = RetirementFakeSource(sourceKey: retirementSourceA);
    registerSource(source);

    await pumpDebug(
      tester,
      ComicDebugPage(
        sourceKey: retirementSourceA,
        comicId: 'retire-a',
        scheduleRepository: emptyScheduleStore(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Historical Next Check Time'.tl), findsNothing);
    // The label is the current-value one; its value is an explicit default
    // because this fixture stores no schedule row (Contract D4).
    expect(find.text('Next Check Time'.tl), findsOneWidget);
    expect(find.text('No check record'.tl), findsWidgets);
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
  Future<ScanTargetSnapshot> snapshot({
    Map<String, Set<String>>? dueComicIdsBySource,
    Set<String>? scopeSourceKeys,
    String? roundLabel,
  }) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return ScanTargetSnapshot(
      works: const [],
      cacheGeneration: scanCache.cacheGeneration,
    );
  }
}
