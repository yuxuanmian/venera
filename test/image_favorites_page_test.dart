import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/pages/image_favorites_page/image_favorites_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late HistoryManager historyManager;

  setUpAll(() async {
    await AppTranslation.init();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('venera-image-favorites-');
    App.dataPath = tempDir.path;
    App.cachePath = tempDir.path;
    HistoryManager.cache = null;
    historyManager = HistoryManager();
    await historyManager.init();
  });

  tearDown(() {
    historyManager.close();
    HistoryManager.cache = null;
    tempDir.deleteSync(recursive: true);
  });

  testWidgets(
    'returning from a detail route preserves image favorites search state',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: const ImageFavoritesPage(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      final searchField = find.byType(TextField);
      await tester.enterText(searchField, 'keyword');
      await tester.pumpAndSettle();

      final pageContext = tester.element(find.byType(ImageFavoritesPage));
      final detailRoute = Navigator.of(pageContext).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('detail')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('detail'), findsOneWidget);

      Navigator.of(pageContext).pop();
      await detailRoute;
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
      expect(tester.widget<TextField>(searchField).controller!.text, 'keyword');

      await Navigator.of(pageContext).maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.byIcon(Icons.search), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
