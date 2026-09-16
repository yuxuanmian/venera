import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/scan/source_adapter.dart';
import 'package:venera/foundation/semantic_search/request_scope.dart';

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
    expect(source.semanticSearchData, isNull);
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

  group('the optional tagSearch capability contract (T005)', () {
    test(
      'the page form parses into loadPage and leaves loadNext null',
      () async {
        const key = 'parser_tag_page_form';
        final source = await ComicSourceParser().parse('''
class ParserTagPageSource extends ComicSource {
  name = "Parser tag page";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  search = {
    tagSearch: {
      load: async (value, options, page) => ({comics: [], maxPage: 2}),
    },
  };
}
''', '$key.js');

        expect(source.semanticSearchData, isNotNull);
        expect(source.semanticSearchData!.loadPage, isNotNull);
        expect(
          source.semanticSearchData!.loadNext,
          isNull,
          reason: 'only the declared pagination form is exposed',
        );
      },
    );

    test(
      'the cursor form parses into loadNext and leaves loadPage null',
      () async {
        const key = 'parser_tag_cursor_form';
        final source = await ComicSourceParser().parse('''
class ParserTagCursorSource extends ComicSource {
  name = "Parser tag cursor";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  search = {
    tagSearch: {
      loadNext: async (value, options, next) => ({comics: [], next: null}),
    },
  };
}
''', '$key.js');

        expect(source.semanticSearchData, isNotNull);
        expect(source.semanticSearchData!.loadNext, isNotNull);
        expect(
          source.semanticSearchData!.loadPage,
          isNull,
          reason: 'only the declared pagination form is exposed',
        );
      },
    );

    test('load wins when both pagination forms are declared', () async {
      const key = 'parser_tag_load_wins';
      final source = await ComicSourceParser().parse('''
class ParserTagLoadWinsSource extends ComicSource {
  name = "Parser tag load wins";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  search = {
    tagSearch: {
      load: async (value, options, page) => ({
        comics: [new Comic({id: "from-load-" + page, title: "load", cover: "", tags: [], description: ""})],
        maxPage: 3,
      }),
      loadNext: async (value, options, next) => ({
        comics: [new Comic({id: "from-loadNext", title: "next", cover: "", tags: [], description: ""})],
        next: "cursor",
      }),
    },
  };
}
''', '$key.js');

      expect(source.semanticSearchData, isNotNull);
      expect(source.semanticSearchData!.loadPage, isNotNull);
      expect(
        source.semanticSearchData!.loadNext,
        isNull,
        reason:
            'tagSearch.load wins over tagSearch.loadNext, like ordinary search',
      );

      final scope = SemanticSearchRequestScope();
      addTearDown(() => source.semanticSearchData!.releaseLane!(scope));

      // The loader the Host is handed must be the one that is really called.
      final res = await source.semanticSearchData!.loadPage!(
        'value',
        const <String>[],
        1,
        requestScope: scope,
      );
      expect(res.error, isFalse);
      expect(res.data.single.id, 'from-load-1');
      expect(res.subData, 3);
    });

    test(
      'the page adapter passes value, options and page through unchanged',
      () async {
        const key = 'parser_tag_page_args';
        final source = await ComicSourceParser().parse('''
class ParserTagPageArgsSource extends ComicSource {
  name = "Parser tag page args";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  search = {
    tagSearch: {
      load: async (...args) => ({
        comics: [new Comic({
          id: JSON.stringify(args),
          title: "record",
          cover: "",
          tags: [],
          description: "",
        })],
        maxPage: 2,
      }),
    },
  };
}
''', '$key.js');

        final scope = SemanticSearchRequestScope();
        addTearDown(() => source.semanticSearchData!.releaseLane!(scope));

        const value = '  MiXeD Case  ';
        final options = <String>['dd', 'zh'];
        final res = await source.semanticSearchData!.loadPage!(
          value,
          options,
          2,
          requestScope: scope,
        );
        expect(res.error, isFalse);

        final recorded = jsonDecode(res.data.single.id) as List<dynamic>;
        expect(
          recorded.length,
          3,
          reason:
              'the Dart-only requestScope must never appear in the JavaScript '
              'argument list',
        );
        expect(
          recorded[0],
          value,
          reason: 'the opaque value is never trimmed or re-cased',
        );
        expect(
          recorded[1],
          isA<List<dynamic>>(),
          reason: 'options must arrive as a JS array',
        );
        expect(recorded[1], options);
        expect(recorded[2], 2);
      },
    );

    test(
      'the cursor adapter passes value, options and next through unchanged',
      () async {
        const key = 'parser_tag_cursor_args';
        final source = await ComicSourceParser().parse('''
class ParserTagCursorArgsSource extends ComicSource {
  name = "Parser tag cursor args";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  search = {
    tagSearch: {
      loadNext: async (...args) => ({
        comics: [new Comic({
          id: JSON.stringify(args),
          title: "record",
          cover: "",
          tags: [],
          description: "",
        })],
        next: "cursor-1",
      }),
    },
  };
}
''', '$key.js');

        final scope = SemanticSearchRequestScope();
        addTearDown(() => source.semanticSearchData!.releaseLane!(scope));

        const value = '  MiXeD Case  ';
        final options = <String>['dd', 'zh'];
        final res = await source.semanticSearchData!.loadNext!(
          value,
          options,
          null,
          requestScope: scope,
        );
        expect(res.error, isFalse);

        final recorded = jsonDecode(res.data.single.id) as List<dynamic>;
        expect(
          recorded.length,
          3,
          reason:
              'the Dart-only requestScope must never appear in the JavaScript '
              'argument list',
        );
        expect(recorded[0], value);
        expect(recorded[1], isA<List<dynamic>>());
        expect(recorded[1], options);
        expect(
          recorded[2],
          isNull,
          reason: 'the initial cursor form invocation passes an explicit null',
        );
        expect(res.subData, 'cursor-1');
      },
    );

    test('the page form preserves comics and maxPage', () async {
      const key = 'parser_tag_page_results';
      final source = await ComicSourceParser().parse('''
class ParserTagPageResultsSource extends ComicSource {
  name = "Parser tag page results";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  search = {
    tagSearch: {
      load: async (value, options, page) => ({
        comics: [new Comic({
          id: "comic-1",
          title: "Title 1",
          subtitle: "Subtitle 1",
          cover: "cover-1",
          tags: ["tag-1", "tag-2"],
          description: "Description 1",
        })],
        maxPage: 7,
      }),
    },
  };
}
''', '$key.js');

      final scope = SemanticSearchRequestScope();
      addTearDown(() => source.semanticSearchData!.releaseLane!(scope));

      final res = await source.semanticSearchData!.loadPage!(
        'v',
        const <String>[],
        1,
        requestScope: scope,
      );
      expect(res.error, isFalse);
      final comic = res.data.single;
      expect(comic.id, 'comic-1');
      expect(comic.title, 'Title 1');
      expect(comic.subtitle, 'Subtitle 1');
      expect(comic.cover, 'cover-1');
      expect(comic.tags, ['tag-1', 'tag-2']);
      expect(comic.description, 'Description 1');
      expect(comic.sourceKey, key);
      expect(
        res.subData,
        7,
        reason: 'Res.subData carries the source maxPage unchanged',
      );
    });

    test('the cursor form preserves comics and next', () async {
      const key = 'parser_tag_cursor_results';
      final source = await ComicSourceParser().parse('''
class ParserTagCursorResultsSource extends ComicSource {
  name = "Parser tag cursor results";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  search = {
    tagSearch: {
      loadNext: async (value, options, next) => ({
        comics: [new Comic({id: "comic-2", title: "Title 2", cover: "c2", tags: [], description: ""})],
        next: "opaque-next",
      }),
    },
  };
}
''', '$key.js');

      final scope = SemanticSearchRequestScope();
      addTearDown(() => source.semanticSearchData!.releaseLane!(scope));

      final res = await source.semanticSearchData!.loadNext!(
        'v',
        const <String>[],
        null,
        requestScope: scope,
      );
      expect(res.error, isFalse);
      final comic = res.data.single;
      expect(comic.id, 'comic-2');
      expect(comic.title, 'Title 2');
      expect(comic.sourceKey, key);
      expect(
        res.subData,
        'opaque-next',
        reason: 'Res.subData carries the source cursor unchanged',
      );
    });
  });

  group(
    'an invalid optional capability cannot break ordinary search (T049)',
    () {
      /// Every case in this group must keep the ordinary loader working; the
      /// assertions below therefore call it for real instead of only inspecting
      /// the parsed shape.
      Future<void> expectOrdinaryLoaderWorks(
        ComicSource source,
        String reason,
      ) async {
        expect(source.searchPageData, isNotNull, reason: reason);
        final res = await source.searchPageData!.loadPage!(
          'keyword',
          1,
          const <String>[],
        );
        expect(res.error, isFalse, reason: reason);
        expect(res.data.single.id, 'ordinary-ok', reason: reason);
      }

      /// The optional capability is absent, and ordinary search is untouched.
      Future<void> expectAbsentCapability(
        ComicSource source,
        String reason,
      ) async {
        expect(source.semanticSearchData, isNull, reason: reason);
        await expectOrdinaryLoaderWorks(source, reason);
      }

      String ordinarySearchSource(String key, String tagSearchDeclaration) =>
          '''
class ParserTagCompatibilitySource extends ComicSource {
  name = "Parser tag compatibility";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  search = {
    load: async (keyword, options, page) => ({
      comics: [new Comic({id: "ordinary-ok", title: "ordinary", cover: "", tags: [], description: ""})],
      maxPage: 1,
    }),
$tagSearchDeclaration
  };
}
''';

      test(
        'an ordinary-only search leaves the semantic capability absent',
        () async {
          const key = 'parser_tag_ordinary_only';
          final source = await ComicSourceParser().parse(
            ordinarySearchSource(key, ''),
            '$key.js',
          );

          expect(source.semanticSearchData, isNull);
          await expectAbsentCapability(source, 'ordinary-only search');
        },
      );

      test('a tagSearch without a function loader is ignored', () async {
        const key = 'parser_tag_no_function_loader';
        final source = await ComicSourceParser().parse(
          ordinarySearchSource(key, '''
    tagSearch: {
      load: "not a function",
      loadNext: 5,
    },'''),
          '$key.js',
        );

        await expectAbsentCapability(source, 'non-function loaders');
      });

      test('a non-object tagSearch is ignored', () async {
        for (final declaration in const [
          '"tagSearch"',
          '[1, 2]',
          '42',
          'null',
        ]) {
          final key = 'parser_tag_shape_${declaration.hashCode.abs()}';
          final source = await ComicSourceParser().parse(
            ordinarySearchSource(key, '    tagSearch: $declaration,'),
            '$key.js',
          );

          await expectAbsentCapability(source, declaration);
        }
      });

      test(
        'a tagSearch loader that throws degrades to an adapter error',
        () async {
          const key = 'parser_tag_loader_throws';
          final source = await ComicSourceParser().parse('''
class ParserTagThrowsSource extends ComicSource {
  name = "Parser tag throws";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  search = {
    load: async (keyword, options, page) => ({
      comics: [new Comic({id: "ordinary-ok", title: "ordinary", cover: "", tags: [], description: ""})],
      maxPage: 1,
    }),
    tagSearch: {
      load: async (value, options, page) => { throw new Error("semantic loader exploded"); },
    },
  };
}
''', '$key.js');

          // The capability still parses; only its invocation fails.
          expect(source.semanticSearchData, isNotNull);
          expect(source.semanticSearchData!.loadPage, isNotNull);

          final scope = SemanticSearchRequestScope();
          addTearDown(() => source.semanticSearchData!.releaseLane!(scope));
          final semantic = await source.semanticSearchData!.loadPage!(
            'v',
            const <String>[],
            1,
            requestScope: scope,
          );
          expect(semantic.error, isTrue);
          expect(semantic.dataOrNull, isNull);
          expect(semantic.errorMessage, isNotNull);

          await expectOrdinaryLoaderWorks(source, 'throwing semantic loader');
        },
      );
    },
  );

  group('tagSearch navigation targets (T024)', () {
    const key = 'parser_tag_target_source';

    test('legacy and modern shapes both keep the opaque keyword', () {
      final legacy = PageJumpTarget.parse(key, {
        'action': 'tagSearch',
        'keyword': '  A B  ',
      });
      expect(legacy.page, 'tagSearch');
      expect(legacy.tagSearchValue, '  A B  ');
      expect(legacy.sourceKey, key);

      final modern = PageJumpTarget.parse(key, {
        'page': 'tagSearch',
        'attributes': {'keyword': '  A B  '},
      });
      expect(modern.page, 'tagSearch');
      expect(modern.tagSearchValue, '  A B  ');
      expect(modern.sourceKey, key);
    });

    test('an unknown action still parses without guessing', () {
      final unknown = PageJumpTarget.parse(key, {'action': 'mystery'});
      expect(unknown.page, 'mystery');
      expect(unknown.sourceKey, key);
      expect(unknown.attributes, isNull);
    });

    test('ordinary search and category parsing is unchanged', () {
      final legacySearch = PageJumpTarget.parse(key, {
        'action': 'search',
        'keyword': 'keyword',
      });
      expect(legacySearch.page, 'search');
      expect(legacySearch.sourceKey, key);
      expect(legacySearch.attributes, {'text': 'keyword'});

      final legacyCategory = PageJumpTarget.parse(key, {
        'action': 'category',
        'keyword': 'category',
        'param': 'param',
      });
      expect(legacyCategory.page, 'category');
      expect(legacyCategory.attributes, {
        'category': 'category',
        'param': 'param',
      });

      final modernSearch = PageJumpTarget.parse(key, {
        'page': 'search',
        'attributes': {'text': 'keyword'},
      });
      expect(modernSearch.page, 'search');
      expect(modernSearch.attributes, {'text': 'keyword'});

      final stringSearch = PageJumpTarget.parse(key, 'search:keyword');
      expect(stringSearch.page, 'search');
      expect(stringSearch.attributes, {'text': 'keyword'});

      final stringCategory = PageJumpTarget.parse(key, 'category:name@param');
      expect(stringCategory.page, 'category');
      expect(stringCategory.attributes, {'category': 'name', 'param': 'param'});
    });

    test('a top-level keyword is accepted as a shorthand for attributes', () {
      const key = 'parser_tag_shorthand';
      // Canonical form.
      final canonical = PageJumpTarget.parse(key, {
        'page': 'tagSearch',
        'attributes': {'keyword': '  A B  '},
      });
      expect(canonical.page, 'tagSearch');
      expect(canonical.sourceKey, key);
      expect(canonical.tagSearchValue, '  A B  ');

      // Shorthand: the keyword sits next to `page` instead of inside
      // `attributes`. It must not silently become an empty opaque value.
      final shorthand = PageJumpTarget.parse(key, {
        'page': 'tagSearch',
        'keyword': '  A B  ',
      });
      expect(shorthand.page, 'tagSearch');
      expect(shorthand.sourceKey, key);
      expect(shorthand.tagSearchValue, '  A B  ');

      // `attributes` stays authoritative when both are present.
      final both = PageJumpTarget.parse(key, {
        'page': 'tagSearch',
        'keyword': 'top-level',
        'attributes': {'keyword': 'nested'},
      });
      expect(both.tagSearchValue, 'nested');

      // The same shorthand works for ordinary search.
      final search = PageJumpTarget.parse(key, {
        'page': 'search',
        'keyword': 'plain',
      });
      expect(search.page, 'search');
      expect(search.attributes?['keyword'], 'plain');
    });
  });
}
