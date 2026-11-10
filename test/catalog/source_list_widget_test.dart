import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/home_page.dart';
import 'package:venera/utils/app_links.dart';
import 'package:venera/utils/translations.dart';

ComicSource _source(
  String name,
  String key, {
  String version = '1.0.0',
  bool withAccount = false,
  bool logged = false,
  List<ExplorePageData> explorePages = const [],
  CategoryData? categoryData,
  FavoriteData? favoriteData,
  SearchPageData? searchPageData,
  Map<String, Map<String, dynamic>>? settings,
  LinkHandler? linkHandler,
}) {
  final source = ComicSource(
    name,
    key,
    withAccount
        ? AccountConfig(null, null, null, () {}, null, null, null, null)
        : null,
    categoryData,
    null,
    favoriteData,
    explorePages,
    searchPageData,
    settings,
    null,
    null,
    null,
    null,
    null,
    '$key.js',
    '',
    version,
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
    linkHandler,
    false,
    false,
    null,
    null,
  );
  if (logged) source.data['account'] = 'ok';
  return source;
}

void _useTallView(WidgetTester tester, {double height = 1500}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(800, height);
  addTearDown(tester.view.reset);
}

SourcePreferences _preferences(
  List<String> initial, {
  Future<List<String>?> Function(
    Set<String> added,
    Set<String> removed,
    void Function(Map<String, dynamic> settings)? patchSettings,
  )?
  apply,
}) {
  return SourcePreferences(
    initial: initial,
    selectionApplier:
        apply ??
        (added, removed, patchSettings) async {
          final settings = <String, dynamic>{};
          patchSettings?.call(settings);
          final next = List<String>.from(initial)
            ..removeWhere(removed.contains)
            ..addAll(added.where((key) => !initial.contains(key)));
          return SourcePreferences.normalizeSelection(next);
        },
  );
}

void main() {
  setUpAll(AppTranslation.init);

  late List<String> managerKeys;
  late Object? oldEnabled;

  setUp(() {
    final manager = ComicSourceManager();
    managerKeys = manager.all().map((source) => source.key).toList();
    oldEnabled = appdata.settings['enabledSources'];
  });

  tearDown(() {
    final manager = ComicSourceManager();
    for (final source in manager.all().toList()) {
      manager.remove(source.key);
    }
    for (final key in managerKeys) {
      // Existing test sources are not restored because their instances are not
      // available; tests using this singleton start from a clean manager.
      if (manager.find(key) != null) manager.remove(key);
    }
    appdata.settings['enabledSources'] = oldEnabled;
  });

  testWidgets('zero enabled sources shows clear selection destinations', (
    tester,
  ) async {
    final preferences = _preferences(const []);
    addTearDown(preferences.dispose);
    await tester.pumpWidget(
      MaterialApp(home: ComicSourcePage(preferences: preferences)),
    );

    expect(find.byKey(const Key('manage-comic-sources')), findsOneWidget);
    expect(find.byKey(const Key('choose-comic-sources-empty')), findsOneWidget);
    expect(find.text('Choose comic sources'.tl), findsOneWidget);
  });

  testWidgets('home follows manager order, limits six and shows local login', (
    tester,
  ) async {
    _useTallView(tester);
    final sources = [
      _source(
        'A very long comic source name that must stay on one line',
        's1',
        withAccount: true,
        logged: true,
      ),
      for (var index = 2; index <= 8; index++)
        _source('Source $index', 's$index'),
    ];
    final manager = ComicSourceManager();
    for (final source in sources) {
      manager.add(source);
    }
    final preferences = _preferences([
      for (final source in sources.reversed) source.key,
    ]);
    addTearDown(preferences.dispose);

    await tester.pumpWidget(
      MaterialApp(home: ComicSourcePage(preferences: preferences)),
    );

    for (var index = 1; index <= 6; index++) {
      expect(find.byKey(Key('enabled-source-row-s$index')), findsOneWidget);
    }
    expect(find.byKey(const Key('enabled-source-row-s7')), findsNothing);
    expect(
      find.text('View all (@c sources)'.tlParams({'c': 8})),
      findsOneWidget,
    );
    expect(find.text('Logged in'.tl), findsOneWidget);
    final longName = tester.widget<Text>(
      find.text('A very long comic source name that must stay on one line'),
    );
    expect(longName.maxLines, 1);
    expect(longName.overflow, TextOverflow.ellipsis);
  });

  testWidgets('enabled list is separately searchable and opens detail', (
    tester,
  ) async {
    _useTallView(tester);
    final manager = ComicSourceManager();
    for (final source in [
      _source(
        'Alpha',
        'a',
        version: '2.3.4',
        withAccount: true,
        settings: {
          'test_switch': {
            'type': 'switch',
            'title': 'Test source setting',
            'default': false,
          },
        },
      ),
      _source('Beta', 'b'),
      _source('Gamma', 'c'),
    ]) {
      manager.add(source);
    }
    final preferences = _preferences(const ['a', 'b', 'c']);
    addTearDown(preferences.dispose);
    await tester.pumpWidget(
      MaterialApp(home: EnabledComicSourcesPage(preferences: preferences)),
    );

    await tester.enterText(
      find.byKey(const Key('enabled-source-search')),
      'alp',
    );
    await tester.pump();
    expect(find.byKey(const Key('enabled-list-row-a')), findsOneWidget);
    expect(find.byKey(const Key('enabled-list-row-b')), findsNothing);

    await tester.tap(find.byKey(const Key('enabled-list-row-a')));
    await tester.pumpAndSettle();
    expect(find.byType(ComicSourceDetailPage), findsOneWidget);
    expect(find.text('2.3.4'), findsOneWidget);
    expect(find.text('Log in'.tl), findsOneWidget);
    expect(find.text('Test source setting'), findsOneWidget);
  });

  testWidgets('exactly six sources do not show the view-all destination', (
    tester,
  ) async {
    _useTallView(tester);
    final manager = ComicSourceManager();
    for (var index = 1; index <= 6; index++) {
      manager.add(_source('Exact $index', 'e$index'));
    }
    final preferences = _preferences([
      for (var index = 1; index <= 6; index++) 'e$index',
    ]);
    addTearDown(preferences.dispose);
    await tester.pumpWidget(
      MaterialApp(home: ComicSourcePage(preferences: preferences)),
    );

    expect(find.byKey(const Key('view-all-enabled-sources')), findsNothing);
    for (var index = 1; index <= 6; index++) {
      expect(find.text('Exact $index'), findsOneWidget);
    }
  });

  testWidgets('the seventh enabled source switches to the view-all entry', (
    tester,
  ) async {
    _useTallView(tester);
    final manager = ComicSourceManager();
    for (var index = 1; index <= 7; index++) {
      manager.add(_source('Seven $index', 'seven$index'));
    }
    final preferences = _preferences([
      for (var index = 1; index <= 7; index++) 'seven$index',
    ]);
    addTearDown(preferences.dispose);
    await tester.pumpWidget(
      MaterialApp(home: ComicSourcePage(preferences: preferences)),
    );

    expect(find.text('Seven 6'), findsOneWidget);
    expect(find.text('Seven 7'), findsNothing);
    expect(
      find.text('View all (@c sources)'.tlParams({'c': 7})),
      findsOneWidget,
    );
  });

  testWidgets('large source sets keep the homepage preview bounded', (
    tester,
  ) async {
    _useTallView(tester, height: 1800);
    final manager = ComicSourceManager();
    for (var index = 1; index <= 50; index++) {
      manager.add(_source('Bulk $index', 'b$index'));
    }
    final preferences = _preferences([
      for (var index = 1; index <= 50; index++) 'b$index',
    ]);
    addTearDown(preferences.dispose);
    await tester.pumpWidget(
      MaterialApp(home: ComicSourcePage(preferences: preferences)),
    );

    for (var index = 1; index <= 6; index++) {
      expect(find.text('Bulk $index'), findsOneWidget);
    }
    expect(find.text('Bulk 7'), findsNothing);
    expect(
      find.text('View all (@c sources)'.tlParams({'c': 50})),
      findsOneWidget,
    );
  });

  testWidgets('selection editor keeps search/filter separate from draft', (
    tester,
  ) async {
    _useTallView(tester);
    final alpha = _source(
      'Alpha',
      'alpha',
      explorePages: [
        ExplorePageData(
          'Alpha explore',
          ExplorePageType.multiPageComicList,
          null,
          null,
          null,
          null,
        ),
      ],
    );
    final manager = ComicSourceManager()
      ..add(alpha)
      ..add(_source('Beta', 'beta'))
      ..add(_source('Gamma', 'gamma'));
    Set<String>? appliedAdded;
    Set<String>? appliedRemoved;
    Map<String, dynamic>? appliedPages;
    final preferences = _preferences(
      const ['beta'],
      apply: (added, removed, patchSettings) async {
        appliedAdded = added;
        appliedRemoved = removed;
        final settings = <String, dynamic>{};
        patchSettings?.call(settings);
        appliedPages = settings;
        return const ['alpha', 'unknown'];
      },
    );
    addTearDown(preferences.dispose);
    var completed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: ComicSourceSelectionPage(
          preferences: preferences,
          onComplete: () => completed = true,
          onCancel: () {},
          firstRun: true,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('source-selection-search')),
      'alpha',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('source-selection-alpha')));
    await tester.pump();
    expect(
      find.textContaining('Selected @a of @b'.tlParams({'a': 2, 'b': 3})),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('source-selection-search')),
      '',
    );
    await tester.tap(find.text('Selected'.tl));
    await tester.pump();
    expect(find.byKey(const Key('source-selection-alpha')), findsOneWidget);
    expect(find.byKey(const Key('source-selection-beta')), findsOneWidget);
    expect(find.byKey(const Key('source-selection-gamma')), findsNothing);

    await tester.tap(find.byKey(const Key('source-selection-beta')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-comic-source-selection')));
    await tester.pumpAndSettle();

    expect(completed, isTrue);
    expect(appliedAdded, {'alpha'});
    expect(appliedRemoved, {'beta'});
    expect(appliedPages?['explore_pages'], contains('Alpha explore'));
    expect(preferences.enabledSources, ['alpha', 'unknown']);
    expect(manager.find('alpha'), same(alpha));
  });

  testWidgets('dirty return requires explicit discard confirmation', (
    tester,
  ) async {
    _useTallView(tester);
    final source = _source('Alpha', 'alpha');
    ComicSourceManager().add(source);
    final preferences = _preferences(const []);
    addTearDown(preferences.dispose);
    var cancelled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: ComicSourceSelectionPage(
          preferences: preferences,
          onComplete: () {},
          onCancel: () => cancelled = true,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('source-selection-alpha')));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(find.text('Discard unsaved changes?'.tl), findsOneWidget);
    await tester.tap(find.text('Continue editing'.tl));
    await tester.pumpAndSettle();
    expect(cancelled, isFalse);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard changes'.tl));
    await tester.pumpAndSettle();
    expect(cancelled, isTrue);
  });

  testWidgets('save failure retains the draft and allows empty selection', (
    tester,
  ) async {
    _useTallView(tester);
    for (final source in [_source('Alpha', 'alpha'), _source('Beta', 'beta')]) {
      ComicSourceManager().add(source);
    }
    var fail = true;
    var completed = 0;
    final pendingSave = Completer<void>();
    final preferences = _preferences(
      const [],
      apply: (added, removed, patchSettings) async {
        if (fail) {
          await pendingSave.future;
          throw StateError('injected');
        }
        return const [];
      },
    );
    addTearDown(preferences.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ComicSourceSelectionPage(
          preferences: preferences,
          onComplete: () => completed++,
          onCancel: () {},
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('source-selection-alpha')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-comic-source-selection')));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Discard unsaved changes?'.tl), findsNothing);

    pendingSave.complete();
    await tester.pumpAndSettle();

    expect(
      find.text('Failed to save comic source selection. Try again.'.tl),
      findsOneWidget,
    );
    final alpha = tester.widget<CheckboxListTile>(
      find.byKey(const Key('source-selection-alpha')),
    );
    expect(alpha.value, isTrue);

    await tester.tap(find.byKey(const Key('source-selection-alpha')));
    await tester.pump();
    fail = false;
    await tester.tap(find.byKey(const Key('save-comic-source-selection')));
    await tester.pumpAndSettle();
    expect(completed, 1);
    expect(preferences.enabledSources, isEmpty);
  });

  testWidgets('home preview caps names at six and refreshes preferences', (
    tester,
  ) async {
    _useTallView(tester);
    final manager = ComicSourceManager();
    for (var index = 1; index <= 8; index++) {
      manager.add(_source('Preview $index', 'p$index'));
    }
    appdata.settings['enabledSources'] = [
      for (var index = 1; index <= 8; index++) 'p$index',
    ];

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CustomScrollView(slivers: [ComicSourcePreviewCard()]),
        ),
      ),
    );
    for (var index = 1; index <= 6; index++) {
      expect(find.text('Preview $index'), findsOneWidget);
    }
    expect(find.text('Preview 7'), findsNothing);
    expect(find.text('+2'), findsOneWidget);

    appdata.settings['enabledSources'] = ['p1', 'p2'];
    await tester.pump();
    expect(find.text('Preview 1'), findsOneWidget);
    expect(find.text('Preview 2'), findsOneWidget);
    expect(find.text('Preview 3'), findsNothing);
    expect(find.text('+2'), findsNothing);
  });

  test('disabled external links only prompt for source management', () async {
    final source = _source(
      'External',
      'external',
      linkHandler: LinkHandler(['example.com'], (_) => 'comic-1'),
    );
    ComicSourceManager().add(source);
    String? message;

    final handled = await handleAppLink(
      Uri.parse('https://example.com/comic/1'),
      onDisabledSource: (value) => message = value,
    );

    expect(handled, isTrue);
    expect(message, isNotNull);
  });

  test('source UI exposes no per-source update controls', () {
    for (final path in [
      'lib/pages/comic_source_page.dart',
      'lib/pages/home_page.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('availableUpdates')), reason: path);
      expect(source, isNot(contains('New Version')), reason: path);
    }
  });
}
