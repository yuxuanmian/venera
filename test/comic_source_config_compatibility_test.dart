// Cross-repository release gate for feature 008 (tasks T003 and T059).
//
// This test parses **every** script currently listed by the sibling
// `venera-configs/index.json` through the real Host parser with
// `register: false`, `loadData: false` and `scheduleInit: false`, and compares
// each script's *ordinary* capability shape against the committed, pre-change
// baseline `test/fixtures/comic_source_config_capabilities.json`.
//
// The projection is deliberately narrow and stable:
//   * identity: script `key` / `version` and the index entry metadata;
//   * presence/shape of the ordinary capabilities (search page/cursor form,
//     search option labels/types/defaults, category, category-comics,
//     favorites, explore pages, account and comic loader slots, tag
//     navigation, settings/translation key sets).
// It deliberately records **nothing** from the new optional semantic
// capability (`search.tagSearch`), and no URLs, headers, cookies, tokens or
// other account data, so the fixture cannot leak or drift over presentation
// details.
//
// Modes
// -----
//   * default (no env): the suite is explicitly skipped, so ordinary
//     single-repository CI stays green. The sibling repository is not
//     guaranteed to exist there.
//   * `VENERA_CONFIGS_REQUIRED=1` (release evidence): `VENERA_CONFIGS_DIR`
//     must point at the `venera-configs` checkout. A missing variable,
//     missing directory or a directory without usable index scripts FAILS the
//     test instead of skipping.
//   * `VENERA_CONFIGS_BASELINE_WRITE=1` (maintainer-only regeneration): writes
//     the fixture from `VENERA_CONFIGS_DIR`. The fixture is never written by a
//     default run.
//
// Regenerate the baseline deliberately with:
//
//   cd venera
//   $env:VENERA_CONFIGS_DIR = (Resolve-Path '..\venera-configs').Path
//   $env:VENERA_CONFIGS_BASELINE_WRITE = '1'
//   flutter test --no-pub test\comic_source_config_compatibility_test.dart
//   Remove-Item Env:\VENERA_CONFIGS_BASELINE_WRITE
//
// Review the resulting diff and keep the capability comparison unchanged.
// A declared `version` bump (for example the gated Pica `1.0.8 -> 1.0.9` step
// in task T060) is reported as an ordinary metadata change: refresh the
// baseline only for that deliberate bump, and never to hide a changed
// ordinary capability shape.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';

/// Path of the committed ordinary-capability baseline.
const String baselineFilePath =
    'test/fixtures/comic_source_config_capabilities.json';

/// Schema version of the baseline document itself.
const int baselineSchemaVersion = 1;

/// Baseline keys compared strictly per script. `indexName` is informational
/// only: a display-name change is not an ordinary capability change.
const List<String> _comparedEntryKeys = [
  'fileName',
  'indexKey',
  'indexVersion',
  'capability',
];

const String _requiredEnv = 'VENERA_CONFIGS_REQUIRED';
const String _directoryEnv = 'VENERA_CONFIGS_DIR';
const String _writeEnv = 'VENERA_CONFIGS_BASELINE_WRITE';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final environment = Platform.environment;
  final required = environment[_requiredEnv] == '1';
  final writeBaseline = environment[_writeEnv] == '1';
  final configsDirectory = environment[_directoryEnv]?.trim();

  late Directory dataDirectory;

  setUpAll(() async {
    dataDirectory = await Directory.systemTemp.createTemp(
      'venera-config-compatibility-',
    );
    App.dataPath = dataDirectory.path;
    await JsEngine().init();
  });

  tearDownAll(() async {
    if (await dataDirectory.exists()) {
      await dataDirectory.delete(recursive: true);
    }
  });

  test(
    'every venera-configs script keeps its pre-change ordinary capability shape',
    () async {
      if (configsDirectory == null || configsDirectory.isEmpty) {
        fail(
          '$_requiredEnv=1 requires $_directoryEnv to point at the sibling '
          'venera-configs checkout (for example '
          r"VENERA_CONFIGS_DIR=(Resolve-Path '..\venera-configs').Path"
          '). The cross-repository release smoke test must fail instead of '
          'silently passing when the configs repository is unavailable.',
        );
      }
      final directory = Directory(configsDirectory);
      if (!await directory.exists()) {
        fail(
          '$_directoryEnv points at a directory that does not exist: '
          '${directory.path}',
        );
      }

      final scripts = await _readIndexScripts(directory);
      if (scripts.isEmpty) {
        fail(
          'the directory named by $_directoryEnv contains no usable index '
          'scripts: ${directory.path}${Platform.pathSeparator}index.json must '
          'list at least one script.',
        );
      }

      final projected = <Map<String, Object?>>[];
      for (final script in scripts) {
        projected.add(await _projectScript(directory, script));
      }

      if (writeBaseline) {
        final document = {
          'schemaVersion': baselineSchemaVersion,
          'kind': 'venera-configs ordinary capability shape',
          'regeneratedBy':
              'VENERA_CONFIGS_BASELINE_WRITE=1 flutter test --no-pub '
              'test/comic_source_config_compatibility_test.dart',
          'note':
              'Pre-change baseline for feature 008 (T003/T059). It records '
              'only ordinary capability shape: no semantic tagSearch data, no '
              'URLs, headers, cookies or account data.',
          'entries': projected,
        };
        final file = File(baselineFilePath);
        await file.parent.create(recursive: true);
        await file.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(document)}\n',
          flush: true,
        );
        stdout.writeln(
          '[config-baseline] wrote ${projected.length} script projections to '
          '${file.path}',
        );
        for (final entry in projected) {
          stdout.writeln('[config-baseline] ${_reportLine(entry)}');
        }
        // Round-trip the freshly written baseline so a regeneration cannot
        // persist something this test would immediately reject.
        final reread = await _readBaseline();
        final problems = _compareBaseline(reread, projected);
        if (problems.isNotEmpty) {
          fail(
            'the regenerated baseline does not round-trip:\n'
            '${problems.join('\n')}',
          );
        }
        return;
      }

      final baseline = await _readBaseline();
      for (final entry in projected) {
        stdout.writeln('[config-smoke] ${_reportLine(entry)}');
      }

      final problems = _compareBaseline(baseline, projected);
      if (problems.isNotEmpty) {
        final metadataOnly = problems.every(
          (problem) =>
              problem.contains('indexVersion') ||
              problem.contains('capability.version'),
        );
        fail(
          'the ordinary capability shape of venera-configs changed '
          '(${projected.length} scripts checked). '
          '${metadataOnly ? 'Only the declared version metadata changed: if '
                    'this is the deliberate, gated config version bump, '
                    'regenerate $baselineFilePath with '
                    '$_writeEnv=1 and verify that no capability entry moved. ' : ''}'
          'Every difference must be explained before a Pica/index version is '
          'raised:\n${problems.join('\n')}',
        );
      }

      stdout.writeln(
        '[config-smoke] checked ${projected.length} index scripts against '
        '$baselineFilePath: ordinary capability shape unchanged',
      );
    },
    skip: !required && !writeBaseline
        ? 'Cross-repository comic-source config smoke test skipped: this '
              'suite parses every script listed by the sibling '
              'venera-configs/index.json, which is not available in an '
              'ordinary single-repository CI run. Release evidence must run it '
              'in required mode: set $_requiredEnv=1 and $_directoryEnv=<path '
              'to venera-configs>. Regenerate the baseline with $_writeEnv=1 '
              'and the same $_directoryEnv.'
        : null,
  );
}

/// One script listed by `index.json`.
class _IndexScript {
  const _IndexScript({
    required this.fileName,
    required this.key,
    required this.version,
    this.name,
  });

  final String fileName;
  final String key;
  final String version;
  final String? name;
}

/// Reads and validates the index listing without inventing any fallback: a
/// malformed index must fail required mode instead of shrinking the smoke set.
Future<List<_IndexScript>> _readIndexScripts(Directory directory) async {
  final indexFile = File(
    '${directory.path}${Platform.pathSeparator}index.json',
  );
  if (!await indexFile.exists()) {
    fail(
      'no index.json in ${directory.path}: the required-mode config smoke '
      'needs the actual index listing to know which scripts to parse.',
    );
  }
  Object? decoded;
  try {
    decoded = jsonDecode(await indexFile.readAsString());
  } catch (error) {
    fail('${indexFile.path} is not valid JSON: $error');
  }
  if (decoded is! List) {
    fail('${indexFile.path} must be a JSON array of source entries');
  }
  final scripts = <_IndexScript>[];
  final seen = <String>{};
  for (final item in decoded) {
    if (item is! Map) {
      fail('${indexFile.path} contains a non-object entry: $item');
    }
    final fileName = item['fileName'];
    final key = item['key'];
    final version = item['version'];
    final name = item['name'];
    if (fileName is! String ||
        fileName.isEmpty ||
        key is! String ||
        key.isEmpty ||
        version is! String ||
        version.isEmpty) {
      fail('${indexFile.path} entry is missing fileName/key/version: $item');
    }
    if (!seen.add(fileName)) {
      fail('${indexFile.path} lists $fileName more than once');
    }
    scripts.add(
      _IndexScript(
        fileName: fileName,
        key: key,
        version: version,
        name: name is String ? name : null,
      ),
    );
  }
  return scripts;
}

/// Parses one listed script through the real Host parser and projects its
/// ordinary capability shape.
Future<Map<String, Object?>> _projectScript(
  Directory directory,
  _IndexScript script,
) async {
  final file = File(
    '${directory.path}${Platform.pathSeparator}${script.fileName}',
  );
  if (!await file.exists()) {
    fail(
      '${script.fileName} is listed by index.json but missing from '
      '${directory.path}',
    );
  }
  final ComicSource source;
  try {
    source = await ComicSourceParser().parse(
      await file.readAsString(),
      file.path,
      register: false,
      loadData: false,
      scheduleInit: false,
      allowExistingKey: true,
    );
  } catch (error) {
    fail(
      'the Host parser could not parse ${script.fileName} '
      '(index key ${script.key}, version ${script.version}): $error',
    );
  }
  return {
    'fileName': script.fileName,
    'indexKey': script.key,
    'indexVersion': script.version,
    'indexName': script.name,
    'capability': _projectCapability(source),
  };
}

/// The narrow, deliberately stable ordinary capability projection.
///
/// Everything here is structural (presence, type, arity-relevant slot, option
/// label/type/default, key sets). No semantic capability field, URL, header,
/// cookie or account value is recorded.
Map<String, Object?> _projectCapability(ComicSource source) {
  final search = source.searchPageData;
  final category = source.categoryData;
  final categoryComics = source.categoryComicsData;
  final favorites = source.favoriteData;
  final account = source.account;
  final ranking = categoryComics?.rankingData;
  return {
    'key': source.key,
    'version': source.version,
    'search': search == null
        ? null
        : {
            'loadPage': search.loadPage != null,
            'loadNext': search.loadNext != null,
            'optionList': [
              for (final option
                  in search.searchOptions ?? const <SearchOptions>[])
                {
                  'label': option.label,
                  'type': option.type,
                  'defaultValue': option.defaultValue,
                  'choices': _sortedPairs(option.options),
                },
            ],
          },
    'category': category == null
        ? null
        : {
            'title': category.title,
            'enableRankingPage': category.enableRankingPage,
            'parts': [
              for (final part in category.categories)
                _projectCategoryPart(part),
            ],
          },
    'categoryComics': categoryComics == null
        ? null
        : {
            'optionList': [
              for (final option
                  in categoryComics.options ?? const <CategoryComicsOptions>[])
                {
                  'label': option.label,
                  'choices': _sortedPairs(option.options),
                  'notShowWhen': option.notShowWhen,
                  'showWhen': option.showWhen,
                },
            ],
            'optionLoader': categoryComics.optionsLoader != null,
            'ranking': ranking == null
                ? null
                : {
                    'choices': _sortedPairs(ranking.options),
                    'load': ranking.load != null,
                    'loadWithNext': ranking.loadWithNext != null,
                  },
          },
    'favorites': favorites == null
        ? null
        : {
            'title': favorites.title,
            'multiFolder': favorites.multiFolder,
            'singleFolderForSingleComic': favorites.singleFolderForSingleComic,
            'loadComic': favorites.loadComic != null,
            'loadNext': favorites.loadNext != null,
            'loadFolders': favorites.loadFolders != null,
            'addFolder': favorites.addFolder != null,
            'deleteFolder': favorites.deleteFolder != null,
            'addOrDelFavorite': favorites.addOrDelFavorite != null,
            'updateCheck': favorites.updateCheck != null,
          },
    'explore': [
      for (final page in source.explorePages)
        {
          'title': page.title,
          'type': page.type.name,
          'loadPage': page.loadPage != null,
          'loadNext': page.loadNext != null,
          'loadMultiPart': page.loadMultiPart != null,
          'loadMixed': page.loadMixed != null,
        },
    ],
    'account': account == null
        ? null
        : {
            'login': account.login != null,
            'checkLoginStatus': account.checkLoginStatus != null,
            'cookieFieldCount': account.cookieFields?.length ?? 0,
            'validateCookies': account.validateCookies != null,
          },
    'comic': {
      'thumbnailLoader': source.loadComicThumbnail != null,
      'imageLoadingConfig': source.getImageLoadingConfig != null,
      'thumbnailLoadingConfig': source.getThumbnailLoadingConfig != null,
      'commentsLoader': source.commentsLoader != null,
      'sendComment': source.sendCommentFunc != null,
      'chapterCommentsLoader': source.chapterCommentsLoader != null,
      'sendChapterComment': source.sendChapterCommentFunc != null,
      'likeComic': source.likeOrUnlikeComic != null,
      'voteComment': source.voteCommentFunc != null,
      'likeComment': source.likeCommentFunc != null,
      'idMatcher': source.idMatcher != null,
      'starRating': source.starRatingFunc != null,
      'archiveDownloader': source.archiveDownloader != null,
    },
    'tagNavigation': {
      'onClickTag': source.handleClickTagEvent != null,
      'onTagSuggestionSelected': source.onTagSuggestionSelected != null,
      'linkHandler': source.linkHandler != null,
      'enableTagsSuggestions': source.enableTagsSuggestions,
      'enableTagsTranslate': source.enableTagsTranslate,
    },
    'settingsKeys': _sortedKeys(source.settings),
    'translationLanguages': _sortedKeys(source.translations),
  };
}

/// Projects one category part *without* invoking its loader.
///
/// `DynamicCategoryPart.categories` runs the source's JavaScript loader and
/// `RandomCategoryPart.categories` is non-deterministic, so the projection
/// reads only the structural fields that are stored on the part itself. This
/// keeps the smoke test free of network calls and of run-to-run variance.
Map<String, Object?> _projectCategoryPart(BaseCategoryPart part) {
  return switch (part) {
    FixedCategoryPart() => {
      'title': part.title,
      'enableRandom': part.enableRandom,
      'kind': 'fixed',
      'count': part.categories.length,
    },
    RandomCategoryPart() => {
      'title': part.title,
      'enableRandom': part.enableRandom,
      'kind': 'random',
      'count': part.all.length,
      'randomNumber': part.randomNumber,
    },
    DynamicCategoryPart() => {
      'title': part.title,
      'enableRandom': part.enableRandom,
      'kind': 'dynamic',
      'loader': true,
    },
    _ => {
      'title': part.title,
      'enableRandom': part.enableRandom,
      'kind': 'unknown',
    },
  };
}

Map<String, String> _sortedPairs(Map<String, String> input) {
  final keys = input.keys.toList()..sort();
  return {for (final key in keys) key: input[key]!};
}

List<String> _sortedKeys(Map<String, dynamic>? input) {
  if (input == null) return const [];
  return input.keys.toList()..sort();
}

Future<Map<String, Map<String, Object?>>> _readBaseline() async {
  final file = File(baselineFilePath);
  if (!await file.exists()) {
    fail(
      'the ordinary capability baseline is missing: ${file.absolute.path}. '
      'It must be committed before Host parser changes; regenerate it with '
      '$_writeEnv=1 and $_directoryEnv set.',
    );
  }
  Object? decoded;
  try {
    decoded = jsonDecode(await file.readAsString());
  } catch (error) {
    fail('$baselineFilePath is not valid JSON: $error');
  }
  if (decoded is! Map || decoded['entries'] is! List) {
    fail('$baselineFilePath must be an object with an "entries" array');
  }
  final schema = decoded['schemaVersion'];
  if (schema != baselineSchemaVersion) {
    fail(
      '$baselineFilePath has schemaVersion $schema, expected '
      '$baselineSchemaVersion',
    );
  }
  final entries = <String, Map<String, Object?>>{};
  for (final item in decoded['entries'] as List) {
    if (item is! Map) fail('$baselineFilePath contains a non-object entry');
    final entry = Map<String, Object?>.from(item);
    final fileName = entry['fileName'];
    if (fileName is! String) {
      fail('$baselineFilePath entry without a fileName: $item');
    }
    entries[fileName] = entry;
  }
  return entries;
}

/// Compares the committed baseline with the freshly projected scripts and
/// returns one human-readable line per difference; an empty list means the
/// ordinary capability shape is unchanged and every script was checked.
List<String> _compareBaseline(
  Map<String, Map<String, Object?>> baseline,
  List<Map<String, Object?>> projected,
) {
  final problems = <String>[];
  final checked = <String>{};
  for (final entry in projected) {
    final fileName = entry['fileName'] as String;
    checked.add(fileName);
    final expected = baseline[fileName];
    if (expected == null) {
      problems.add(
        '$fileName is listed by index.json but absent from the baseline '
        '(new script)',
      );
      continue;
    }
    for (final key in _comparedEntryKeys) {
      final expectedValue = jsonEncode(expected[key]);
      final actualValue = jsonEncode(entry[key]);
      if (expectedValue != actualValue) {
        if (key == 'capability') {
          problems.addAll(
            _diffMaps(
              'capability',
              (expected[key] as Map?)?.cast<String, Object?>() ??
                  const <String, Object?>{},
              (entry[key] as Map?)?.cast<String, Object?>() ??
                  const <String, Object?>{},
            ),
          );
        } else {
          problems.add(
            '$fileName $key: baseline $expectedValue != current $actualValue',
          );
        }
      }
    }
  }
  for (final fileName in baseline.keys) {
    if (!checked.contains(fileName)) {
      problems.add(
        '$fileName is in the baseline but is no longer listed by index.json '
        '(removed script)',
      );
    }
  }
  problems.sort();
  return problems;
}

List<String> _diffMaps(
  String path,
  Map<String, Object?> expected,
  Map<String, Object?> actual,
) {
  final problems = <String>[];
  final keys = {...expected.keys, ...actual.keys}.toList()..sort();
  for (final key in keys) {
    final childPath = '$path.$key';
    final expectedValue = expected[key];
    final actualValue = actual[key];
    if (expectedValue is Map && actualValue is Map) {
      problems.addAll(
        _diffMaps(
          childPath,
          expectedValue.cast<String, Object?>(),
          actualValue.cast<String, Object?>(),
        ),
      );
      continue;
    }
    if (jsonEncode(expectedValue) != jsonEncode(actualValue)) {
      problems.add(
        '$childPath: baseline ${jsonEncode(expectedValue)} != current '
        '${jsonEncode(actualValue)}',
      );
    }
  }
  return problems;
}

String _reportLine(Map<String, Object?> entry) {
  final capability = (entry['capability'] as Map).cast<String, Object?>();
  final search = capability['search'];
  final searchForm = search == null
      ? 'no-search'
      : (search as Map)['loadPage'] == true
      ? 'search.page'
      : 'search.cursor';
  return '${entry['fileName']} key=${capability['key']} '
      'version=${capability['version']} '
      '(index ${entry['indexVersion']}) $searchForm '
      'category=${capability['category'] != null} '
      'categoryComics=${capability['categoryComics'] != null} '
      'favorites=${capability['favorites'] != null} '
      'explore=${(capability['explore'] as List).length}';
}
