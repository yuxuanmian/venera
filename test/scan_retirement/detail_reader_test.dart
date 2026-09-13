import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/translations.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appDirectory;
  late RetirementFixture fixture;

  setUpAll(() async {
    await AppTranslation.init();
    appDirectory = await Directory.systemTemp.createTemp(
      'venera-retirement-detail-app-',
    );
    App.dataPath = appDirectory.path;
    App.cachePath = appDirectory.path;
    await HistoryManager().init();
    await LocalManager().init();
  });

  tearDownAll(() async {
    ComicSourceManager().remove(retirementSourceA);
    HistoryManager().close();
    LocalManager().dispose();
    try {
      await appDirectory.delete(recursive: true);
    } on PathAccessException {
      // Windows may release a native SQLite handle just after dispose.
    }
  });

  setUp(() async {
    fixture = await createRetirementFixture();
  });

  tearDown(() async {
    ComicSourceManager().remove(retirementSourceA);
    await fixture.dispose();
  });

  void registerSource(RetirementFakeSource source) {
    ComicSourceManager().remove(source.sourceKey);
    ComicSourceManager().add(source.buildComicSource());
  }

  Future<void> pumpPage(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: child,
        builder: (context, child) => WindowFrame(child!),
      ),
    );
    await tester.pump();
  }

  Future<void> settleLoading(WidgetTester tester) async {
    await tester.pumpAndSettle();
  }

  testWidgets(
    'ComicPage uses the registered source for normal detail success',
    (tester) async {
      final source = RetirementFakeSource(sourceKey: retirementSourceA);
      registerSource(source);
      final before = snapshotRetirementState(fixture.databasePath);

      await pumpPage(
        tester,
        const ComicPage(id: 'retire-c', sourceKey: retirementSourceA),
      );
      await settleLoading(tester);

      expect(find.text('Fake retire-c'), findsWidgets);
      expect(source.counters.detailCalls, 1);
      expect(snapshotRetirementState(fixture.databasePath), before);
    },
  );

  testWidgets(
    'ComicPage keeps ordinary retry and offers only favorite removal on a 404',
    (tester) async {
      final source = RetirementFakeSource(
        sourceKey: retirementSourceA,
        detailError: '404 Not Found',
      );
      registerSource(source);
      final before = snapshotRetirementState(fixture.databasePath);

      await pumpPage(
        tester,
        const ComicPage(id: 'retire-c', sourceKey: retirementSourceA),
      );
      await settleLoading(tester);

      expect(find.text('404 Not Found'), findsOneWidget);
      // `retire-c` is a cached favorite, so removal is offered — and that is
      // the point: the action is justified by the user's own favorite, not by a
      // delist verdict the app can no longer form (FR-023).
      expect(find.text('Remove Favorite'.tl), findsOneWidget);
      expect(
        find.text('Clear Suspected Removed'.tl),
        findsNothing,
        reason: 'the control was removed from the build, not merely hidden',
      );
      final callsBeforeRetry = source.counters.detailCalls;

      await tester.tap(find.text('Retry'.tl));
      await settleLoading(tester);

      expect(source.counters.detailCalls, greaterThan(callsBeforeRetry));
      expect(snapshotRetirementState(fixture.databasePath), before);
    },
  );

  testWidgets(
    'ComicPage offers only Remove Favorite, and never a suspected-removed control',
    (tester) async {
      final source = RetirementFakeSource(
        sourceKey: retirementSourceA,
        detailError: 'comic removed (404)',
      );
      registerSource(source);
      final before = snapshotRetirementState(fixture.databasePath);

      await pumpPage(
        tester,
        const ComicPage(id: 'retire-b', sourceKey: retirementSourceA),
      );
      await settleLoading(tester);

      expect(find.text('comic removed (404)'), findsOneWidget);
      expect(find.text('Remove Favorite'.tl), findsOneWidget);
      // The removed control, its handler and its backing verdict are all gone
      // (FR-023).  Its absence is the assertion: a returning button would mean
      // the retired verdict came back with it.
      expect(find.text('Clear Suspected Removed'.tl), findsNothing);
      expect(snapshotRetirementState(fixture.databasePath), before);
    },
  );

  testWidgets(
    'ReaderWithLoading opens the normal reader and keeps scan state untouched',
    (tester) async {
      final source = RetirementFakeSource(
        sourceKey: retirementSourceA,
        readerPagesPending: true,
      );
      registerSource(source);
      final before = snapshotRetirementState(fixture.databasePath);

      await pumpPage(
        tester,
        const ReaderWithLoading(id: 'retire-c', sourceKey: retirementSourceA),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(Reader), findsOneWidget);
      expect(source.counters.detailCalls, 1);
      expect(source.counters.readerPageCalls, 1);
      expect(snapshotRetirementState(fixture.databasePath), before);

      // Keep page loading pending so the test does not perform an image
      // request; the real reader route has already been entered.
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: const SizedBox.shrink(),
          builder: (context, child) => WindowFrame(child!),
        ),
      );
      // Reader disposal schedules the existing data-sync registration timer;
      // let that ordinary lifecycle callback finish while a valid root frame
      // is still mounted.
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'ReaderWithLoading shows ordinary removed errors without scan evidence',
    (tester) async {
      final source = RetirementFakeSource(
        sourceKey: retirementSourceA,
        detailError: 'removed by source (404)',
      );
      registerSource(source);
      final before = snapshotRetirementState(fixture.databasePath);

      await pumpPage(
        tester,
        const ReaderWithLoading(id: 'retire-b', sourceKey: retirementSourceA),
      );
      await settleLoading(tester);

      expect(find.text('removed by source (404)'), findsOneWidget);
      expect(find.byType(Reader), findsNothing);
      expect(source.counters.detailCalls, greaterThanOrEqualTo(4));
      expect(snapshotRetirementState(fixture.databasePath), before);
    },
  );
}
