import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/io.dart';

import 'app.dart';

String _formatFavoriteTime(DateTime time) =>
    time.toIso8601String().replaceFirst('T', ' ').substring(0, 19);

/// A cached copy of a comic in a source-owned favorite folder.
///
/// This is deliberately only a presentation/cache model. Adding and removing
/// favorites always goes through [FavoriteData] and is never written as a
/// local-only favorite.
class FavoriteItem implements Comic {
  FavoriteItem({
    required this.id,
    required this.name,
    required this.coverPath,
    required this.author,
    required this.sourceKeyValue,
    required this.tags,
    this.chapterCount,
    this.remoteFavoriteId,
    DateTime? favoriteTime,
  }) : time = _formatFavoriteTime(favoriteTime ?? DateTime.now());

  FavoriteItem.fromComic(Comic comic)
    : id = comic.id,
      name = comic.title,
      coverPath = comic.cover,
      author = comic.subtitle ?? '',
      sourceKeyValue = comic.sourceKey,
      tags = List<String>.from(comic.tags ?? const []),
      chapterCount = comic is FavoriteItem ? comic.chapterCount : null,
      remoteFavoriteId = comic.favoriteId,
      time = _formatFavoriteTime(DateTime.now());

  FavoriteItem.fromRow(Row row)
    : id = row['comic_id'] as String,
      sourceKeyValue = row['source_key'] as String,
      time =
          row['favorite_time'] as String? ??
          _formatFavoriteTime(DateTime.now()),
      remoteFavoriteId = row['favorite_id'] as String?,
      name = _readComicJson(row)['title'] as String? ?? '',
      coverPath = _readComicJson(row)['cover'] as String? ?? '',
      author =
          (_readComicJson(row)['subTitle'] ??
                  _readComicJson(row)['subtitle'] ??
                  '')
              .toString(),
      chapterCount = (_readComicJson(row)['chapterCount'] as num?)?.toInt(),
      tags = List<String>.from(_readComicJson(row)['tags'] ?? const []);

  static Map<String, dynamic> _readComicJson(Row row) {
    final value = row['comic_json'];
    if (value is! String || value.isEmpty) return const {};
    return Map<String, dynamic>.from(jsonDecode(value) as Map);
  }

  @override
  final String id;
  final String name;
  final String author;
  final String sourceKeyValue;
  @override
  final List<String> tags;
  final int? chapterCount;
  final String coverPath;
  final String? remoteFavoriteId;
  final String time;

  ComicType get type => ComicType(sourceKeyValue.hashCode);

  @override
  String get cover => coverPath;

  @override
  String get description => '$sourceKeyValue | ${time.substring(0, 10)}';

  @override
  String? get favoriteId => remoteFavoriteId;

  @override
  String? get language => null;

  @override
  int? get maxPage => null;

  @override
  String get sourceKey => sourceKeyValue;

  @override
  double? get stars => null;

  @override
  String? get subtitle => author;

  @override
  String get title => name;

  @override
  Map<String, dynamic> toJson() => {
    'title': name,
    'cover': coverPath,
    'id': id,
    'subTitle': author,
    if (chapterCount != null) 'chapterCount': chapterCount,
    'tags': tags,
    'description': '',
    'sourceKey': sourceKeyValue,
    'favoriteId': remoteFavoriteId,
  };

  Map<String, dynamic> toCacheJson() => toJson();

  @override
  bool operator ==(Object other) =>
      other is Comic && other.id == id && other.sourceKey == sourceKey;

  @override
  int get hashCode => id.hashCode ^ sourceKey.hashCode;
}

class FavoriteItemWithUpdateInfo extends FavoriteItem {
  FavoriteItemWithUpdateInfo(
    FavoriteItem item,
    this.updateTime,
    this.updateMarker,
    this.hasNewUpdate,
    int? lastCheckTime,
    int? retryAfter, {
    this.checkFailures = 0,
    this.checkNotFoundCount = 0,
    this.isSuspectGone = false,
  }) : lastCheckTime = lastCheckTime == null
           ? null
           : DateTime.fromMillisecondsSinceEpoch(lastCheckTime),
       retryAfter = retryAfter == null
           ? null
           : DateTime.fromMillisecondsSinceEpoch(retryAfter),
       super(
         id: item.id,
         name: item.name,
         coverPath: item.coverPath,
         author: item.author,
         sourceKeyValue: item.sourceKey,
         tags: item.tags,
         chapterCount: item.chapterCount,
         remoteFavoriteId: item.favoriteId,
       );

  final String? updateTime;
  final String? updateMarker;
  final DateTime? lastCheckTime;
  final DateTime? retryAfter;
  final bool hasNewUpdate;
  final int checkFailures;
  final int checkNotFoundCount;
  final bool isSuspectGone;

  @override
  String get description => '${updateTime ?? 'Unknown'} | $sourceKey';
}

class NetworkFavoriteFolderRef {
  const NetworkFavoriteFolderRef({
    required this.sourceKey,
    required this.folderId,
    this.title,
  });

  final String sourceKey;
  final String folderId;
  final String? title;

  factory NetworkFavoriteFolderRef.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('Invalid favorite folder');
    final sourceKey = json['sourceKey'];
    final folderId = json['folderId'];
    if (sourceKey is! String || folderId is! String) {
      throw const FormatException('Invalid favorite folder');
    }
    return NetworkFavoriteFolderRef(
      sourceKey: sourceKey,
      folderId: folderId,
      title: json['title'] as String?,
    );
  }

  /// Reads the persisted follow-updates setting without letting a malformed
  /// value break startup.  The setting used to be a local folder name, so old
  /// string values intentionally resolve to null.
  static NetworkFavoriteFolderRef? tryFromJson(Object? json) {
    try {
      return NetworkFavoriteFolderRef.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
    'sourceKey': sourceKey,
    'folderId': folderId,
    if (title != null) 'title': title,
  };

  @override
  bool operator ==(Object other) =>
      other is NetworkFavoriteFolderRef &&
      other.sourceKey == sourceKey &&
      other.folderId == folderId;

  @override
  int get hashCode => sourceKey.hashCode ^ folderId.hashCode;
}

class NetworkFavoriteFolder extends NetworkFavoriteFolderRef {
  const NetworkFavoriteFolder({
    required super.sourceKey,
    required super.folderId,
    required String super.title,
    required this.updatedAt,
  });

  final DateTime updatedAt;
}

/// Reads the only legacy relation that remains meaningful after local
/// favorites are removed: a selected follow-updates folder linked to a remote
/// source folder. It deliberately does not inspect or import any comics.
NetworkFavoriteFolderRef? readLegacyFollowUpdatesFolder(
  File legacyDatabase,
  Object? oldFollowFolder,
) {
  if (oldFollowFolder is! String || !legacyDatabase.existsSync()) return null;
  Database? database;
  try {
    database = sqlite3.open(legacyDatabase.path);
    final tables = database
        .select("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row['name'])
        .toSet();
    if (!tables.contains('folder_sync')) return null;
    final rows = database.select(
      'SELECT source_key, source_folder FROM folder_sync WHERE folder_name = ?',
      [oldFollowFolder],
    );
    if (rows.isEmpty) return null;
    return NetworkFavoriteFolderRef(
      sourceKey: rows.first['source_key'] as String,
      folderId: rows.first['source_folder'] as String,
    );
  } catch (_) {
    // A corrupt legacy database must not prevent application startup.
    return null;
  } finally {
    database?.dispose();
  }
}

class CachedFavoritePage {
  const CachedFavoritePage({
    required this.comics,
    required this.pageIndex,
    required this.updatedAt,
    this.maxPage,
    this.nextToken,
  });

  final List<FavoriteItem> comics;
  final int pageIndex;
  final DateTime updatedAt;
  final int? maxPage;
  final String? nextToken;
}

/// The last successful explicit full-cache operation for one remote folder.
class FavoriteFullCacheStatus {
  const FavoriteFullCacheStatus({
    this.completedAt,
    this.pageCount = 0,
    this.comicCount = 0,
  });

  final DateTime? completedAt;
  final int pageCount;
  final int comicCount;

  bool get isComplete => completedAt != null;
}

/// Progress emitted while an explicit full-cache operation is running.
///
/// Cursor-based sources do not expose a total page count, so [totalPages] is
/// null and the UI should show an indeterminate progress indicator.
class FavoriteFullCacheProgress {
  const FavoriteFullCacheProgress({
    required this.pagesCached,
    required this.comicsCached,
    this.totalPages,
    this.errorMessage,
    this.isComplete = false,
    this.isCanceled = false,
  });

  final int pagesCached;
  final int comicsCached;
  final int? totalPages;
  final String? errorMessage;
  final bool isComplete;
  final bool isCanceled;
}

/// Device-local cache for remote favorite folders.
class NetworkFavoriteCacheManager with ChangeNotifier {
  NetworkFavoriteCacheManager._create();

  /// Creates an isolated manager for SQLite regression tests.
  NetworkFavoriteCacheManager.forTesting();

  static NetworkFavoriteCacheManager? _instance;

  factory NetworkFavoriteCacheManager() =>
      _instance ??= NetworkFavoriteCacheManager._create();

  late Database _db;
  final Set<String> _refreshing = {};
  final Set<String> _fullCaching = {};
  static const _backgroundRefreshAfter = Duration(seconds: 30);
  static const backgroundSummaryRefreshAfter = Duration(hours: 6);

  Future<void> init({String? databasePath, bool migrateLegacy = true}) async {
    _db = sqlite3.open(
      databasePath ?? FilePath.join(App.dataPath, 'network_favorite_cache.db'),
    );
    _db.execute('''
      CREATE TABLE IF NOT EXISTS metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS favorite_folders (
        source_key TEXT NOT NULL,
        folder_id TEXT NOT NULL,
        title TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        full_cache_at INTEGER,
        full_cache_pages INTEGER NOT NULL DEFAULT 0,
        full_cache_comics INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (source_key, folder_id)
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS favorite_pages (
        source_key TEXT NOT NULL,
        folder_id TEXT NOT NULL,
        page_index INTEGER NOT NULL,
        request_token TEXT NOT NULL,
        next_token TEXT,
        max_page INTEGER,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (source_key, folder_id, request_token)
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS favorite_items (
        source_key TEXT NOT NULL,
        folder_id TEXT NOT NULL,
        page_index INTEGER NOT NULL,
        comic_id TEXT NOT NULL,
        display_order INTEGER NOT NULL,
        comic_json TEXT NOT NULL,
        favorite_id TEXT,
        favorite_time TEXT NOT NULL,
        search_text TEXT NOT NULL DEFAULT '',
        last_update_time TEXT,
        last_check_time INTEGER,
        has_new_update INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (source_key, folder_id, page_index, comic_id)
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS favorite_membership (
        source_key TEXT NOT NULL,
        folder_id TEXT NOT NULL,
        comic_id TEXT NOT NULL,
        PRIMARY KEY (source_key, folder_id, comic_id)
      );
    ''');
    final folderColumns = _db
        .select('PRAGMA table_info(favorite_folders)')
        .map((row) => row['name'] as String)
        .toSet();
    if (!folderColumns.contains('full_cache_at')) {
      _db.execute(
        'ALTER TABLE favorite_folders ADD COLUMN full_cache_at INTEGER',
      );
    }
    if (!folderColumns.contains('full_cache_pages')) {
      _db.execute(
        'ALTER TABLE favorite_folders ADD COLUMN full_cache_pages INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!folderColumns.contains('full_cache_comics')) {
      _db.execute(
        'ALTER TABLE favorite_folders ADD COLUMN full_cache_comics INTEGER NOT NULL DEFAULT 0',
      );
    }
    final itemColumns = _db
        .select('PRAGMA table_info(favorite_items)')
        .map((row) => row['name'] as String)
        .toSet();
    if (!itemColumns.contains('update_marker')) {
      _db.execute('ALTER TABLE favorite_items ADD COLUMN update_marker TEXT');
    }
    if (!itemColumns.contains('search_text')) {
      _db.execute(
        "ALTER TABLE favorite_items ADD COLUMN search_text TEXT NOT NULL DEFAULT ''",
      );
    }
    if (!itemColumns.contains('retry_after')) {
      _db.execute('ALTER TABLE favorite_items ADD COLUMN retry_after INTEGER');
    }
    if (!itemColumns.contains('check_failures')) {
      _db.execute(
        'ALTER TABLE favorite_items ADD COLUMN check_failures INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!itemColumns.contains('check_not_found_count')) {
      _db.execute(
        'ALTER TABLE favorite_items ADD COLUMN check_not_found_count INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!itemColumns.contains('check_suspect_gone')) {
      _db.execute(
        'ALTER TABLE favorite_items ADD COLUMN check_suspect_gone INTEGER NOT NULL DEFAULT 0',
      );
    }
    _db.execute('''CREATE INDEX IF NOT EXISTS favorite_items_search
         ON favorite_items (source_key, folder_id, search_text)''');
    _rebuildMissingSearchText();
    if (migrateLegacy) {
      await appdata.ensureInit();
      await _migrateLegacyLocalFavorites();
    }
  }

  Future<void> _migrateLegacyLocalFavorites() async {
    final migrated = _db.select(
      'SELECT value FROM metadata WHERE key = ?',
      const ['legacy_local_favorites_removed'],
    );
    if (migrated.isNotEmpty) return;

    final oldFile = File(FilePath.join(App.dataPath, 'local_favorite.db'));
    final oldFollowFolder = appdata.settings['followUpdatesFolder'];
    final migratedFollowFolder = readLegacyFollowUpdatesFolder(
      oldFile,
      oldFollowFolder,
    );

    if (migratedFollowFolder != null) {
      appdata.settings['followUpdatesFolder'] = migratedFollowFolder.toJson();
    } else if (oldFollowFolder is String) {
      appdata.settings['followUpdatesFolder'] = null;
    }
    appdata.settings['quickFavorite'] = null;
    appdata.settings['newFavoriteAddTo'] = null;
    appdata.settings['moveFavoriteAfterRead'] = null;
    appdata.settings['localFavoritesFirst'] = null;
    appdata.settings['showFavoriteStatusOnTile'] = null;
    appdata.settings['onClickFavorite'] = null;

    try {
      await appdata.saveData();
    } catch (e, s) {
      Log.error(
        'Favorite migration',
        'Failed to save appdata after removing local favorite settings: $e',
        s,
      );
      return;
    }
    try {
      if (oldFile.existsSync()) {
        oldFile.deleteSync();
      }
      final oldCovers = Directory(
        FilePath.join(App.dataPath, 'favorite_cover'),
      );
      if (oldCovers.existsSync()) {
        oldCovers.deleteSync(recursive: true);
      }
    } catch (e, s) {
      Log.error(
        'Favorite migration',
        'Failed to clean legacy local favorite files: $e',
        s,
      );
    }
    try {
      _db.execute(
        'INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)',
        const ['legacy_local_favorites_removed', '1'],
      );
    } catch (e, s) {
      Log.error(
        'Favorite migration',
        'Failed to record legacy local favorite migration: $e',
        s,
      );
    }
  }

  void close() {
    _db.dispose();
  }

  /// Clears every device-local favorite cache entry.
  ///
  /// Remote favorites and source accounts are not touched.
  void clearAllCache() {
    _db.execute('BEGIN');
    try {
      _db.execute('DELETE FROM favorite_items');
      _db.execute('DELETE FROM favorite_pages');
      _db.execute('DELETE FROM favorite_folders');
      _db.execute('DELETE FROM favorite_membership');
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    _refreshing.clear();
    _fullCaching.clear();
    notifyListeners();
  }

  void _rebuildMissingSearchText() {
    final rows = _db.select(
      "SELECT rowid, comic_id, comic_json FROM favorite_items "
      "WHERE search_text IS NULL OR search_text = ''",
    );
    if (rows.isEmpty) return;
    _db.execute('BEGIN');
    try {
      for (final row in rows) {
        _db.execute(
          'UPDATE favorite_items SET search_text = ? WHERE rowid = ?',
          [
            _buildSearchText(
              row['comic_id'] as String,
              FavoriteItem._readComicJson(row),
            ),
            row['rowid'],
          ],
        );
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  List<NetworkFavoriteFolder> getCachedFolders(String sourceKey) {
    return _db
        .select(
          'SELECT * FROM favorite_folders WHERE source_key = ? ORDER BY title',
          [sourceKey],
        )
        .map(
          (row) => NetworkFavoriteFolder(
            sourceKey: row['source_key'] as String,
            folderId: row['folder_id'] as String,
            title: row['title'] as String,
            updatedAt: DateTime.fromMillisecondsSinceEpoch(
              row['updated_at'] as int,
            ),
          ),
        )
        .toList();
  }

  List<NetworkFavoriteFolder> getAllCachedFolders() => _db
      .select('SELECT * FROM favorite_folders ORDER BY source_key, title')
      .map(
        (row) => NetworkFavoriteFolder(
          sourceKey: row['source_key'] as String,
          folderId: row['folder_id'] as String,
          title: row['title'] as String,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(
            row['updated_at'] as int,
          ),
        ),
      )
      .toList();

  Set<String> getKnownFolderIds(String sourceKey, String comicId) => _db
      .select(
        '''SELECT folder_id FROM favorite_membership
           WHERE source_key = ? AND comic_id = ?''',
        [sourceKey, comicId],
      )
      .map((row) => row['folder_id'] as String)
      .toSet();

  /// Stores folder labels learned from a successful comic-detail query.  Such
  /// a query may only concern one comic, so it must not remove other cached
  /// folders that were obtained from the normal folder-list endpoint.
  void cacheFolderSnapshot(String sourceKey, Map<String, String> folders) {
    _upsertFolders(
      sourceKey,
      folders.entries
          .map(
            (entry) => NetworkFavoriteFolder(
              sourceKey: sourceKey,
              folderId: entry.key,
              title: entry.value,
              updatedAt: DateTime.now(),
            ),
          )
          .toList(),
      removeMissing: false,
    );
  }

  /// A successful remote detail lookup is authoritative for this comic's
  /// folder memberships, unlike a partial paged folder cache.
  void replaceComicMembership(
    String sourceKey,
    String comicId,
    Iterable<String> folderIds,
  ) {
    _db.execute('BEGIN');
    try {
      _db.execute(
        '''DELETE FROM favorite_membership
           WHERE source_key = ? AND comic_id = ?''',
        [sourceKey, comicId],
      );
      for (final folderId in folderIds) {
        _db.execute(
          '''INSERT OR IGNORE INTO favorite_membership
             (source_key, folder_id, comic_id) VALUES (?, ?, ?)''',
          [sourceKey, folderId, comicId],
        );
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    notifyListeners();
  }

  Future<Res<List<NetworkFavoriteFolder>>> refreshFolders(
    FavoriteData data,
  ) async {
    if (!data.multiFolder) {
      final folder = NetworkFavoriteFolder(
        sourceKey: data.key,
        folderId: '',
        title: data.title,
        updatedAt: DateTime.now(),
      );
      _upsertFolders(data.key, [folder], removeMissing: false);
      return Res([folder]);
    }
    if (data.loadFolders == null) {
      return const Res.error('Favorite folders are not supported');
    }
    final result = await data.loadFolders!();
    if (result.error) return Res.error(result.errorMessage!);
    final now = DateTime.now();
    final folders = result.data.entries
        .map(
          (entry) => NetworkFavoriteFolder(
            sourceKey: data.key,
            folderId: entry.key,
            title: entry.value,
            updatedAt: now,
          ),
        )
        .toList();
    _upsertFolders(data.key, folders, removeMissing: true);
    return Res(folders);
  }

  FavoriteFullCacheStatus getFullCacheStatus(NetworkFavoriteFolderRef folder) {
    final rows = _db.select(
      '''SELECT full_cache_at, full_cache_pages, full_cache_comics
         FROM favorite_folders WHERE source_key = ? AND folder_id = ?''',
      [folder.sourceKey, folder.folderId],
    );
    if (rows.isEmpty) return const FavoriteFullCacheStatus();
    final row = rows.first;
    final completedAt = row['full_cache_at'] as int?;
    return FavoriteFullCacheStatus(
      completedAt: completedAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(completedAt),
      pageCount: row['full_cache_pages'] as int? ?? 0,
      comicCount: row['full_cache_comics'] as int? ?? 0,
    );
  }

  int countCachedComics(NetworkFavoriteFolderRef folder) {
    final row = _db
        .select(
          '''SELECT COUNT(DISTINCT comic_id) AS count FROM favorite_items
             WHERE source_key = ? AND folder_id = ?''',
          [folder.sourceKey, folder.folderId],
        )
        .first;
    return row['count'] as int;
  }

  /// Searches every locally cached item in one remote folder. This never
  /// consults a source script or starts a network request.
  List<FavoriteItem> searchCachedComics(
    NetworkFavoriteFolderRef folder,
    String query,
  ) {
    final tokens = _searchTokens(query);
    if (tokens.isEmpty) return const [];
    final conditions = <String>[
      'source_key = ?',
      'folder_id = ?',
      ...List.filled(tokens.length, "search_text LIKE ? ESCAPE '\\'"),
    ];
    final parameters = <Object>[folder.sourceKey, folder.folderId];
    parameters.addAll(tokens.map((token) => '%${_escapeLikeToken(token)}%'));
    final rows = _db.select('''SELECT * FROM favorite_items
         WHERE ${conditions.join(' AND ')}
         ORDER BY page_index, display_order''', parameters);
    final seenIds = <String>{};
    final comics = <FavoriteItem>[];
    for (final row in rows) {
      final item = FavoriteItem.fromRow(row);
      if (seenIds.add(item.id)) comics.add(item);
    }
    return comics;
  }

  static List<String> _searchTokens(String query) => _normalizeSearchText(
    query,
  ).split(' ').where((token) => token.isNotEmpty).toList();

  static String _escapeLikeToken(String value) => value
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');

  static String _normalizeSearchText(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\-_.\\/:|,，。；;、（）()\[\]{}]+'), ' ')
      .trim();

  static String _buildSearchText(String comicId, Map<String, dynamic> json) {
    final tags = json['tags'];
    final tagValues = tags is Iterable
        ? tags.map((tag) => tag.toString())
        : const Iterable<String>.empty();
    return _normalizeSearchText(
      [
        comicId,
        json['title']?.toString() ?? '',
        json['subTitle']?.toString() ?? json['subtitle']?.toString() ?? '',
        ...tagValues,
      ].join(' '),
    );
  }

  void _upsertFolders(
    String sourceKey,
    List<NetworkFavoriteFolder> folders, {
    required bool removeMissing,
  }) {
    _db.execute('BEGIN');
    try {
      if (removeMissing) {
        final ids = folders.map((folder) => folder.folderId).toSet();
        final existing = _db.select(
          'SELECT folder_id FROM favorite_folders WHERE source_key = ?',
          [sourceKey],
        );
        for (final row in existing) {
          final id = row['folder_id'] as String;
          if (!ids.contains(id)) _deleteFolderCache(sourceKey, id);
        }
      }
      for (final folder in folders) {
        _db.execute(
          '''INSERT INTO favorite_folders
             (source_key, folder_id, title, updated_at) VALUES (?, ?, ?, ?)
             ON CONFLICT(source_key, folder_id) DO UPDATE SET
               title = excluded.title,
               updated_at = excluded.updated_at''',
          [
            folder.sourceKey,
            folder.folderId,
            folder.title,
            folder.updatedAt.millisecondsSinceEpoch,
          ],
        );
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    notifyListeners();
  }

  CachedFavoritePage? getCachedPage(
    NetworkFavoriteFolderRef folder,
    int page,
  ) => _getCachedPage(folder, 'page:$page');

  CachedFavoritePage? getCachedNextPage(
    NetworkFavoriteFolderRef folder,
    String? requestToken,
  ) => _getCachedPage(folder, 'next:${requestToken ?? ''}');

  CachedFavoritePage? _getCachedPage(
    NetworkFavoriteFolderRef folder,
    String requestToken,
  ) {
    final pages = _db.select(
      '''SELECT * FROM favorite_pages
         WHERE source_key = ? AND folder_id = ? AND request_token = ?''',
      [folder.sourceKey, folder.folderId, requestToken],
    );
    if (pages.isEmpty) return null;
    final page = pages.first;
    final pageIndex = page['page_index'] as int;
    final rows = _db.select(
      '''SELECT * FROM favorite_items
         WHERE source_key = ? AND folder_id = ? AND page_index = ?
         ORDER BY display_order''',
      [folder.sourceKey, folder.folderId, pageIndex],
    );
    return CachedFavoritePage(
      comics: rows.map(FavoriteItem.fromRow).toList(),
      pageIndex: pageIndex,
      maxPage: page['max_page'] as int?,
      nextToken: page['next_token'] as String?,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(page['updated_at'] as int),
    );
  }

  Future<Res<CachedFavoritePage>> refreshPage(
    FavoriteData data,
    NetworkFavoriteFolderRef folder,
    int page, {
    bool preserveExistingCover = false,
  }) async {
    if (data.loadComic == null) {
      return const Res.error('Favorite paging is not supported');
    }
    final result = await data.loadComic!(page, folder.folderId);
    if (result.error) return Res.error(result.errorMessage!);
    final maxPage = result.subData is int ? result.subData as int : null;
    try {
      return Res(
        _storePage(
          folder,
          pageIndex: page,
          requestToken: 'page:$page',
          comics: result.data,
          maxPage: maxPage,
          nextToken: null,
          clearFollowingCursorPages: false,
          preserveExistingCover: preserveExistingCover,
        ),
      );
    } catch (e, s) {
      Log.error('Favorite page refresh', e.toString(), s);
      return Res.error(e.toString());
    }
  }

  Future<Res<CachedFavoritePage>> refreshNextPage(
    FavoriteData data,
    NetworkFavoriteFolderRef folder,
    String? requestToken, {
    bool preserveExistingCover = false,
  }) async {
    if (data.loadNext == null) {
      return const Res.error('Favorite cursor paging is not supported');
    }
    final result = await data.loadNext!(requestToken, folder.folderId);
    if (result.error) return Res.error(result.errorMessage!);
    final tokenKey = 'next:${requestToken ?? ''}';
    final existing = _getCachedPage(folder, tokenKey);
    final pageIndex = existing?.pageIndex ?? _nextPageIndex(folder);
    try {
      return Res(
        _storePage(
          folder,
          pageIndex: pageIndex,
          requestToken: tokenKey,
          comics: result.data,
          maxPage: null,
          nextToken: result.subData as String?,
          clearFollowingCursorPages:
              existing != null && existing.nextToken != result.subData,
          preserveExistingCover: preserveExistingCover,
        ),
      );
    } catch (e, s) {
      Log.error('Favorite next page refresh', e.toString(), s);
      return Res.error(e.toString());
    }
  }

  int _nextPageIndex(NetworkFavoriteFolderRef folder) {
    final row = _db
        .select(
          '''SELECT MAX(page_index) AS max_page FROM favorite_pages
         WHERE source_key = ? AND folder_id = ?''',
          [folder.sourceKey, folder.folderId],
        )
        .first;
    return (row['max_page'] as int? ?? 0) + 1;
  }

  CachedFavoritePage _storePage(
    NetworkFavoriteFolderRef folder, {
    required int pageIndex,
    required String requestToken,
    required List<Comic> comics,
    required int? maxPage,
    required String? nextToken,
    required bool clearFollowingCursorPages,
    required bool preserveExistingCover,
  }) {
    final now = DateTime.now();
    _db.execute('BEGIN');
    try {
      final updateState = <String, Map<String, Object?>>{};
      for (final row in _db.select(
        '''SELECT source_key, comic_id, comic_json, favorite_id, favorite_time,
                  last_update_time, update_marker, last_check_time, has_new_update,
                  retry_after
           FROM favorite_items
           WHERE source_key = ? AND folder_id = ? AND page_index = ?''',
        [folder.sourceKey, folder.folderId, pageIndex],
      )) {
        updateState[row['comic_id'] as String] = {
          'last_update_time': row['last_update_time'],
          'update_marker': row['update_marker'],
          'last_check_time': row['last_check_time'],
          'has_new_update': row['has_new_update'],
          'retry_after': row['retry_after'],
          'item': FavoriteItem.fromRow(row),
        };
      }
      _db.execute(
        '''DELETE FROM favorite_items
           WHERE source_key = ? AND folder_id = ? AND page_index = ?''',
        [folder.sourceKey, folder.folderId, pageIndex],
      );
      if (clearFollowingCursorPages) {
        _db.execute(
          '''DELETE FROM favorite_items
             WHERE source_key = ? AND folder_id = ? AND page_index > ?''',
          [folder.sourceKey, folder.folderId, pageIndex],
        );
        _db.execute(
          '''DELETE FROM favorite_pages
             WHERE source_key = ? AND folder_id = ? AND page_index > ?''',
          [folder.sourceKey, folder.folderId, pageIndex],
        );
      }
      if (maxPage != null) {
        _db.execute(
          '''DELETE FROM favorite_items
             WHERE source_key = ? AND folder_id = ? AND page_index > ?''',
          [folder.sourceKey, folder.folderId, maxPage],
        );
        _db.execute(
          '''DELETE FROM favorite_pages
             WHERE source_key = ? AND folder_id = ? AND page_index > ?''',
          [folder.sourceKey, folder.folderId, maxPage],
        );
      }
      _db.execute(
        '''INSERT OR REPLACE INTO favorite_pages
           (source_key, folder_id, page_index, request_token, next_token, max_page, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)''',
        [
          folder.sourceKey,
          folder.folderId,
          pageIndex,
          requestToken,
          nextToken,
          maxPage,
          now.millisecondsSinceEpoch,
        ],
      );
      final seenIds = <String>{};
      for (var index = 0; index < comics.length; index++) {
        final remoteItem = FavoriteItem.fromComic(comics[index]);
        if (!seenIds.add(remoteItem.id)) continue;
        final previous = updateState[remoteItem.id];
        final previousItem = previous?['item'] as FavoriteItem?;
        final previousFavoriteTime = previousItem == null
            ? null
            : DateTime.tryParse(previousItem.time.replaceFirst(' ', 'T'));
        final item = FavoriteItem(
          id: remoteItem.id,
          name: remoteItem.name,
          coverPath: preserveExistingCover
              ? previousItem?.coverPath ?? remoteItem.coverPath
              : remoteItem.coverPath,
          author: remoteItem.author,
          sourceKeyValue: remoteItem.sourceKey,
          tags: remoteItem.tags,
          chapterCount: remoteItem.chapterCount ?? previousItem?.chapterCount,
          remoteFavoriteId: remoteItem.favoriteId,
          favoriteTime: previousFavoriteTime,
        );
        _db.execute(
          '''INSERT INTO favorite_items
              (source_key, folder_id, page_index, comic_id, display_order, comic_json,
               favorite_id, favorite_time, search_text, last_update_time, update_marker,
               last_check_time, has_new_update, retry_after)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
          [
            folder.sourceKey,
            folder.folderId,
            pageIndex,
            item.id,
            index,
            jsonEncode(item.toCacheJson()),
            item.favoriteId,
            item.time,
            _buildSearchText(item.id, item.toCacheJson()),
            previous?['last_update_time'],
            previous?['update_marker'],
            previous?['last_check_time'],
            previous?['has_new_update'] ?? 0,
            previous?['retry_after'],
          ],
        );
      }
      _rebuildMembership(folder);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    final cached = _getCachedPage(folder, requestToken)!;
    notifyListeners();
    return cached;
  }

  void _rebuildMembership(NetworkFavoriteFolderRef folder) {
    _db.execute(
      'DELETE FROM favorite_membership WHERE source_key = ? AND folder_id = ?',
      [folder.sourceKey, folder.folderId],
    );
    _db.execute(
      '''INSERT OR IGNORE INTO favorite_membership (source_key, folder_id, comic_id)
         SELECT source_key, folder_id, comic_id FROM favorite_items
         WHERE source_key = ? AND folder_id = ?''',
      [folder.sourceKey, folder.folderId],
    );
  }

  Future<Res<CachedFavoritePage>> loadCachedThenRefreshPage(
    FavoriteData data,
    NetworkFavoriteFolderRef folder,
    int page,
    void Function(CachedFavoritePage page)? onRefreshed,
  ) async {
    final cached = getCachedPage(folder, page);
    if (cached != null) {
      if (DateTime.now().difference(cached.updatedAt) >
          _backgroundRefreshAfter) {
        _refreshInBackground(
          'page:${folder.sourceKey}:${folder.folderId}:$page',
          () => refreshPage(data, folder, page, preserveExistingCover: true),
          onRefreshed,
        );
      }
      return Res(cached, subData: cached.maxPage);
    }
    final result = await refreshPage(data, folder, page);
    if (result.success) onRefreshed?.call(result.data);
    return result.success
        ? Res(result.data, subData: result.data.maxPage)
        : Res.error(result.errorMessage!);
  }

  Future<Res<CachedFavoritePage>> loadCachedThenRefreshNextPage(
    FavoriteData data,
    NetworkFavoriteFolderRef folder,
    String? requestToken,
    void Function(CachedFavoritePage page)? onRefreshed,
  ) async {
    final cached = getCachedNextPage(folder, requestToken);
    if (cached != null) {
      if (DateTime.now().difference(cached.updatedAt) >
          _backgroundRefreshAfter) {
        _refreshInBackground(
          'next:${folder.sourceKey}:${folder.folderId}:${requestToken ?? ''}',
          () => refreshNextPage(
            data,
            folder,
            requestToken,
            preserveExistingCover: true,
          ),
          onRefreshed,
        );
      }
      return Res(cached, subData: cached.nextToken);
    }
    final result = await refreshNextPage(data, folder, requestToken);
    if (result.success) onRefreshed?.call(result.data);
    return result.success
        ? Res(result.data, subData: result.data.nextToken)
        : Res.error(result.errorMessage!);
  }

  void _refreshInBackground(
    String key,
    Future<Res<CachedFavoritePage>> Function() refresh,
    void Function(CachedFavoritePage page)? onRefreshed,
  ) {
    if (_refreshing.contains(key)) return;
    _refreshing.add(key);
    refresh()
        .then((result) {
          if (result.success) onRefreshed?.call(result.data);
        })
        .catchError((Object e, StackTrace s) {
          Log.error('Favorite background refresh', e.toString(), s);
        })
        .whenComplete(() => _refreshing.remove(key));
  }

  /// Refreshes favorite-list summaries already present in the cache.
  ///
  /// Only metadata endpoints are used. Existing cover URLs are retained, so
  /// this does not invalidate image cache entries or cause cover downloads.
  Future<void> refreshCachedSummaries(
    FavoriteData data, {
    Duration minimumAge = backgroundSummaryRefreshAfter,
  }) async {
    var folders = getCachedFolders(data.key);
    final refreshFoldersNeeded =
        folders.isEmpty ||
        folders.any(
          (folder) => DateTime.now().difference(folder.updatedAt) >= minimumAge,
        );
    if (refreshFoldersNeeded) {
      final foldersResult = await refreshFolders(data);
      if (foldersResult.error) return;
      folders = foldersResult.data;
    }
    for (final folder in folders) {
      if (_fullCaching.contains(_folderCacheKey(folder))) continue;
      if (data.loadComic != null) {
        final pages = _db
            .select(
              '''SELECT page_index FROM favorite_pages
                 WHERE source_key = ? AND folder_id = ?
                   AND request_token LIKE 'page:%'
                 ORDER BY page_index''',
              [folder.sourceKey, folder.folderId],
            )
            .map((row) => row['page_index'] as int)
            .toList();
        for (final page in pages) {
          final cached = getCachedPage(folder, page);
          if (cached == null ||
              DateTime.now().difference(cached.updatedAt) < minimumAge) {
            continue;
          }
          await refreshPage(data, folder, page, preserveExistingCover: true);
        }
      } else if (data.loadNext != null) {
        String? token;
        while (true) {
          final cached = getCachedNextPage(folder, token);
          if (cached == null) break;
          if (DateTime.now().difference(cached.updatedAt) >= minimumAge) {
            await refreshNextPage(
              data,
              folder,
              token,
              preserveExistingCover: true,
            );
          }
          final current = getCachedNextPage(folder, token);
          if (current == null || current.nextToken == null) break;
          token = current.nextToken;
        }
      }
    }
  }

  String _folderCacheKey(NetworkFavoriteFolderRef folder) =>
      '${folder.sourceKey}\u0000${folder.folderId}';

  bool isFullCacheRunning(NetworkFavoriteFolderRef folder) =>
      _fullCaching.contains(_folderCacheKey(folder));

  /// Caches all pages in [folder] using favorite-list endpoints only.
  ///
  /// Completed pages are retained if this is cancelled or a later page fails.
  /// The folder's full-cache timestamp is updated only after the terminal page
  /// succeeds.
  Stream<FavoriteFullCacheProgress> cacheAllPages(
    FavoriteData data,
    NetworkFavoriteFolderRef folder, {
    required bool Function() isCanceled,
  }) {
    final stream = StreamController<FavoriteFullCacheProgress>();
    final key = _folderCacheKey(folder);
    if (_fullCaching.contains(key)) {
      stream
        ..add(
          const FavoriteFullCacheProgress(
            pagesCached: 0,
            comicsCached: 0,
            errorMessage: 'A full cache operation is already running',
          ),
        )
        ..close();
      return stream.stream;
    }
    _fullCaching.add(key);
    () async {
      try {
        _upsertFolders(data.key, [
          NetworkFavoriteFolder(
            sourceKey: folder.sourceKey,
            folderId: folder.folderId,
            title: folder.title ?? data.title,
            updatedAt: DateTime.now(),
          ),
        ], removeMissing: false);
        if (data.loadComic != null) {
          await _cacheAllNumberedPages(data, folder, stream, isCanceled);
        } else if (data.loadNext != null) {
          await _cacheAllCursorPages(data, folder, stream, isCanceled);
        } else {
          stream.add(
            const FavoriteFullCacheProgress(
              pagesCached: 0,
              comicsCached: 0,
              errorMessage: 'Favorite paging is not supported',
            ),
          );
        }
      } catch (e) {
        stream.add(
          FavoriteFullCacheProgress(
            pagesCached: 0,
            comicsCached: countCachedComics(folder),
            errorMessage: e.toString(),
          ),
        );
      } finally {
        _fullCaching.remove(key);
        await stream.close();
      }
    }();
    return stream.stream;
  }

  Future<void> _cacheAllNumberedPages(
    FavoriteData data,
    NetworkFavoriteFolderRef folder,
    StreamController<FavoriteFullCacheProgress> stream,
    bool Function() isCanceled,
  ) async {
    var page = 1;
    int? totalPages;
    while (true) {
      if (isCanceled()) {
        stream.add(
          FavoriteFullCacheProgress(
            pagesCached: page - 1,
            comicsCached: countCachedComics(folder),
            totalPages: totalPages,
            isCanceled: true,
          ),
        );
        return;
      }
      final result = await refreshPage(
        data,
        folder,
        page,
        preserveExistingCover: true,
      );
      if (result.error) {
        stream.add(
          FavoriteFullCacheProgress(
            pagesCached: page - 1,
            comicsCached: countCachedComics(folder),
            totalPages: totalPages,
            errorMessage: result.errorMessage,
          ),
        );
        return;
      }
      totalPages ??= result.data.maxPage;
      if (totalPages == null) {
        stream.add(
          FavoriteFullCacheProgress(
            pagesCached: page,
            comicsCached: countCachedComics(folder),
            errorMessage: 'Favorite source did not provide a page count',
          ),
        );
        return;
      }
      final comicsCached = countCachedComics(folder);
      stream.add(
        FavoriteFullCacheProgress(
          pagesCached: page,
          comicsCached: comicsCached,
          totalPages: totalPages,
        ),
      );
      if (page >= totalPages) {
        _markFullCacheComplete(folder, page, comicsCached);
        stream.add(
          FavoriteFullCacheProgress(
            pagesCached: page,
            comicsCached: comicsCached,
            totalPages: totalPages,
            isComplete: true,
          ),
        );
        return;
      }
      page++;
    }
  }

  Future<void> _cacheAllCursorPages(
    FavoriteData data,
    NetworkFavoriteFolderRef folder,
    StreamController<FavoriteFullCacheProgress> stream,
    bool Function() isCanceled,
  ) async {
    String? token;
    var page = 0;
    final seenTokens = <String>{'@root'};
    while (true) {
      if (isCanceled()) {
        stream.add(
          FavoriteFullCacheProgress(
            pagesCached: page,
            comicsCached: countCachedComics(folder),
            isCanceled: true,
          ),
        );
        return;
      }
      final result = await refreshNextPage(
        data,
        folder,
        token,
        preserveExistingCover: true,
      );
      if (result.error) {
        stream.add(
          FavoriteFullCacheProgress(
            pagesCached: page,
            comicsCached: countCachedComics(folder),
            errorMessage: result.errorMessage,
          ),
        );
        return;
      }
      page++;
      final comicsCached = countCachedComics(folder);
      stream.add(
        FavoriteFullCacheProgress(
          pagesCached: page,
          comicsCached: comicsCached,
        ),
      );
      token = result.data.nextToken;
      if (token == null) {
        _markFullCacheComplete(folder, page, comicsCached);
        stream.add(
          FavoriteFullCacheProgress(
            pagesCached: page,
            comicsCached: comicsCached,
            isComplete: true,
          ),
        );
        return;
      }
      if (!seenTokens.add(token)) {
        stream.add(
          FavoriteFullCacheProgress(
            pagesCached: page,
            comicsCached: comicsCached,
            errorMessage: 'Favorite source returned a repeated page cursor',
          ),
        );
        return;
      }
    }
  }

  void _markFullCacheComplete(
    NetworkFavoriteFolderRef folder,
    int pages,
    int comics,
  ) {
    _db.execute(
      '''UPDATE favorite_folders
         SET full_cache_at = ?, full_cache_pages = ?, full_cache_comics = ?
         WHERE source_key = ? AND folder_id = ?''',
      [
        DateTime.now().millisecondsSinceEpoch,
        pages,
        comics,
        folder.sourceKey,
        folder.folderId,
      ],
    );
    notifyListeners();
  }

  bool isFavoriteKnown(String sourceKey, String comicId) {
    final rows = _db.select(
      'SELECT 1 FROM favorite_membership WHERE source_key = ? AND comic_id = ? LIMIT 1',
      [sourceKey, comicId],
    );
    return rows.isNotEmpty;
  }

  String? _cachedFavoriteId(String sourceKey, String folderId, String comicId) {
    final rows = _db.select(
      '''SELECT favorite_id FROM favorite_items
         WHERE source_key = ? AND folder_id = ? AND comic_id = ? LIMIT 1''',
      [sourceKey, folderId, comicId],
    );
    return rows.isEmpty ? null : rows.first['favorite_id'] as String?;
  }

  Future<Res<bool>> changeFavorite({
    required FavoriteData data,
    required NetworkFavoriteFolderRef folder,
    required String comicId,
    required bool isAdding,
    String? favoriteId,
  }) async {
    final source = ComicSource.find(data.key);
    if (source == null) return const Res.error('Comic source not found');
    if (!source.isLogged) return const Res.error('Not login');
    if (data.addOrDelFavorite == null) {
      return const Res.error('Favorites are not supported');
    }
    final effectiveFavoriteId = isAdding
        ? favoriteId
        : favoriteId ??
              _cachedFavoriteId(folder.sourceKey, folder.folderId, comicId);
    final result = await data.addOrDelFavorite!(
      comicId,
      folder.folderId,
      isAdding,
      effectiveFavoriteId,
    );
    if (result.error) return result;

    _db.execute('BEGIN');
    try {
      if (isAdding) {
        _db.execute(
          '''INSERT OR IGNORE INTO favorite_membership
             (source_key, folder_id, comic_id) VALUES (?, ?, ?)''',
          [folder.sourceKey, folder.folderId, comicId],
        );
      } else {
        _db.execute(
          '''DELETE FROM favorite_items
             WHERE source_key = ? AND folder_id = ? AND comic_id = ?''',
          [folder.sourceKey, folder.folderId, comicId],
        );
        _db.execute(
          '''DELETE FROM favorite_membership
             WHERE source_key = ? AND folder_id = ? AND comic_id = ?''',
          [folder.sourceKey, folder.folderId, comicId],
        );
      }
      _db.execute(
        '''UPDATE favorite_pages SET updated_at = 0
           WHERE source_key = ? AND folder_id = ?''',
        [folder.sourceKey, folder.folderId],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    notifyListeners();
    return const Res(true);
  }

  Future<Res<bool>> deleteRemoteFolder(
    FavoriteData data,
    NetworkFavoriteFolderRef folder,
  ) async {
    final source = ComicSource.find(data.key);
    if (source == null) return const Res.error('Comic source not found');
    if (!source.isLogged) return const Res.error('Not login');
    if (data.deleteFolder == null) {
      return const Res.error('Deleting folders is not supported');
    }
    final result = await data.deleteFolder!(folder.folderId);
    if (result.error) return result;
    _deleteFolderCache(folder.sourceKey, folder.folderId);
    notifyListeners();
    return const Res(true);
  }

  Future<Res<bool>> createRemoteFolder(FavoriteData data, String name) async {
    final source = ComicSource.find(data.key);
    if (source == null) return const Res.error('Comic source not found');
    if (!source.isLogged) return const Res.error('Not login');
    if (data.addFolder == null) {
      return const Res.error('Creating folders is not supported');
    }
    final result = await data.addFolder!(name);
    if (result.success) await refreshFolders(data);
    return result;
  }

  void _deleteFolderCache(String sourceKey, String folderId) {
    _db.execute(
      'DELETE FROM favorite_items WHERE source_key = ? AND folder_id = ?',
      [sourceKey, folderId],
    );
    _db.execute(
      'DELETE FROM favorite_pages WHERE source_key = ? AND folder_id = ?',
      [sourceKey, folderId],
    );
    _db.execute(
      'DELETE FROM favorite_membership WHERE source_key = ? AND folder_id = ?',
      [sourceKey, folderId],
    );
    _db.execute(
      'DELETE FROM favorite_folders WHERE source_key = ? AND folder_id = ?',
      [sourceKey, folderId],
    );
  }

  List<FavoriteItemWithUpdateInfo> getComicsWithUpdatesInfo(
    NetworkFavoriteFolderRef folder,
  ) {
    final rows = _db.select(
      '''SELECT * FROM favorite_items
         WHERE source_key = ? AND folder_id = ?
         GROUP BY comic_id
         ORDER BY page_index, display_order''',
      [folder.sourceKey, folder.folderId],
    );
    return rows.map(_toFavoriteItemWithUpdateInfo).toList();
  }

  int countComicsWithUpdatesInfo(NetworkFavoriteFolderRef folder) {
    final row = _db
        .select(
          '''SELECT COUNT(DISTINCT comic_id) AS count FROM favorite_items
             WHERE source_key = ? AND folder_id = ?''',
          [folder.sourceKey, folder.folderId],
        )
        .first;
    return row['count'] as int;
  }

  List<FavoriteItemWithUpdateInfo> getComicsWithUpdatesInfoPage(
    NetworkFavoriteFolderRef folder, {
    required int limit,
    required int offset,
  }) {
    final rows = _db.select(
      '''SELECT * FROM favorite_items
         WHERE source_key = ? AND folder_id = ?
         GROUP BY comic_id
         ORDER BY page_index, display_order
         LIMIT ? OFFSET ?''',
      [folder.sourceKey, folder.folderId, limit, offset],
    );
    return rows.map(_toFavoriteItemWithUpdateInfo).toList();
  }

  FavoriteItemWithUpdateInfo _toFavoriteItemWithUpdateInfo(Row row) {
    return FavoriteItemWithUpdateInfo(
      FavoriteItem.fromRow(row),
      row['last_update_time'] as String?,
      row['update_marker'] as String?,
      (row['has_new_update'] as int? ?? 0) != 0,
      row['last_check_time'] as int?,
      row['retry_after'] as int?,
      checkFailures: row['check_failures'] as int? ?? 0,
      checkNotFoundCount: row['check_not_found_count'] as int? ?? 0,
      isSuspectGone: (row['check_suspect_gone'] as int? ?? 0) != 0,
    );
  }

  /// Updates fields from a comic-detail JSON response without changing the
  /// cover, tags, or other list metadata already in the device cache.
  void updateBasicInfo(
    NetworkFavoriteFolderRef folder,
    String comicId, {
    String? title,
    String? author,
    int? chapterCount,
  }) {
    final rows = _db.select(
      '''SELECT * FROM favorite_items
         WHERE source_key = ? AND folder_id = ? AND comic_id = ?''',
      [folder.sourceKey, folder.folderId, comicId],
    );
    for (final row in rows) {
      final json = FavoriteItem._readComicJson(row);
      if (title != null && title.trim().isNotEmpty) json['title'] = title;
      if (author != null && author.trim().isNotEmpty) {
        json['subTitle'] = author;
      }
      if (chapterCount != null) json['chapterCount'] = chapterCount;
      _db.execute(
        '''UPDATE favorite_items SET comic_json = ?, search_text = ?
           WHERE source_key = ? AND folder_id = ? AND page_index = ?
             AND comic_id = ?''',
        [
          jsonEncode(json),
          _buildSearchText(comicId, json),
          folder.sourceKey,
          folder.folderId,
          row['page_index'],
          comicId,
        ],
      );
    }
  }

  /// Records a completed detail check. The first marker only establishes a
  /// baseline; later marker changes are actual updates.
  bool recordComicCheck(
    NetworkFavoriteFolderRef folder,
    String comicId, {
    String? updateTime,
    String? updateMarker,
  }) {
    final rows = _db.select(
      '''SELECT update_marker FROM favorite_items
         WHERE source_key = ? AND folder_id = ? AND comic_id = ?
         LIMIT 1''',
      [folder.sourceKey, folder.folderId, comicId],
    );
    if (rows.isEmpty) return false;
    final previousMarker = rows.first['update_marker'] as String?;
    final changed =
        previousMarker != null &&
        updateMarker != null &&
        previousMarker != updateMarker;
    _db.execute(
      '''UPDATE favorite_items
          SET last_update_time = COALESCE(?, last_update_time),
              update_marker = COALESCE(?, update_marker),
              last_check_time = ?,
              retry_after = NULL,
              check_failures = 0,
              check_not_found_count = 0,
              check_suspect_gone = 0,
              has_new_update = CASE WHEN ? THEN 1 ELSE has_new_update END
          WHERE source_key = ? AND folder_id = ? AND comic_id = ?''',
      [
        updateTime,
        updateMarker,
        DateTime.now().millisecondsSinceEpoch,
        changed ? 1 : 0,
        folder.sourceKey,
        folder.folderId,
        comicId,
      ],
    );
    return changed;
  }

  /// Marks [comicId] as temporarily skipped by automatic scans after it
  /// failed a check. The value is persisted so a restart does not retry the
  /// failed comic immediately.
  void markComicRetryLater(
    NetworkFavoriteFolderRef folder,
    String comicId, {
    Duration delay = const Duration(hours: 1),
    int failures = 0,
  }) {
    _db.execute(
      '''UPDATE favorite_items
          SET retry_after = ?, check_failures = ?, check_not_found_count = 0
          WHERE source_key = ? AND folder_id = ? AND comic_id = ?''',
      [
        DateTime.now().add(delay).millisecondsSinceEpoch,
        failures,
        folder.sourceKey,
        folder.folderId,
        comicId,
      ],
    );
  }

  /// Records a not-found/removed detail response. The first hit becomes a
  /// pending check; the second consecutive hit is confirmed as suspected
  /// removal by [markComicSuspectGone].
  void markComicNotFound(
    NetworkFavoriteFolderRef folder,
    String comicId, {
    required int notFoundCount,
  }) {
    _db.execute(
      '''UPDATE favorite_items
          SET check_not_found_count = ?, check_failures = 0, retry_after = ?,
              last_check_time = ?
          WHERE source_key = ? AND folder_id = ? AND comic_id = ?''',
      [
        notFoundCount,
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
        DateTime.now().millisecondsSinceEpoch,
        folder.sourceKey,
        folder.folderId,
        comicId,
      ],
    );
  }

  /// Marks [comicId] as suspected removed. Such comics are skipped by all
  /// follow-up scans until the user clears the mark or removes the favorite.
  void markComicSuspectGone(NetworkFavoriteFolderRef folder, String comicId) {
    _db.execute(
      '''UPDATE favorite_items
          SET check_suspect_gone = 1, check_failures = 0,
              check_not_found_count = 0, retry_after = NULL, last_check_time = ?
          WHERE source_key = ? AND folder_id = ? AND comic_id = ?''',
      [
        DateTime.now().millisecondsSinceEpoch,
        folder.sourceKey,
        folder.folderId,
        comicId,
      ],
    );
  }

  void clearComicSuspectGoneEverywhere(String sourceKey, String comicId) {
    _db.execute(
      '''UPDATE favorite_items
          SET check_suspect_gone = 0, check_failures = 0,
              check_not_found_count = 0, retry_after = NULL
          WHERE source_key = ? AND comic_id = ?''',
      [sourceKey, comicId],
    );
    notifyListeners();
  }

  bool isComicSuspectGone(String sourceKey, String comicId) {
    final rows = _db.select(
      '''SELECT 1 FROM favorite_items
         WHERE source_key = ? AND comic_id = ? AND check_suspect_gone != 0
         LIMIT 1''',
      [sourceKey, comicId],
    );
    return rows.isNotEmpty;
  }

  void recordComicNotFoundEverywhere(String sourceKey, String comicId) {
    final rows = _db.select(
      '''SELECT check_not_found_count, check_suspect_gone FROM favorite_items
         WHERE source_key = ? AND comic_id = ? LIMIT 1''',
      [sourceKey, comicId],
    );
    if (rows.isEmpty) return;
    if ((rows.first['check_suspect_gone'] as int? ?? 0) != 0) return;
    final notFoundCount =
        (rows.first['check_not_found_count'] as int? ?? 0) + 1;
    for (final folderId in getKnownFolderIds(sourceKey, comicId)) {
      final folder = NetworkFavoriteFolderRef(
        sourceKey: sourceKey,
        folderId: folderId,
      );
      if (notFoundCount >= 2) {
        markComicSuspectGone(folder, comicId);
      } else {
        markComicNotFound(folder, comicId, notFoundCount: notFoundCount);
      }
    }
    notifyListeners();
  }

  List<FavoriteItemWithUpdateInfo> getSuspectGoneComicsInFolders(
    Iterable<NetworkFavoriteFolderRef> folders,
  ) {
    final list = folders.toList();
    if (list.isEmpty) return const [];
    final rows = _db.select(
      '''SELECT * FROM favorite_items
         WHERE ${_folderWhereClause(list)} AND check_suspect_gone != 0
         GROUP BY source_key, comic_id
         ORDER BY source_key, comic_id''',
      list.expand((f) => [f.sourceKey, f.folderId]).toList(),
    );
    return rows.map(_toFavoriteItemWithUpdateInfo).toList();
  }

  Future<Res<bool>> removeFavoriteEverywhere(
    String sourceKey,
    String comicId,
  ) async {
    final source = ComicSource.find(sourceKey);
    final data = source?.favoriteData;
    if (source == null || data == null) {
      return const Res.error('Comic source not found');
    }
    if (!source.isLogged) return const Res.error('Not login');
    if (data.addOrDelFavorite == null) {
      return const Res.error('Favorites are not supported');
    }
    final folderIds = getKnownFolderIds(sourceKey, comicId);
    var anySuccess = false;
    String? lastError;
    for (final folderId in folderIds) {
      final folder = NetworkFavoriteFolderRef(
        sourceKey: sourceKey,
        folderId: folderId,
      );
      final result = await changeFavorite(
        data: data,
        folder: folder,
        comicId: comicId,
        isAdding: false,
      );
      if (result.error) {
        lastError = result.errorMessage;
      } else {
        anySuccess = true;
      }
    }
    if (anySuccess) return const Res(true);
    return Res.error(lastError ?? 'No cached favorite folder found');
  }

  void markAsRead(NetworkFavoriteFolderRef folder, String comicId) {
    _db.execute(
      '''UPDATE favorite_items SET has_new_update = 0
         WHERE source_key = ? AND folder_id = ? AND comic_id = ?''',
      [folder.sourceKey, folder.folderId, comicId],
    );
    notifyListeners();
  }

  void markReadInAllFolders(String sourceKey, String comicId) {
    _db.execute(
      '''UPDATE favorite_items SET has_new_update = 0
         WHERE source_key = ? AND comic_id = ?''',
      [sourceKey, comicId],
    );
    notifyListeners();
  }

  /// Flushes update-check changes that are deliberately batched to avoid a UI
  /// notification for every comic in a follow-updates run.
  void notifyCacheChanged() => notifyListeners();

  /// Number of cached comics in [folder] that have never completed a
  /// follow-up check. A comic only counts as checked once its detail request
  /// succeeded, regardless of whether the source exposed a usable marker.
  int countUncheckedComics(NetworkFavoriteFolderRef folder) {
    final row = _db
        .select(
          '''SELECT COUNT(DISTINCT comic_id) AS count FROM favorite_items
             WHERE source_key = ? AND folder_id = ? AND last_check_time IS NULL''',
          [folder.sourceKey, folder.folderId],
        )
        .first;
    return row['count'] as int;
  }

  bool hasUncheckedComics(NetworkFavoriteFolderRef folder) =>
      countUncheckedComics(folder) > 0;

  /// Removes every follow-up baseline so the next check re-establishes it.
  ///
  /// Only update-check metadata is reset; cached comics and folders remain.
  void clearAllBaselines() {
    _db.execute('''
      UPDATE favorite_items
      SET last_check_time = NULL,
          last_update_time = NULL,
          update_marker = NULL,
          has_new_update = 0
    ''');
    notifyListeners();
  }

  int countUpdates(NetworkFavoriteFolderRef folder) {
    final row = _db
        .select(
          '''SELECT COUNT(DISTINCT comic_id) AS count FROM favorite_items
         WHERE source_key = ? AND folder_id = ? AND has_new_update != 0''',
          [folder.sourceKey, folder.folderId],
        )
        .first;
    return row['count'] as int;
  }

  static String _folderWhereClause(List<NetworkFavoriteFolderRef> folders) {
    if (folders.isEmpty) return '0';
    return '(${folders.map((f) => '(source_key = ? AND folder_id = ?)').join(' OR ')})';
  }

  int _countDistinctComicsInFolders(
    Iterable<NetworkFavoriteFolderRef> folders, {
    String? extraCondition,
  }) {
    final list = folders.toList();
    if (list.isEmpty) return 0;
    final conditions = <String>[_folderWhereClause(list)];
    if (extraCondition != null) conditions.add(extraCondition);
    final row = _db.select('''SELECT COUNT(*) AS count FROM (
             SELECT source_key, comic_id FROM favorite_items
             WHERE ${conditions.join(' AND ')}
             GROUP BY source_key, comic_id
           )''', list.expand((f) => [f.sourceKey, f.folderId]).toList()).first;
    return row['count'] as int;
  }

  int countCachedComicsInFolders(Iterable<NetworkFavoriteFolderRef> folders) =>
      _countDistinctComicsInFolders(folders);

  int countUncheckedComicsInFolders(
    Iterable<NetworkFavoriteFolderRef> folders,
  ) => _countDistinctComicsInFolders(
    folders,
    extraCondition: 'last_check_time IS NULL',
  );

  int countUpdatesInFolders(Iterable<NetworkFavoriteFolderRef> folders) =>
      _countDistinctComicsInFolders(
        folders,
        extraCondition: 'has_new_update != 0',
      );

  int countComicsWithUpdatesInfoInFolders(
    Iterable<NetworkFavoriteFolderRef> folders,
  ) => countCachedComicsInFolders(folders);

  List<FavoriteItemWithUpdateInfo> getComicsWithUpdatesInfoPageInFolders(
    Iterable<NetworkFavoriteFolderRef> folders, {
    required int limit,
    required int offset,
  }) {
    final list = folders.toList();
    if (list.isEmpty) return const [];
    final rows = _db.select(
      '''SELECT * FROM favorite_items
         WHERE ${_folderWhereClause(list)}
         GROUP BY source_key, comic_id
         ORDER BY source_key, comic_id
         LIMIT ? OFFSET ?''',
      [
        ...list.expand((f) => [f.sourceKey, f.folderId]),
        limit,
        offset,
      ],
    );
    return rows.map(_toFavoriteItemWithUpdateInfo).toList();
  }

  List<FavoriteItemWithUpdateInfo> getUpdatedComicsInFolders(
    Iterable<NetworkFavoriteFolderRef> folders,
  ) {
    final list = folders.toList();
    if (list.isEmpty) return const [];
    final rows = _db.select(
      '''SELECT * FROM favorite_items
         WHERE ${_folderWhereClause(list)} AND has_new_update != 0
         GROUP BY source_key, comic_id
         ORDER BY last_update_time DESC, source_key, comic_id''',
      list.expand((f) => [f.sourceKey, f.folderId]).toList(),
    );
    return rows.map(_toFavoriteItemWithUpdateInfo).toList();
  }
}
