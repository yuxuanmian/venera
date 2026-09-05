import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/tracking/diagnostics.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String previousLanguage;
  setUpAll(() async {
    await AppTranslation.init();
    previousLanguage = appdata.settings['language'] as String;
    appdata.settings['language'] = 'en-US';
    final directory = await Directory.systemTemp.createTemp(
      'venera-tracking-debug-',
    );
    await NetworkFavoriteCacheManager().init(
      databasePath: p.join(directory.path, 'favorites.db'),
      migrateLegacy: false,
    );
  });

  setUp(() => trackingDiagnostics.clear());

  tearDownAll(() {
    appdata.settings['language'] = previousLanguage;
  });

  testWidgets('shows an explicit empty trace state', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ComicDebugPage(sourceKey: 'missing-source', comicId: 'comic-1'),
      ),
    );

    expect(find.text('Tracking Diagnostics'), findsOneWidget);
    expect(find.text('No trace in this session'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'renders all trace stages for changed, mismatch, and stale cases',
    (tester) async {
      trackingDiagnostics.record(
        TrackingDiagnosticTrace(
          sourceKey: 'manwa',
          fileName: 'manwa.js',
          comicId: 'comic-2',
          at: DateTime.utc(2026, 9, 3),
          runtime: const {'revision': 'rev', 'generation': 2},
          rawObservation: const {'sourceUnread': true},
          normalization: const {
            'state': {'latestChapterId': 'chapter-2'},
            'dropped': [
              {'field': 'metadata', 'reason': 'bounded'},
            ],
          },
          comparison: const {'result': 'changed', 'reason': 'new chapter'},
          presentation: const {'finalHasNewUpdate': true},
          rejection: 'stale or revision mismatch',
        ),
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: ComicDebugPage(sourceKey: 'manwa', comicId: 'comic-2'),
        ),
      );

      await tester.scrollUntilVisible(
        find.text('Rejection'),
        300,
        scrollable: find.byType(Scrollable).first,
      );

      for (final title in [
        'Runtime',
        'Raw Observation',
        'Normalized UpdateState',
        'Comparison',
        'Presentation',
        'Rejection',
      ]) {
        expect(find.text(title), findsOneWidget);
      }
      expect(find.textContaining('new chapter'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('shows ownership placeholder before app initialization', (
    tester,
  ) async {
    final previousInitialized = App.isInitialized;
    addTearDown(() => App.isInitialized = previousInitialized);
    App.isInitialized = false;

    await tester.pumpWidget(
      const MaterialApp(
        home: ComicDebugPage(sourceKey: 'missing-source', comicId: 'comic-1'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Runtime Ownership'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('Runtime Ownership'), findsOneWidget);
    expect(find.text('Not initialized'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
