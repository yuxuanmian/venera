import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

import 'app.dart';
import 'appdata.dart';
import 'catalog/source_preferences.dart';
import 'comic_source/comic_source.dart';
import 'favorite_search.dart';
import 'favorites.dart';
import 'follow_updates.dart';
import 'follow_updates_query.dart';
import 'tracking/sqlite_judgment_repository.dart';

/// The folders that must have published complete favorites for this source.
/// An empty list for a multi-folder source can be a confirmed empty directory.
List<NetworkFavoriteFolderRef> favoriteUpdateFolders(FavoriteData data) =>
    _favoriteUpdateFolders(data, NetworkFavoriteCacheManager());

List<NetworkFavoriteFolderRef> _favoriteUpdateFolders(
  FavoriteData data,
  NetworkFavoriteCacheManager cache,
) {
  final folderId = data.cacheAllFolder ?? (data.multiFolder ? null : '');
  if (folderId != null) {
    return [NetworkFavoriteFolderRef(sourceKey: data.key, folderId: folderId)];
  }
  try {
    return cache.getCachedFolders(data.key);
  } catch (error) {
    if (_isUninitializedCache(error)) return const [];
    rethrow;
  }
}

/// Whether this is the active, eligible favorites capability for its source.
bool favoriteUpdatesSupported(FavoriteData data) {
  final source = ComicSource.find(data.key);
  return source != null &&
      identical(source.favoriteData, data) &&
      isSourceEnabled(data.key) &&
      followUpdateSelectedSourceKeys().contains(data.key) &&
      (source.account == null || source.isLogged) &&
      (sourceDeclaresUnreadSignal(data.key) ||
          source.scan?.isSupported == true);
}

/// Whether the eligible source has complete published membership in scope.
bool favoriteUpdatesCacheReady(FavoriteData data) =>
    favoriteUpdatesSupported(data) &&
    _readyFolders(data, NetworkFavoriteCacheManager()) != null;

List<NetworkFavoriteFolderRef>? _readyFolders(
  FavoriteData data,
  NetworkFavoriteCacheManager cache,
) {
  final folders = _favoriteUpdateFolders(data, cache);
  try {
    if (folders.isEmpty) {
      return cache.hasLoadedFavoriteDirectory(data.key) ? folders : null;
    }
    return folders.every(
          (folder) => cache.getFullCacheStatus(folder).isComplete,
        )
        ? folders
        : null;
  } catch (error) {
    if (_isUninitializedCache(error)) return null;
    rethrow;
  }
}

bool _isUninitializedCache(Object error) => const {
  'LateError',
  'LateInitializationError',
}.contains(error.runtimeType.toString());

/// Local reader shared by the per-source update badge and list.
class FavoriteUpdatesQuery {
  FavoriteUpdatesQuery({
    NetworkFavoriteCacheManager? cache,
    String Function()? favoriteDatabasePath,
    SqliteJudgmentRepository? trackingRepository,
  }) : _cache = cache ?? NetworkFavoriteCacheManager(),
       _favoriteDatabasePath =
           favoriteDatabasePath ?? _defaultFavoriteDatabasePath,
       _trackingRepository = trackingRepository ?? judgmentStateRepository;

  final NetworkFavoriteCacheManager _cache;
  final String Function() _favoriteDatabasePath;
  final SqliteJudgmentRepository _trackingRepository;

  /// The full unread count for the current source, or null until ready.
  Future<int?> count(FavoriteData data) =>
      _read(data, (db, candidates, parameters, _) {
        return db.select('''
          $candidates
          SELECT COUNT(DISTINCT comic_id) AS total FROM unread_favorites
        ''', parameters).single['total']
            as int;
      });

  /// Reads a filtered page with a total for that filter. A stale continuation
  /// throws [FollowUpdatesCursorExpiredException] so callers can start over.
  Future<FollowUpdatesPageResult?> queryPage(
    FavoriteData data, {
    String keyword = '',
    FollowUpdatesCursor? after,
    int pageSize = 30,
  }) async {
    if (pageSize <= 0) {
      throw ArgumentError.value(pageSize, 'pageSize', 'must be positive');
    }
    final tokens = favoriteSearchTokens(keyword);
    return _read(data, (db, candidates, parameters, session) {
      final requestToken = _digest([
        'favoriteUpdates',
        session,
        tokens,
        pageSize,
      ]);
      final offset = after?.offset ?? 0;
      if (offset < 0 || (after != null && after.requestToken != requestToken)) {
        throw const FollowUpdatesCursorExpiredException();
      }
      final search = tokens
          .map((_) => "AND search_text LIKE ? ESCAPE '\\'")
          .join(' ');
      final rows =
          db
              .select(
                '''
        $candidates,
        ranked AS (
          SELECT rowid, comic_id, comic_json, search_text,
                 ROW_NUMBER() OVER (
                   PARTITION BY comic_id
                   ORDER BY folder_id, page_index, display_order, rowid
                 ) AS representative
          FROM unread_favorites
        )
        SELECT rowid, comic_id, search_text,
               CAST(json_extract(comic_json, '\$.title') AS TEXT) AS title
        FROM ranked
        WHERE representative = 1 $search
      ''',
                [
                  ...parameters,
                  for (final token in tokens)
                    '%${escapeFavoriteSearchLikeToken(token)}%',
                ],
              )
              .toList()
            ..sort((left, right) {
              final byTitle = (left['title'] as String? ?? '').compareTo(
                right['title'] as String? ?? '',
              );
              return byTitle != 0
                  ? byTitle
                  : (left['comic_id'] as String).compareTo(
                      right['comic_id'] as String,
                    );
            });
      final snapshotToken = _digest([
        requestToken,
        for (final row in rows)
          [row['rowid'], row['comic_id'], row['title'], row['search_text']],
      ]);
      if (offset > rows.length ||
          (after != null && after.snapshotToken != snapshotToken)) {
        throw const FollowUpdatesCursorExpiredException();
      }

      final end = offset + pageSize.clamp(0, rows.length - offset).toInt();
      final ids = rows
          .sublist(offset, end)
          .map((row) => row['rowid'] as int)
          .toList();
      final comics = <int, FavoriteItem>{
        for (final row in db.select(
          '''
          SELECT rowid, source_key, comic_id, favorite_time, favorite_id, comic_json
          FROM favorites.favorite_items
          WHERE rowid IN (SELECT value FROM json_each(?))
        ''',
          [jsonEncode(ids)],
        ))
          row['rowid'] as int: FavoriteItem.fromRow(row),
      };
      return FollowUpdatesPageResult(
        items: [for (final id in ids) FollowUpdatesEntry(comic: comics[id]!)],
        totalCount: rows.length,
        nextCursor: end < rows.length
            ? FollowUpdatesCursor(
                offset: end,
                requestToken: requestToken,
                snapshotToken: snapshotToken,
              )
            : null,
        snapshotToken: snapshotToken,
      );
    });
  }

  Future<T?> _read<T>(
    FavoriteData data,
    T Function(
      Database db,
      String candidates,
      List<Object> parameters,
      List<Object> session,
    )
    read,
  ) async {
    if (!favoriteUpdatesSupported(data)) return null;
    final key = data.key;
    final epoch = _cache.captureFavoriteSessionEpoch(key);
    final manager = ComicSourceManager();
    final assembly = manager.assemblyRevision;
    bool isCurrent() =>
        manager.assemblyRevision == assembly &&
        _cache.isFavoriteSessionEpochCurrent(key, epoch) &&
        favoriteUpdatesSupported(data);

    final sourceUnread = sourceDeclaresUnreadSignal(key);
    try {
      var folders = _readyFolders(data, _cache);
      if (folders == null) return null;
      if (!sourceUnread && folders.isNotEmpty) {
        await _trackingRepository.ensureOpen();
        if (!isCurrent()) return null;
        folders = _readyFolders(data, _cache);
        if (folders == null) return null;
      }
      final favoritePath = _favoriteDatabasePath();
      if (!File(favoritePath).existsSync()) {
        throw const FollowUpdatesQueryException(
          'The favorite cache database does not exist',
        );
      }
      final folderIds = folders.map((folder) => folder.folderId).toList()
        ..sort();
      final trackingPath = !sourceUnread && folderIds.isNotEmpty
          ? _trackingRepository.databasePath
          : null;
      if (trackingPath != null && !File(trackingPath).existsSync()) {
        throw const FollowUpdatesQueryException(
          'The tracking state database does not exist',
        );
      }
      final database = sqlite3.openInMemory();
      try {
        final blockedWords = List<String>.from(
          appdata.settings['blockedWords'],
        );
        if (blockedWords.isNotEmpty) {
          database.createFunction(
            functionName: 'is_visible_favorite',
            argumentCount: const AllowedArgumentCount(2),
            function: (arguments) {
              final json = jsonDecode(arguments[0] as String) as Map;
              final blocked = blockedComicKeyword(
                blockedWords,
                title: json['title'] as String? ?? '',
                subtitle: (json['subTitle'] ?? json['subtitle'])?.toString(),
                description: '$key | ${arguments[1]}',
                tags: List<String>.from(json['tags'] ?? const []),
              );
              return blocked == null ? 1 : 0;
            },
          );
        }
        database.execute('ATTACH DATABASE ? AS favorites', [favoritePath]);
        if (trackingPath != null) {
          database.execute('ATTACH DATABASE ? AS tracking', [trackingPath]);
        }
        database.execute('BEGIN');
        // An empty directory has no candidate rows and needs no judgment DB.
        final authority = trackingPath == null
            ? ('favorites.favorite_source_unread', 'is_unread')
            : ('tracking.judgment_state', 'has_new_update');
        final result = read(
          database,
          '''
          WITH unread_favorites AS (
            SELECT item.rowid, item.comic_id, item.folder_id, item.page_index,
                   item.display_order, item.comic_json, item.search_text
            FROM favorites.favorite_membership AS member
            JOIN ${authority.$1} AS state
              ON state.source_key = member.source_key
             AND state.comic_id = member.comic_id
             AND state.${authority.$2} != 0
            JOIN favorites.favorite_items AS item
              ON item.source_key = member.source_key
             AND item.folder_id = member.folder_id
             AND item.comic_id = member.comic_id
            WHERE member.source_key = ?
              AND member.folder_id IN (SELECT value FROM json_each(?))
              ${blockedWords.isEmpty ? '' : '''
              AND is_visible_favorite(
                item.comic_json,
                SUBSTR(COALESCE(item.favorite_time, DATE('now', 'localtime')), 1, 10)
              ) = 1'''}
          )
          ''',
          [key, jsonEncode(folderIds)],
          [key, epoch, assembly, folderIds, blockedWords],
        );
        return isCurrent() ? result : null;
      } finally {
        database.dispose();
      }
    } on FollowUpdatesQueryException {
      rethrow;
    } catch (error) {
      if (!isCurrent()) return null;
      throw FollowUpdatesQueryException(
        'Unable to read favorite updates',
        error,
      );
    }
  }
}

String _digest(List<Object> values) =>
    sha256.convert(utf8.encode(jsonEncode(values))).toString();

String _defaultFavoriteDatabasePath() =>
    path.join(App.dataPath, 'network_favorite_cache.db');

final favoriteUpdatesQuery = FavoriteUpdatesQuery();
