import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/catalog_gate.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/controller.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';
import 'package:venera/foundation/catalog/store.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/utils/translations.dart';

class _FirstRunController extends CatalogController {
  _FirstRunController({
    required this.result,
    required SourcePreferences preferences,
  }) : super(
         store: CatalogStore(Directory.systemTemp),
         appdata: Appdata.createForTesting(() async => Directory.systemTemp),
         preferences: preferences,
       );

  final CatalogStartupResult result;

  @override
  Future<CatalogStartupResult> boot() async => result;
}

ComicSource _source() => ComicSource(
  'First source',
  'first_source',
  null,
  null,
  null,
  null,
  const [],
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  'first_source.js',
  '',
  '1.0.0',
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  false,
  false,
  null,
  null,
);

CatalogReady _ready() {
  final pointer = CatalogRepositorySource.defaults.pointerForRevision('a' * 40);
  return CatalogReady(
    snapshot: CatalogSnapshot(
      manifest: CatalogSnapshotManifest(
        pointer: pointer,
        indexSha256: '0' * 64,
        files: const [],
      ),
      indexBytes: const [],
      index: CatalogIndex.fromJson(const []),
      rootPath: Directory.systemTemp.path,
    ),
    needsSourceSelection: true,
    repositorySource: CatalogRepositorySource.defaults,
  );
}

void main() {
  setUpAll(AppTranslation.init);

  setUp(() {
    for (final source in ComicSourceManager().all().toList()) {
      ComicSourceManager().remove(source.key);
    }
    ComicSourceManager().add(_source());
  });

  tearDown(() {
    for (final source in ComicSourceManager().all().toList()) {
      ComicSourceManager().remove(source.key);
    }
  });

  testWidgets(
    'first-run selection appears once after ready and empty save works',
    (tester) async {
      final writes = <List<String>?>[];
      final preferences = SourcePreferences(
        initial: const [],
        selectionApplier: (added, removed, patchSettings) async {
          final settings = <String, dynamic>{};
          patchSettings?.call(settings);
          expect(settings, isEmpty);
          final value = SourcePreferences.normalizeSelection(const []);
          writes.add(value);
          return value;
        },
      );
      final controller = _FirstRunController(
        result: _ready(),
        preferences: preferences,
      );
      addTearDown(() {
        preferences.dispose();
        controller.dispose();
      });
      var readyServices = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: CatalogGate(
            controller: controller,
            onReady: () async => readyServices++,
            ready: (_) => const Scaffold(body: Text('main')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(readyServices, 1);
      expect(find.byType(ComicSourceSelectionPage), findsOneWidget);
      expect(
        find.textContaining('Selected @a of @b'.tlParams({'a': 0, 'b': 1})),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('save-comic-source-selection')));
      await tester.pumpAndSettle();
      expect(writes, [isEmpty]);
      expect(find.text('main'), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('main'), findsOneWidget);
      expect(find.byType(ComicSourceSelectionPage), findsNothing);
      expect(readyServices, 1);
    },
  );

  testWidgets(
    'first-run clean cancellation exits to main and does not repeat',
    (tester) async {
      final preferences = SourcePreferences(initial: const []);
      final controller = _FirstRunController(
        result: _ready(),
        preferences: preferences,
      );
      addTearDown(() {
        preferences.dispose();
        controller.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: CatalogGate(
            controller: controller,
            onReady: () async {},
            ready: (_) => const Scaffold(body: Text('main')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.text('main'), findsOneWidget);
      expect(find.byType(ComicSourceSelectionPage), findsNothing);
    },
  );
}
