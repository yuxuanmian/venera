import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as file_path;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/favorite_search.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/schedule/sqlite_schedule_repository.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';

enum FollowUpdatesTab { unread, recent }

class FollowUpdatesIdentity {
  const FollowUpdatesIdentity(this.sourceKey, this.comicId);

  final String sourceKey;
  final String comicId;

  @override
  bool operator ==(Object other) =>
      other is FollowUpdatesIdentity &&
      other.sourceKey == sourceKey &&
      other.comicId == comicId;

  @override
  int get hashCode => Object.hash(sourceKey, comicId);
}

/// A continuation token for one ordered candidate snapshot.
class FollowUpdatesCursor {
  const FollowUpdatesCursor({
    required this.offset,
    required this.requestToken,
    required this.snapshotToken,
  });

  final int offset;
  final String requestToken;
  final String snapshotToken;
}

class FollowUpdatesEntry {
  const FollowUpdatesEntry({required this.comic, this.autoHotUntil});

  final FavoriteItem comic;
  final DateTime? autoHotUntil;

  String get sourceKey => comic.sourceKey;
  String get comicId => comic.id;
}

class FollowUpdatesPageResult {
  FollowUpdatesPageResult({
    required Iterable<FollowUpdatesEntry> items,
    required this.totalCount,
    required this.nextCursor,
    required this.snapshotToken,
  }) : items = List.unmodifiable(items);

  final List<FollowUpdatesEntry> items;
  final int totalCount;
  final FollowUpdatesCursor? nextCursor;
  final String snapshotToken;

  bool get hasMore => nextCursor != null;
}

class FollowUpdatesQueryException implements Exception {
  const FollowUpdatesQueryException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'Follow-up query error: $message';
}

class FollowUpdatesCursorExpiredException extends FollowUpdatesQueryException {
  const FollowUpdatesCursorExpiredException()
    : super('The follow-up result changed; restart from the first page');
}

/// Reads the follow-up tabs from the three existing stores.
///
/// The caller supplies the source keys currently allowed by the per-source
/// gate. A debug-gate bypass passes the gate's full criterion set instead of
/// its satisfied set; this data layer does not duplicate that UI policy.
class FollowUpdatesQueryService {
  FollowUpdatesQueryService({
    String Function()? favoriteDatabasePath,
    String Function()? trackingDatabasePath,
    String Function()? scheduleDatabasePath,
    SqliteJudgmentRepository? trackingRepository,
    SqliteScheduleRepository? scheduleRepository,
  }) {
    _trackingRepository =
        trackingRepository ??
        (trackingDatabasePath == null
            ? judgmentStateRepository
            : SqliteJudgmentRepository(
                databasePath: trackingDatabasePath.call(),
              ));
    _scheduleRepository =
        scheduleRepository ??
        (scheduleDatabasePath == null
            ? scheduleStateRepository
            : SqliteScheduleRepository(
                databasePath: scheduleDatabasePath.call(),
              ));
    _favoriteDatabasePath =
        favoriteDatabasePath ?? _defaultFavoriteDatabasePath;
    _trackingDatabasePath =
        trackingDatabasePath ?? (() => _trackingRepository.databasePath);
    _scheduleDatabasePath =
        scheduleDatabasePath ?? (() => _scheduleRepository.databasePath);
  }

  late final String Function() _favoriteDatabasePath;
  late final String Function() _trackingDatabasePath;
  late final String Function() _scheduleDatabasePath;
  late final SqliteJudgmentRepository _trackingRepository;
  late final SqliteScheduleRepository _scheduleRepository;

  /// Returns every visible unread identity for the badge and mark-all-read.
  ///
  /// Identity authority comes from `tracking_state.db`; the favorite cache is
  /// joined only to enforce visibility. This method does not use the retired
  /// `comic_check_state` table.
  Future<Set<FollowUpdatesIdentity>> readVisibleUnreadIdentities({
    required Iterable<String> allowedSourceKeys,
  }) async {
    final sources = _normalizeSourceKeys(allowedSourceKeys);
    if (sources.isEmpty) return <FollowUpdatesIdentity>{};
    return _withReadDatabases(
      tab: FollowUpdatesTab.unread,
      sources: sources,
      read: _readVisibleUnreadIdentities,
    );
  }

  /// Queries one page after filtering, deduplicating and sorting all candidates.
  ///
  /// Only the current page's `comic_json` is read. [cursor] must come from the
  /// immediately preceding page for the same tab, source set, query and page
  /// size; if the candidate snapshot changed, [FollowUpdatesCursorExpiredException]
  /// tells the UI to restart at page one.
  Future<FollowUpdatesPageResult> queryPage({
    required Iterable<String> allowedSourceKeys,
    required DateTime now,
    required FollowUpdatesTab tab,
    String query = '',
    int pageSize = 30,
    FollowUpdatesCursor? cursor,
  }) async {
    if (pageSize <= 0) {
      throw ArgumentError.value(pageSize, 'pageSize', 'must be positive');
    }
    final sources = _normalizeSourceKeys(allowedSourceKeys);
    final requestToken = _requestToken(tab, sources, query, pageSize);
    if (cursor != null &&
        (cursor.offset < 0 || cursor.requestToken != requestToken)) {
      throw const FollowUpdatesCursorExpiredException();
    }
    if (sources.isEmpty) {
      return FollowUpdatesPageResult(
        items: const [],
        totalCount: 0,
        nextCursor: null,
        snapshotToken: _digest(<String>[tab.name, 'empty']),
      );
    }

    return _withReadDatabases(
      tab: tab,
      sources: sources,
      read: (database) {
        final candidates = _readCandidates(database, tab, now, query);
        final snapshotToken = _snapshotToken(tab, candidates);
        if (cursor != null && cursor.snapshotToken != snapshotToken) {
          throw const FollowUpdatesCursorExpiredException();
        }
        final offset = cursor?.offset ?? 0;
        if (offset > candidates.length) {
          throw const FollowUpdatesCursorExpiredException();
        }
        final end = (offset + pageSize).clamp(0, candidates.length).toInt();
        final pageCandidates = candidates.sublist(offset, end);
        final delayedUntil = _readPageComics(database, pageCandidates);
        final items = [
          for (final candidate in pageCandidates)
            FollowUpdatesEntry(
              comic: delayedUntil[candidate.sourceRowId]!,
              autoHotUntil: candidate.autoHotUntilMs == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(
                      candidate.autoHotUntilMs!,
                    ),
            ),
        ];
        return FollowUpdatesPageResult(
          items: items,
          totalCount: candidates.length,
          nextCursor: end < candidates.length
              ? FollowUpdatesCursor(
                  offset: end,
                  requestToken: requestToken,
                  snapshotToken: snapshotToken,
                )
              : null,
          snapshotToken: snapshotToken,
        );
      },
    );
  }

  Future<T> _withReadDatabases<T>({
    required FollowUpdatesTab tab,
    required List<String> sources,
    required T Function(Database database) read,
  }) async {
    if (tab == FollowUpdatesTab.unread) {
      await _trackingRepository.ensureOpen();
    } else {
      await _scheduleRepository.ensureOpen();
    }
    final favoritePath = _favoriteDatabasePath();
    final statePath = tab == FollowUpdatesTab.unread
        ? _trackingDatabasePath()
        : _scheduleDatabasePath();
    _requireDatabase(favoritePath, 'favorite cache');
    _requireDatabase(
      statePath,
      tab == FollowUpdatesTab.unread ? 'tracking state' : 'schedule state',
    );

    final database = sqlite3.openInMemory();
    try {
      database.execute('ATTACH DATABASE ? AS favorites', [favoritePath]);
      database.execute(
        'ATTACH DATABASE ? AS ${tab == FollowUpdatesTab.unread ? 'tracking' : 'schedule'}',
        [statePath],
      );
      database.execute('''
        CREATE TEMP TABLE allowed_sources (
          source_key TEXT PRIMARY KEY
        )
      ''');
      for (final source in sources) {
        database.execute(
          'INSERT INTO allowed_sources (source_key) VALUES (?)',
          [source],
        );
      }
      database.execute('BEGIN');
      return read(database);
    } on FollowUpdatesCursorExpiredException {
      rethrow;
    } catch (error) {
      throw FollowUpdatesQueryException(
        'Unable to read local follow-up data',
        error,
      );
    } finally {
      try {
        database.execute('ROLLBACK');
      } catch (_) {}
      database.dispose();
    }
  }

  Set<FollowUpdatesIdentity> _readVisibleUnreadIdentities(Database database) {
    final rows = database.select('''
      SELECT DISTINCT item.source_key, item.comic_id
      FROM favorites.favorite_items AS item
      INNER JOIN allowed_sources AS allowed
        ON allowed.source_key = item.source_key
      INNER JOIN tracking.judgment_state AS state
        ON state.source_key = item.source_key
       AND state.comic_id = item.comic_id
       AND state.has_new_update != 0
    ''');
    return {
      for (final row in rows)
        FollowUpdatesIdentity(
          row['source_key'] as String,
          row['comic_id'] as String,
        ),
    };
  }

  List<_Candidate> _readCandidates(
    Database database,
    FollowUpdatesTab tab,
    DateTime now,
    String query,
  ) {
    final scopeJoin = tab == FollowUpdatesTab.unread
        ? '''
          INNER JOIN tracking.judgment_state AS state
            ON state.source_key = item.source_key
           AND state.comic_id = item.comic_id
           AND state.has_new_update != 0
        '''
        : '''
          INNER JOIN schedule.schedule_state AS state
            ON state.source_key = item.source_key
           AND state.comic_id = item.comic_id
           AND state.auto_hot_until > ?
        ''';
    final autoHotSelection = tab == FollowUpdatesTab.recent
        ? 'state.auto_hot_until'
        : 'NULL';
    final tokens = favoriteSearchTokens(query);
    final search = tokens.isEmpty
        ? ''
        : '''
          WHERE ${tokens.map((_) => "candidate.search_text LIKE ? ESCAPE '\\'").join(' AND ')}
        ''';
    final parameters = <Object>[
      if (tab == FollowUpdatesTab.recent) now.millisecondsSinceEpoch,
      ...tokens.map((token) => '%${escapeFavoriteSearchLikeToken(token)}%'),
    ];
    final rows = database.select('''
      WITH scoped_favorites AS (
        SELECT
          item.rowid AS representative_rowid,
          item.source_key,
          item.comic_id,
          item.folder_id,
          item.page_index,
          item.display_order,
          item.comic_json,
          COALESCE(item.search_text, '') AS search_text,
          $autoHotSelection AS auto_hot_until
        FROM favorites.favorite_items AS item
        INNER JOIN allowed_sources AS allowed
          ON allowed.source_key = item.source_key
        $scopeJoin
      ),
      ranked_favorites AS (
        SELECT
          item.representative_rowid,
          item.source_key,
          item.comic_id,
          CAST(json_extract(item.comic_json, '\$.title') AS TEXT) AS title,
          item.search_text,
          item.auto_hot_until,
          ROW_NUMBER() OVER (
            PARTITION BY item.source_key, item.comic_id
            ORDER BY item.folder_id, item.page_index, item.display_order,
                     item.representative_rowid
          ) AS dedupe_row
        FROM scoped_favorites AS item
      ),
      candidates AS (
        SELECT * FROM ranked_favorites WHERE dedupe_row = 1
      )
      SELECT
        candidate.representative_rowid,
        candidate.source_key,
        candidate.comic_id,
        candidate.title,
        candidate.search_text,
        candidate.auto_hot_until
      FROM candidates AS candidate
      $search
      ''', parameters);
    final candidates = [
      for (final row in rows)
        _Candidate(
          sourceRowId: row['representative_rowid'] as int,
          sourceKey: row['source_key'] as String,
          comicId: row['comic_id'] as String,
          title: row['title'] as String? ?? '',
          searchText: row['search_text'] as String,
          autoHotUntilMs: row['auto_hot_until'] as int?,
        ),
    ];
    candidates.sort((left, right) {
      if (tab == FollowUpdatesTab.recent) {
        final byHotWindow = right.autoHotUntilMs!.compareTo(
          left.autoHotUntilMs!,
        );
        if (byHotWindow != 0) return byHotWindow;
      } else {
        final byTitle = left.title.compareTo(right.title);
        if (byTitle != 0) return byTitle;
      }
      final bySource = left.sourceKey.compareTo(right.sourceKey);
      return bySource != 0 ? bySource : left.comicId.compareTo(right.comicId);
    });
    return candidates;
  }

  Map<int, FavoriteItem> _readPageComics(
    Database database,
    List<_Candidate> candidates,
  ) {
    if (candidates.isEmpty) return const {};
    final placeholders = List.filled(candidates.length, '?').join(', ');
    final rows = database.select('''
      SELECT rowid AS source_rowid, source_key, comic_id, favorite_time,
             favorite_id, comic_json
      FROM favorites.favorite_items
      WHERE rowid IN ($placeholders)
      ''', candidates.map((candidate) => candidate.sourceRowId).toList());
    return {
      for (final row in rows)
        row['source_rowid'] as int: FavoriteItem.fromRow(row),
    };
  }

  static List<String> _normalizeSourceKeys(Iterable<String> sourceKeys) =>
      sourceKeys.where((key) => key.isNotEmpty).toSet().toList()..sort();

  static String _requestToken(
    FollowUpdatesTab tab,
    List<String> sources,
    String query,
    int pageSize,
  ) => _digest(<String>[
    tab.name,
    normalizeFavoriteSearchText(query),
    pageSize.toString(),
    ...sources,
  ]);

  static String _snapshotToken(
    FollowUpdatesTab tab,
    List<_Candidate> candidates,
  ) => _digest(<String>[
    tab.name,
    for (final candidate in candidates) ...[
      candidate.sourceRowId.toString(),
      candidate.sourceKey,
      candidate.comicId,
      candidate.title,
      candidate.searchText,
      candidate.autoHotUntilMs?.toString() ?? '',
    ],
  ]);

  static String _digest(Iterable<String> values) {
    final buffer = StringBuffer();
    for (final value in values) {
      buffer
        ..write(value.length)
        ..write(':')
        ..write(value);
    }
    return sha256.convert(utf8.encode(buffer.toString())).toString();
  }

  static void _requireDatabase(String path, String role) {
    if (!File(path).existsSync()) {
      throw FollowUpdatesQueryException('The $role database does not exist');
    }
  }
}

class _Candidate {
  const _Candidate({
    required this.sourceRowId,
    required this.sourceKey,
    required this.comicId,
    required this.title,
    required this.searchText,
    required this.autoHotUntilMs,
  });

  final int sourceRowId;
  final String sourceKey;
  final String comicId;
  final String title;
  final String searchText;
  final int? autoHotUntilMs;
}

String _defaultFavoriteDatabasePath() =>
    file_path.join(App.dataPath, 'network_favorite_cache.db');

/// Product-owned reader for the follow-up list and badge.
final followUpdatesQueryService = FollowUpdatesQueryService();
