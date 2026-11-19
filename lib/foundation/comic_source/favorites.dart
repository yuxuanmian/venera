part of 'comic_source.dart';

typedef AddOrDelFavFunc =
    Future<Res<bool>> Function(
      String comicId,
      String folderId,
      bool isAdding,
      String? favId,
    );

typedef FavoriteCachePageLoader =
    Future<Res<FavoriteCachePage>> Function(
      int page,
      String folder,
      int? total,
    );

class FavoriteCachePage {
  const FavoriteCachePage(this.comics, this.maxPage, this.total, {this.next});

  final List<Comic> comics;
  final int? maxPage;
  final int? total;
  final String? next;
}

typedef FavoriteCacheCursorLoader =
    Future<Res<FavoriteCachePage>> Function(String? next, String folder);

class FavoriteUpdateSnapshot {
  final List<Comic> comics;
  final int pageSize;
  final int total;

  const FavoriteUpdateSnapshot({
    required this.comics,
    required this.pageSize,
    required this.total,
  });
}

class FavoriteUpdateCheckData {
  final Duration scanInterval;
  final Future<Res<FavoriteUpdateSnapshot>> Function([String? folderId]) load;

  const FavoriteUpdateCheckData({
    required this.scanInterval,
    required this.load,
  });
}

class FavoriteData {
  final String key;

  final String title;

  final bool multiFolder;

  final Future<Res<List<Comic>>> Function(int page, [String? folder])?
  loadComic;

  final Future<Res<List<Comic>>> Function(String? next, [String? folder])?
  loadNext;

  /// key-id, value-name
  ///
  /// if comicId is not null, Res.subData is the folders that the comic is in
  final Future<Res<Map<String, String>>> Function([String? comicId])?
  loadFolders;

  /// A value of null disables this feature
  final Future<Res<bool>> Function(String key)? deleteFolder;

  /// A value of null disables this feature
  final Future<Res<bool>> Function(String name)? addFolder;

  /// A value of null disables this feature
  final AddOrDelFavFunc? addOrDelFavorite;

  final bool singleFolderForSingleComic;

  final FavoriteUpdateCheckData? updateCheck;
  final FavoriteCachePageLoader? loadCachePage;
  final FavoriteCacheCursorLoader? loadCacheNext;
  final List<String> cacheSettings;
  final String? cacheAllFolder;
  final String? cacheAccountSetting;

  bool get usesCollectionCache =>
      loadCachePage != null || loadCacheNext != null;

  String get cacheScope {
    if (cacheSettings.isEmpty) return '';
    final source = ComicSource.find(key);
    final settings = source?.data['settings'];
    final values = jsonEncode([
      for (final name in cacheSettings)
        (settings is Map ? settings[name] : null) ??
            source?.settings?[name]?['default'],
    ]);
    return sha256.convert(utf8.encode(values)).toString();
  }

  const FavoriteData({
    required this.key,
    required this.title,
    required this.multiFolder,
    required this.loadComic,
    required this.loadNext,
    this.loadFolders,
    this.deleteFolder,
    this.addFolder,
    this.addOrDelFavorite,
    this.singleFolderForSingleComic = false,
    this.updateCheck,
    this.loadCachePage,
    this.loadCacheNext,
    this.cacheSettings = const [],
    this.cacheAllFolder,
    this.cacheAccountSetting,
  });
}

FavoriteData getFavoriteData(String key) {
  var source = ComicSource.find(key) ?? (throw "Unknown source key: $key");
  return source.favoriteData!;
}

FavoriteData? getFavoriteDataOrNull(String key) {
  var source = ComicSource.find(key);
  return source?.favoriteData;
}
