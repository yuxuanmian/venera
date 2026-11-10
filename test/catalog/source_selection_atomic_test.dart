import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/source_pages.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

ComicSource _addedSource() => ComicSource(
  'Added',
  'added',
  null,
  CategoryData(
    title: 'Added',
    categories: [],
    enableRankingPage: false,
    key: 'added_category',
  ),
  null,
  FavoriteData(
    key: 'added_favorite',
    title: 'Added',
    multiFolder: false,
    loadComic: null,
    loadNext: null,
  ),
  [
    ExplorePageData(
      'Added explore',
      ExplorePageType.multiPageComicList,
      null,
      null,
      null,
      null,
    ),
  ],
  const SearchPageData(null, null, null),
  null,
  null,
  null,
  null,
  null,
  null,
  'added.js',
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

SourcePreferences _preferences(
  Appdata target,
  List<String> initial,
  ComicSource source,
) {
  return SourcePreferences(
    initial: initial,
    selectionApplier: (added, removed, patchSettings) =>
        target.updateEnabledSourcesAndSettings((raw) {
          final next = List<String>.from(
            SourcePreferences.normalizeOrPrevious(raw, initial) ?? const [],
          );
          next.removeWhere(removed.contains);
          next.addAll(added.where((key) => !next.contains(key)));
          return SourcePreferences.normalizeSelection(next);
        }, patchSettings: patchSettings),
  );
}

void main() {
  late Directory root;
  late bool wasInitialized;
  String? oldDataPath;

  setUp(() async {
    wasInitialized = App.isInitialized;
    oldDataPath = wasInitialized ? App.dataPath : null;
    root = await Directory.systemTemp.createTemp('source-selection-atomic-');
    App.dataPath = root.path;
  });

  tearDown(() async {
    if (wasInitialized) {
      App.dataPath = oldDataPath!;
    } else {
      App.isInitialized = false;
    }
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'selection delta preserves unknown keys and atomically adds defaults',
    () async {
      final target = Appdata.createForTesting(() async => root);
      await target.persistEnabledSources(['alpha', 'beta', 'unknown']);
      await target.persistEnabledSources([
        'alpha',
        'beta',
        'external',
        'unknown',
      ]);
      final source = _addedSource();
      final preferences = _preferences(target, const ['alpha', 'beta'], source);
      addTearDown(preferences.dispose);

      await preferences.applySelectionChanges(
        added: const {'added'},
        removed: const {'alpha'},
        patchSettings: (settings) {
          settings.addAll(defaultSourcePages(settings, source));
        },
      );

      expect(preferences.enabledSources, [
        'added',
        'beta',
        'external',
        'unknown',
      ]);
      expect(target.settings['enabledSources'], [
        'added',
        'beta',
        'external',
        'unknown',
      ]);
      expect(target.settings['explore_pages'], contains('Added explore'));
      expect(target.settings['categories'], contains('added_category'));
      expect(target.settings['favorites'], contains('added_favorite'));
      expect(target.settings['searchSources'], contains('added'));

      final document =
          jsonDecode(await File('${root.path}/appdata.json').readAsString())
              as Map;
      final settings = document['settings'] as Map;
      expect(settings['enabledSources'], [
        'added',
        'beta',
        'external',
        'unknown',
      ]);
      expect(settings['explore_pages'], contains('Added explore'));
    },
  );

  test(
    'write failure leaves old selection and page settings unchanged',
    () async {
      final target = Appdata.createForTesting(() async => root);
      await target.persistEnabledSources(const ['beta']);
      final file = File('${root.path}/appdata.json');
      final before = await file.readAsString();
      final source = _addedSource();
      final preferences = _preferences(target, const ['beta'], source);
      addTearDown(preferences.dispose);
      target.atomicReplace = (_, _) async {
        throw const FileSystemException('injected failure');
      };

      await expectLater(
        preferences.applySelectionChanges(
          added: const {'added'},
          removed: const {'beta'},
          patchSettings: (settings) {
            settings.addAll(defaultSourcePages(settings, source));
          },
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(preferences.enabledSources, ['beta']);
      expect(target.settings['enabledSources'], ['beta']);
      expect(
        target.settings['explore_pages'],
        isNot(contains('Added explore')),
      );
      expect(await file.readAsString(), before);
    },
  );
}
