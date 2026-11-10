import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/controller.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';
import 'package:venera/foundation/catalog/store.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

class _DiagnosticsController extends CatalogController {
  _DiagnosticsController({
    required this.state,
    required CatalogRepositoryCheck latest,
  }) : super(
         store: CatalogStore(Directory.systemTemp),
         appdata: Appdata.createForTesting(() async => Directory.systemTemp),
         preferences: SourcePreferences(initial: const []),
       ) {
    latestRepositoryCheck = latest;
  }

  final AppCatalogState state;

  @override
  AppCatalogState? get sessionState => state;

  @override
  CatalogPointer? get runtimePointer => state.active;

  @override
  CatalogRepositorySource get repositorySource =>
      CatalogRepositorySource.defaults;

  @override
  bool get usingLocalFallback => true;

  @override
  CatalogLocalFallbackReason? get localFallbackReason =>
      CatalogLocalFallbackReason.updatePreparationFailed;
}

void main() {
  setUpAll(AppTranslation.init);

  testWidgets(
    'diagnostics show full identity but no legacy address or raw error',
    (tester) async {
      final runtime = CatalogRepositorySource.defaults.pointerForRevision(
        'a' * 40,
      );
      final latest = CatalogRepositorySource.defaults.pointerForRevision(
        'b' * 40,
      );
      final legacy = CatalogLastAuthority(
        catalog: runtime,
        serverUrl: 'https://private-server.example',
        checkedAt: DateTime.utc(2026, 11, 9),
      );
      final failure = const CatalogSetupFailure(
        CatalogSetupFailureKind.connectionFailed,
        diagnostic: 'private response body https://private-server.example',
      );
      final controller = _DiagnosticsController(
        state: AppCatalogState(active: runtime, lastAuthority: legacy),
        latest: CatalogRepositoryCheck(
          source: CatalogRepositorySource.defaults,
          checkedAt: DateTime.utc(2026, 11, 9, 12),
          status: CatalogRepositoryCheckStatus.failed,
          latest: latest,
          failure: failure,
        ),
      );
      addTearDown(() {
        controller.preferences.dispose();
        controller.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(home: CatalogDiagnostics(controller: controller)),
      );
      await tester.pumpAndSettle();

      expect(find.text(runtime.revision), findsWidgets);
      await tester.scrollUntilVisible(
        find.text('localFallback:updatePreparationFailed'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.text('localFallback:updatePreparationFailed'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('connectionFailed'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('connectionFailed'), findsOneWidget);
      expect(find.textContaining('private-server.example'), findsNothing);
      expect(find.textContaining('private response body'), findsNothing);
      expect(find.textContaining('cloudTrackingAccessToken'), findsNothing);
      expect(find.textContaining('Cookie'), findsNothing);
    },
  );
}
