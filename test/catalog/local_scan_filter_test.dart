import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/res.dart';

const _sourceKey = 'catalog_filter_test';

ComicSource _source(FavoriteData data) => ComicSource(
  'Catalog filter test',
  _sourceKey,
  null,
  null,
  null,
  data,
  const [],
  null,
  null,
  (id) async => Res(
    ComicDetails.fromJson({
      'title': 'Comic $id',
      'subtitle': 'Author',
      'cover': '',
      'tags': <String, List<String>>{},
      'chapters': <String, String>{},
      'sourceKey': _sourceKey,
      'comicId': id,
    }),
  ),
  null,
  null,
  null,
  null,
  '',
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

void main() {
  late Directory directory;
  late NetworkFavoriteCacheManager cache;
  late Object? previousEnabled;
  late Object? previousFavorites;

  setUp(() async {
    previousEnabled = appdata.settings['enabledSources'];
    previousFavorites = appdata.settings['favorites'];
    appdata.settings['enabledSources'] = <String>[_sourceKey];
    appdata.settings['favorites'] = <String>[_sourceKey];
    directory = await Directory.systemTemp.createTemp('venera-catalog-filter-');
    cache = NetworkFavoriteCacheManager();
    await cache.init(
      databasePath: '${directory.path}${Platform.pathSeparator}cache.db',
      migrateLegacy: false,
    );
  });

  tearDown(() async {
    ComicSourceManager().remove(_sourceKey);
    appdata.settings['enabledSources'] = previousEnabled;
    appdata.settings['favorites'] = previousFavorites;
    cache.close();
    await directory.delete(recursive: true);
  });

  test(
    'follow-update folder filtering still respects source visibility',
    () async {
      final comic = Comic(
        'Comic one',
        '',
        'one',
        'Author',
        const [],
        '',
        _sourceKey,
        null,
        null,
      );
      final data = FavoriteData(
        key: _sourceKey,
        title: 'Catalog filter test',
        multiFolder: true,
        loadComic: (page, [_]) async => Res([comic], subData: 1),
        loadNext: null,
        loadFolders: ([_]) async => const Res({'remote': 'Remote'}),
      );
      final source = _source(data)..data['account'] = <String, dynamic>{};
      ComicSourceManager().add(source);
      await cache.refreshFolders(data);
      await cache.refreshPage(
        data,
        const NetworkFavoriteFolderRef(
          sourceKey: _sourceKey,
          folderId: 'remote',
        ),
        1,
      );

      expect(getFollowUpdateFolders(), hasLength(1));
      appdata.settings['enabledSources'] = <String>[];
      expect(getFollowUpdateFolders(), isEmpty);
    },
  );
}
