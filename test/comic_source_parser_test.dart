import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';

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

  test('parses the optional favorite list update capability', () async {
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
  };
}
''', '$key.js');

    final updateCheck = source.favoriteData!.updateCheck;
    expect(updateCheck, isNotNull);
    expect(updateCheck!.markerScheme, 'test-list-v1');
    expect(updateCheck.scanInterval, const Duration(hours: 1));
    final result = await updateCheck.load(null);
    expect(result.success, isTrue);
    expect(result.data.comics.single.favoriteUpdate!.marker, 'marker-1');
    expect(result.data.comics.single.favoriteUpdate!.metadata, {
      'fullIsNew': true,
    });
  });

  test(
    'accepts a nullable list update time but validates non-null times',
    () async {
      const key = 'parser_nullable_favorite_update_case';
      final source = await ComicSourceParser().parse('''
class ParserNullableFavoriteUpdateSource extends ComicSource {
  name = "Parser nullable favorite update";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  favorites = {
    multiFolder: false,
    updateCheck: {
      markerScheme: "chapter-id-v1",
      scanInterval: 43200,
      load: async (folderId) => ({
        comics: [new Comic({
          id: "comic-1",
          title: "Comic 1",
          cover: "cover",
          tags: [],
          description: "",
          favoriteUpdate: {
            marker: "normal:chapter-1|full:",
            updateTime: null,
            isNew: true,
            metadata: {fullIsNew: false},
          },
        })],
        pageSize: 15,
        total: 1,
      }),
    },
  };
}
''', '$key.js');

      final result = await source.favoriteData!.updateCheck!.load(null);
      expect(result.success, isTrue);
      expect(result.data.comics.single.favoriteUpdate!.updateTime, isNull);

      const invalidKey = 'parser_invalid_favorite_time_case';
      final invalidSource = await ComicSourceParser().parse('''
class ParserInvalidFavoriteTimeSource extends ComicSource {
  name = "Parser invalid favorite time";
  key = "$invalidKey";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  favorites = {
    multiFolder: false,
    updateCheck: {
      markerScheme: "chapter-id-v1",
      scanInterval: 43200,
      load: async (folderId) => ({
        comics: [new Comic({
          id: "comic-1",
          title: "Comic 1",
          cover: "cover",
          tags: [],
          description: "",
          favoriteUpdate: {
            marker: "marker-1",
            updateTime: "not-a-date",
          },
        })],
        pageSize: 15,
        total: 1,
      }),
    },
  };
}
''', '$invalidKey.js');
      final invalidResult = await invalidSource.favoriteData!.updateCheck!.load(
        null,
      );
      expect(invalidResult.success, isFalse);
      expect(invalidResult.errorMessage, contains('full update evidence'));
    },
  );
}
