import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

/// Contract: 007 FR-025 / FR-026 / FR-027, US5.
///
/// The Favorites settings entry is **removed** in both layouts, the list stays
/// contiguous after the removal, and the one switch worth keeping moved to the
/// APP page with its storage key and behaviour unchanged.
///
/// The repository had no settings-page test before this one; the layout switch is
/// `context.width > 720`, so each claim is asserted at a wide and a narrow
/// viewport rather than once.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late bool previousAutoClose;

  setUpAll(() async {
    await AppTranslation.init();
  });

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('venera-settings-');
    App.dataPath = tempDir.path;
    App.cachePath = tempDir.path;
    // The APP settings page reads the local-comics path, which is only available
    // after this init; without it the page throws instead of rendering.
    await LocalManager().init();
    previousAutoClose = appdata.settings['autoCloseFavoritePanel'] as bool;
  });

  tearDown(() {
    appdata.settings['autoCloseFavoritePanel'] = previousAutoClose;
    try {
      tempDir.deleteSync(recursive: true);
    } on PathAccessException {
      // Windows may hold a handle briefly.
    }
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    required bool wide,
    int initialPage = -1,
  }) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = wide
        ? const Size(1200, 900)
        : const Size(420, 900);
    await tester.pumpWidget(
      MaterialApp(
        home: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute(
            // A fresh key per pump: `initialPage` is read in `initState`, so
            // reusing the State would silently keep the previous index.
            builder: (_) => SettingsPage(
              key: ValueKey('settings-$wide-$initialPage'),
              initialPage: initialPage,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The sidebar's own tappable row for one category.
  ///
  /// Scoped this way on purpose: in the wide layout the right pane can render
  /// the same word as a page title, and a bare `find.text` tap would hit that
  /// instead of the navigation row.
  Finder categoryEntry(String label) => find
      .ancestor(of: find.text(label.tl), matching: find.byType(InkWell))
      .first;

  /// Consumes the **pre-existing** framework assertion that the Debug settings
  /// page produces in debug mode.
  ///
  /// Its developer-mode card nests a `SwitchListTile` inside a decorated
  /// `Container` with no `Material` in between, which Flutter asserts about at
  /// build time.  The defect predates 007, is debug-only, and lives in a file
  /// outside 007's change surface, so it is registered in the implementation
  /// evidence rather than fixed here.  Anything else coming out of that page is
  /// still a failure.
  void consumePreExistingDebugPageAssertion(WidgetTester tester) {
    final pending = tester.takeException();
    if (pending == null) return;
    expect(
      pending.toString(),
      contains('ListTile background color or ink splashes may be invisible'),
      reason:
          'the only exception the Debug settings page may produce is the '
          'registered pre-existing ListTile assertion',
    );
    expect(tester.takeException(), isNull);
  }

  const survivingCategories = <String>[
    'Explore',
    'Reading',
    'Appearance',
    'APP',
    'Network',
    'About',
    'Debug',
  ];

  testWidgets('the Favorites entry is gone in both layouts', (tester) async {
    for (final wide in <bool>[true, false]) {
      await pumpSettings(tester, wide: wide);
      expect(
        find.text('Favorites'.tl),
        findsNothing,
        reason: 'the Favorites settings entry must be removed (wide=$wide)',
      );
      expect(
        find.text('Follow Update Threads'.tl),
        findsNothing,
        reason: 'the dead thread knob must not be reachable (wide=$wide)',
      );
      expect(
        find.text('Follow Update Batch Delay (seconds)'.tl),
        findsNothing,
        reason: 'the dead batch-delay knob must not be reachable (wide=$wide)',
      );
      for (final label in survivingCategories) {
        expect(
          find.text(label.tl),
          findsWidgets,
          reason: '"$label" must still be listed (wide=$wide)',
        );
      }
    }
  });

  testWidgets('the index list stays contiguous: index 3 is the APP page', (
    tester,
  ) async {
    // The list is index-driven, so dropping an item without renumbering would
    // leave a category pointing at the wrong page or at nothing.  The wide
    // layout drives `_buildSettingsContent` directly through `initialPage`,
    // which is the deterministic form of the same mapping a tap exercises.
    await pumpSettings(tester, wide: true, initialPage: 3);
    expect(find.byType(AppSettings), findsOneWidget);
    expect(
      find.text('Auto close favorite panel after operation'.tl),
      findsOneWidget,
    );
  });

  testWidgets('the index list stays contiguous: index 5 is the About page', (
    tester,
  ) async {
    await pumpSettings(tester, wide: true, initialPage: 5);
    expect(
      find.byType(AboutSettings),
      findsOneWidget,
      reason: 'index 5 must be the About page (0-based, 7 categories)',
    );
  });

  testWidgets('the index list stays contiguous: index 6 is the last page', (
    tester,
  ) async {
    await pumpSettings(tester, wide: true, initialPage: 6);
    consumePreExistingDebugPageAssertion(tester);
    expect(
      find.byType(DebugPage),
      findsOneWidget,
      reason: 'index 6 must be the (last) Debug page: 7 categories, 0..6',
    );
  });

  testWidgets('the narrow layout reaches the last page by tapping', (
    tester,
  ) async {
    await pumpSettings(tester, wide: false);

    await tester.tap(categoryEntry('Debug'));
    await tester.pumpAndSettle();
    consumePreExistingDebugPageAssertion(tester);
    expect(find.byType(DebugPage), findsOneWidget);

    // …and back, so the sidebar is still usable after a detail navigation.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Explore'.tl), findsWidgets);
    expect(find.text('Favorites'.tl), findsNothing);
  });

  testWidgets('the surviving switch lives on the APP page and still works', (
    tester,
  ) async {
    appdata.settings['autoCloseFavoritePanel'] = false;
    await pumpSettings(tester, wide: true, initialPage: 3);

    final row = find.ancestor(
      of: find.text('Auto close favorite panel after operation'.tl),
      matching: find.byType(ListTile),
    );
    expect(row, findsOneWidget);

    await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
    await tester.pumpAndSettle();

    expect(
      appdata.settings['autoCloseFavoritePanel'],
      isTrue,
      reason: 'the switch must write the same storage key it always did',
    );
    // A second tap flips it back, which is what the old page did.
    await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    expect(appdata.settings['autoCloseFavoritePanel'], isFalse);
  });

  test('the favourite panel still reads that same key', () {
    // The behaviour half: the panel closes itself only when the key says so.
    // Asserted from the source so a rename cannot quietly disconnect the switch
    // from the behaviour it controls.
    final panel = File(
      'lib/pages/comic_details_page/favorite.dart',
    ).readAsStringSync();
    expect(panel, contains("appdata.settings['autoCloseFavoritePanel']"));
    expect(panel, contains('context.pop()'));
  });

  test('the retired knob keys survive in the settings defaults', () {
    // FR-027: the data is kept.  Removing the default would make a user's stored
    // value the only copy, and removing it from the store is out of scope
    // (FR-031).
    expect(appdata.settings['followUpdateThreads'], isNotNull);
    expect(appdata.settings['followUpdateBatchDelay'], isNotNull);
  });

  test('the settings list and its icons stay the same length', () {
    // A structural guard for the two parallel lists: an item removed from one
    // and not the other shifts every icon by one from that point on, which no
    // widget assertion here would notice.
    final source = File(
      'lib/pages/settings/settings_page.dart',
    ).readAsStringSync();
    expect(source, isNot(contains('Favorites"')));
    expect(source, isNot(contains('collections_bookmark_rounded')));
    final categories = source.substring(
      source.indexOf('final categories = <String>['),
      source.indexOf('final icons = <IconData>['),
    );
    final icons = source.substring(
      source.indexOf('final icons = <IconData>['),
      source.indexOf('@override\n  void initState()'),
    );
    String firstIdentifier(String line) {
      final match = RegExp(
        r'^\s*(?:"([^"]+)"|(Icons\.[A-Za-z_]+))',
      ).firstMatch(line);
      if (match == null) return '';
      return match.group(1) ?? match.group(2) ?? '';
    }

    final categoryNames = categories
        .split('\n')
        .map(firstIdentifier)
        .where((value) => value.isNotEmpty)
        .toList();
    final iconNames = icons
        .split('\n')
        .map(firstIdentifier)
        .where((value) => value.isNotEmpty)
        .toList();
    expect(categoryNames, [
      'Explore',
      'Reading',
      'Appearance',
      'APP',
      'Network',
      'About',
      'Debug',
    ]);
    expect(iconNames, hasLength(categoryNames.length));
  });
}
