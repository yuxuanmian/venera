import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/scan/source_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dataDirectory;

  setUpAll(() async {
    dataDirectory = await Directory.systemTemp.createTemp(
      'venera-comic-source-parser-',
    );
    App.dataPath = dataDirectory.path;
    await JsEngine().init();
  });

  tearDownAll(() async {
    if (await dataDirectory.exists()) {
      await dataDirectory.delete(recursive: true);
    }
  });

  test('parses a source without an optional search object', () async {
    const key = 'parser_missing_search_case';
    final source = await ComicSourceParser().parse('''
class ParserMissingSearchSource extends ComicSource {
  name = "Parser missing search";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  comic = {
    loadInfo: async (id) => ({}),
    loadEp: async (comicId, epId) => ({images: []}),
  };
}
''', '$key.js');

    expect(source.key, key);
    expect(source.searchPageData, isNull);
    expect(source.onTagSuggestionSelected, isNull);
    expect(source.enableTagsSuggestions, isFalse);
    expect(source.loadComicInfo, isNotNull);
    expect(source.loadComicPages, isNotNull);
  });

  test('retains search data and tag suggestion callback', () async {
    const key = 'parser_full_search_case';
    final source = await ComicSourceParser().parse('''
class ParserFullSearchSource extends ComicSource {
  name = "Parser full search";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  search = {
    load: async (keyword, options, page) => ({comics: [], maxPage: 1}),
    enableTagsSuggestions: true,
    onTagSuggestionSelected: (namespace, tag) => `\${namespace}:\${tag}`,
  };
  comic = {
    loadInfo: async (id) => ({}),
    loadEp: async (comicId, epId) => ({images: []}),
  };
}
''', '$key.js');

    expect(source.searchPageData, isNotNull);
    expect(source.searchPageData!.loadPage, isNotNull);
    expect(source.enableTagsSuggestions, isTrue);
    expect(source.onTagSuggestionSelected, isNotNull);
    expect(source.onTagSuggestionSelected!('artist', 'alice'), 'artist:alice');
  });

  test('a declared list update capability is no longer parsed', () async {
    const key = 'parser_favorite_update_case';
    final source = await ComicSourceParser().parse('''
class ParserFavoriteUpdateSource extends ComicSource {
  name = "Parser favorite update";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  favorites = {
    multiFolder: false,
    updateCheck: {
      markerScheme: "test-list-v1",
      scanInterval: 3600,
      load: async (folderId) => ({
        comics: [new Comic({
          id: "comic-1",
          title: "Comic 1",
          cover: "cover",
          tags: [],
          description: "",
          favoriteUpdate: {
            marker: "marker-1",
            updateTime: "2026-08-20",
            isNew: false,
            metadata: {fullIsNew: true},
          },
        })],
        pageSize: 15,
        total: 1,
      }),
    },
    loadComics: async (page, folder) => ({comics: [], maxPage: 1}),
  };
}
''', '$key.js');

    // FR-044/FR-045: the application side reads no list-level snapshot.  The
    // source still declares it for older app versions, so parsing must succeed
    // and simply leave the capability absent, while the ordinary favorites
    // loader keeps working.
    expect(source.key, key);
    expect(source.favoriteData, isNotNull);
    expect(source.favoriteData!.updateCheck, isNull);
    expect(source.favoriteData!.loadComic, isNotNull);
    final page = await source.favoriteData!.loadComic!(1);
    expect(page.success, isTrue);
  });

  group('the required branch mapping declaration (Contract C1/C6)', () {
    Future<ComicSource> parseScanSource(
      String key,
      String branchName,
      String branchBody,
    ) => ComicSourceParser().parse('''
class ScanDeclarationSource extends ComicSource {
  name = "Scan declaration";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  scan = {
    primary: "$branchName",
    $branchName: {$branchBody},
  };
}
''', '$key.js');

    const goodLoad = '''
      load: async (id, request) => ({observation: {update: {latestChapterId: id}}}),
''';

    test('a valid declaration yields a normalized comparable label', () async {
      final source = await parseScanSource('parser_scan_valid', 'comic', '''
      fieldSource: {latestChapterId: "  Last_Chapter.ID  "},
$goodLoad''');
      expect(source.scan!.state, ScanCapabilitiesState.supported);
      // Values are trimmed and lowercased; keys keep their declared spelling
      // because a mis-cased key is rejected rather than corrected (C2/C5).
      expect(
        source.scan!.comic!.evidenceSchema,
        '{"latestChapterId":"last_chapter.id"}',
      );
      expect(
        source.scan!.selectedEvidenceSchema,
        source.scan!.comic!.evidenceSchema,
      );
    });

    test('a granularity marker is carried in the label', () async {
      final source = await parseScanSource(
        'parser_scan_granularity',
        'comic',
        '''
      fieldSource: {updatedAt: "updated_at@day"},
$goodLoad''',
      );
      expect(
        source.scan!.selectedEvidenceSchema,
        '{"updatedAt":"updated_at@day"}',
      );
    });

    test('a missing declaration invalidates the capability', () async {
      final source = await parseScanSource(
        'parser_scan_missing',
        'comic',
        goodLoad,
      );
      expect(source.scan!.state, ScanCapabilitiesState.invalid);
      expect(source.scan!.reason, contains('fieldSource is required'));
      // The source itself still loads, so ordinary features are unaffected.
      expect(source.key, 'parser_scan_missing');
    });

    test('a non-object declaration invalidates the capability', () async {
      for (final declaration in const ['"comic.id"', 'null', '[1]']) {
        final source = await parseScanSource(
          'parser_scan_shape_${declaration.hashCode.abs()}',
          'comic',
          '      fieldSource: $declaration,\n$goodLoad',
        );
        expect(
          source.scan!.state,
          ScanCapabilitiesState.invalid,
          reason: declaration,
        );
      }
    });

    test('an unknown field name invalidates the capability', () async {
      final source = await parseScanSource(
        'parser_scan_unknown_field',
        'comic',
        '''
      fieldSource: {latestChapterID: "comic.id"},
$goodLoad''',
      );
      expect(source.scan!.state, ScanCapabilitiesState.invalid);
    });

    test(
      'a granularity on a non-time field invalidates the capability',
      () async {
        final source = await parseScanSource(
          'parser_scan_bad_granularity',
          'comic',
          '''
      fieldSource: {latestChapterId: "comic.id@day"},
$goodLoad''',
        );
        expect(source.scan!.state, ScanCapabilitiesState.invalid);
      },
    );

    test('an empty declaration invalidates the capability', () async {
      final source = await parseScanSource('parser_scan_empty', 'comic', '''
      fieldSource: {},
$goodLoad''');
      expect(source.scan!.state, ScanCapabilitiesState.invalid);
    });

    test('each branch carries its own label', () async {
      const key = 'parser_scan_two_branches';
      final source = await ComicSourceParser().parse('''
class ScanTwoBranchSource extends ComicSource {
  name = "Scan two branches";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  scan = {
    primary: "comic",
    comic: {
      fieldSource: {updatedAt: "updated_at@instant"},
      load: async (id, request) => ({observation: {update: {latestChapterId: id}}}),
    },
    collection: {
      fieldSource: {latestChapterId: "last_chapter.id"},
      load: async (key, cursor, request) => ({items: [], next: null}),
    },
  };
}
''', '$key.js');

      expect(source.scan!.state, ScanCapabilitiesState.supported);
      expect(
        source.scan!.comic!.evidenceSchema,
        '{"updatedAt":"updated_at@instant"}',
      );
      expect(
        source.scan!.collection!.evidenceSchema,
        '{"latestChapterId":"last_chapter.id"}',
      );
      // Switching `primary` changes the selected label structurally, which is
      // what makes a branch switch rebuild the baseline automatically.
      expect(
        source.scan!.selectedEvidenceSchema,
        source.scan!.comic!.evidenceSchema,
      );
    });
  });
}
