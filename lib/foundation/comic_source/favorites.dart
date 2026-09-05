part of 'comic_source.dart';

typedef AddOrDelFavFunc =
    Future<Res<bool>> Function(
      String comicId,
      String folderId,
      bool isAdding,
      String? favId,
    );

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

  /// Legacy source declaration accepted during migration but never used for
  /// comparison, persistence, or Cloud compatibility.
  @Deprecated('markerScheme is ignored; use UpdateState or opaque marker')
  final String? markerScheme;

  const FavoriteUpdateCheckData({
    required this.scanInterval,
    required this.load,
    this.markerScheme,
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
