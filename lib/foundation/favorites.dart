import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/follow_update_schedule.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/io.dart';

import 'app.dart';
import 'follow_update_marker.dart';

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
  FavoriteUpdateHint? get favoriteUpdate => null;

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
    this.baselineAt,
    this.sourceActivityAt,
    this.nextCheckAt,
    this.autoHotUntil,
    this.manualHotUntil,
    this.manualHotEnabled = false,
    this.oldScheduleJitterApplied = false,
    this.sourceUpdateMetadata,
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
  final DateTime? baselineAt;
  final DateTime? sourceActivityAt;
  final DateTime? nextCheckAt;
  final DateTime? autoHotUntil;
  final DateTime? manualHotUntil;
  final bool manualHotEnabled;
  final bool oldScheduleJitterApplied;
  final Map<String, dynamic>? sourceUpdateMetadata;

  DateTime? get effectiveActivityAt => sourceActivityAt ?? baselineAt;

  bool isAutoHotActiveAt(DateTime now) =>
      isAutoHotActive(now: now, autoHotUntil: autoHotUntil);

  bool isManualHotActiveAt(DateTime now) => isManualHotActive(
    now: now,
    manualHotEnabled: manualHotEnabled,
    manualHotUntil: manualHotUntil,
  );

  bool isHotActiveAt(DateTime now) => isHotActive(
    now: now,
    autoHotUntil: autoHotUntil,
    manualHotEnabled: manualHotEnabled,
    manualHotUntil: manualHotUntil,
  );

  DateTime? hotUntilAt(DateTime now) => effectiveHotUntil(
    now: now,
    autoHotUntil: autoHotUntil,
    manualHotUntil: manualHotEnabled ? manualHotUntil : null,
    manualHotEnabled: manualHotEnabled,
  );

  @override
  String get description => '${updateTime ?? 'Unknown'} | $sourceKey';
}

/// Lightweight scan-candidate row (snapshot row + check-state join), used
/// by the scan queue builder so it never materializes whole folders.
class ScanCandidate {
  const ScanCandidate({
    required this.sourceKey,
    required this.comicId,
    required this.folderId,
    required this.lastCheckTime,
    required this.retryAfter,
    required this.nextCheckTime,
  });

  final String sourceKey;
  final String comicId;
  final String folderId;
  final DateTime? lastCheckTime;
  final DateTime? retryAfter;
  final DateTime? nextCheckTime;
}

/// Strips a trailing " (1234)" count that sources like ehentai embed in
/// favorite folder titles. The number comes from the source API at folder
/// list fetch time and drifts from the actual folder contents (especially
/// right after adding/removing favorites), so it is not shown.
String favoriteFolderDisplayTitle(String title) {
  final match = RegExp(r'\s*\(\d+\)$').firstMatch(title);
  return match == null ? title : title.substring(0, match.start);
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

/// Persisted state of a follow-up scan run, stored as JSON under the
/// metadata key `follow_update_run`.
///
/// `running` runs are resumed by the next scan (the app was killed mid-run);
/// `finished`/`canceled` runs are replaced by a fresh run.
class ScanRunInfo {
  const ScanRunInfo({
    required this.runId,
    required this.mode,
    required this.ignoreRetryAfter,
    required this.total,
    required this.status,
    required this.startedAt,
    this.finishedAt,
  });

  final int runId;

  /// [FollowUpdateMode.name] of the run.
  final String mode;

  final bool ignoreRetryAfter;

  /// Queue length at run creation.
  final int total;

  /// running | finished | canceled
  final String status;

  final DateTime startedAt;

  final DateTime? finishedAt;

  ScanRunInfo copyWith({String? status, DateTime? finishedAt}) {
    return ScanRunInfo(
      runId: runId,
      mode: mode,
      ignoreRetryAfter: ignoreRetryAfter,
      total: total,
      status: status ?? this.status,
      startedAt: startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
    );
  }

  Map<String, Object?> toJson() => {
    'runId': runId,
    'mode': mode,
    'ignoreRetryAfter': ignoreRetryAfter,
    'total': total,
    'status': status,
    'startedAt': startedAt.millisecondsSinceEpoch,
    'finishedAt': finishedAt?.millisecondsSinceEpoch,
  };

  /// Returns null when the metadata is missing or malformed; the caller then
  /// starts a fresh run.
  static ScanRunInfo? fromJson(Object? json) {
    if (json is! String) return null;
    try {
      final map = Map<String, dynamic>.from(jsonDecode(json) as Map);
      final runId = map['runId'];
      final mode = map['mode'];
      final total = map['total'];
      final status = map['status'];
      final startedAt = map['startedAt'];
      if (runId is! int ||
          mode is! String ||
          total is! int ||
          status is! String ||
          startedAt is! int) {
        return null;
      }
      return ScanRunInfo(
        runId: runId,
        mode: mode,
        ignoreRetryAfter: map['ignoreRetryAfter'] as bool? ?? false,
        total: total,
        status: status,
        startedAt: DateTime.fromMillisecondsSinceEpoch(startedAt),
        finishedAt: map['finishedAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(map['finishedAt'] as int),
      );
    } catch (_) {
      return null;
    }
  }
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

class FavoriteUpdateScanState {
  const FavoriteUpdateScanState({
    this.markerScheme,
    this.lastAttemptAt,
    this.lastSuccessAt,
    this.retryAfter,
    this.checkFailures = 0,
    this.lastPageCount = 0,
    this.lastComicCount = 0,
  });

  final String? markerScheme;
  final DateTime? lastAttemptAt;
  final DateTime? lastSuccessAt;
  final DateTime? retryAfter;
  final int checkFailures;
  final int lastPageCount;
  final int lastComicCount;
}

class FavoriteUpdateSnapshotApplyResult {
  const FavoriteUpdateSnapshotApplyResult({
    required this.updatedComicCount,
    required this.pageCount,
    required this.comicCount,
  });

  final int updatedComicCount;
  final int pageCount;
  final int comicCount;

  int get updated => updatedComicCount;
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

/// Minimum time between two not-found hits that both count toward the
/// suspected-removed mark. Hits inside the window are ignored, so a
/// risk-control window that lasts hours cannot compress the evidence.
const Duration kNotFoundHitWindow = Duration(hours: 24);

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
  final Map<String, int> _favoriteSessionEpochs = <String, int>{};
  int _cacheGeneration = 0;
  static const _backgroundRefreshAfter = Duration(minutes: 5);
  static const backgroundSummaryRefreshAfter = Duration(hours: 6);
  static const _followScheduleBackfillKey = 'follow_schedule_state_backfill_v1';
  static const _followScheduleCoreColumns = <String>{
    'baseline_at',
    'source_activity_at',
    'next_check_at',
    'auto_hot_until',
    'manual_hot_until',
    'manual_hot_enabled',
    'old_schedule_jitter_applied',
  };

  /// Pages fetched concurrently per batch by full-cache and summary sweeps.
  static const _fullCacheBatchSize = 3;

  /// Safety valve for full-cache runs on sources that never report a page
  /// count: the walk stops after this many pages instead of looping forever.
  /// Tests shorten this.
  static int fullCacheUnknownTotalCap = 100;

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
    _db.execute('''
      CREATE TABLE IF NOT EXISTS scan_queue (
        run_id INTEGER NOT NULL,
        source_key TEXT NOT NULL,
        comic_id TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        result TEXT,
        error TEXT,
        PRIMARY KEY (run_id, source_key, comic_id)
      );
    ''');
    final hadComicCheckStateTable = _db
        .select(
          "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'comic_check_state' LIMIT 1",
        )
        .isNotEmpty;
    final backfillStatusRows = _db.select(
      'SELECT value FROM metadata WHERE key = ?',
      [_followScheduleBackfillKey],
    );
    final backfillStatus = backfillStatusRows.isEmpty
        ? null
        : backfillStatusRows.first['value'] as String?;
    final pendingWrittenBeforeCreate =
        !hadComicCheckStateTable || backfillStatus == 'pending';
    if (pendingWrittenBeforeCreate) {
      _writeFollowScheduleBackfillStatus('pending');
    }
    _db.execute('''
      CREATE TABLE IF NOT EXISTS comic_check_state (
        source_key TEXT NOT NULL,
        comic_id TEXT NOT NULL,
        last_update_time TEXT,
        update_marker TEXT,
        last_check_time INTEGER,
        has_new_update INTEGER NOT NULL DEFAULT 0,
        retry_after INTEGER,
        check_failures INTEGER NOT NULL DEFAULT 0,
        check_not_found_count INTEGER NOT NULL DEFAULT 0,
        check_suspect_gone INTEGER NOT NULL DEFAULT 0,
        baseline_at INTEGER,
        source_activity_at INTEGER,
        next_check_at INTEGER,
        auto_hot_until INTEGER,
        manual_hot_until INTEGER,
        manual_hot_enabled INTEGER NOT NULL DEFAULT 0,
        old_schedule_jitter_applied INTEGER NOT NULL DEFAULT 0,
        source_update_metadata TEXT,
         PRIMARY KEY (source_key, comic_id)
      );
    ''');
    // Read the actual post-CREATE schema. A brand-new table already contains
    // every current column; do not reuse a pre-CREATE empty set and attempt to
    // add those columns again.
    final checkStateColumns = _db
        .select('PRAGMA table_info(comic_check_state)')
        .map((row) => row['name'] as String)
        .toSet();
    final hasMissingFollowScheduleColumn = _followScheduleCoreColumns.any(
      (column) => !checkStateColumns.contains(column),
    );
    final applyLegacyFollowScheduleBackfill =
        !hadComicCheckStateTable ||
        backfillStatus == 'pending' ||
        (backfillStatus != 'done' && hasMissingFollowScheduleColumn);
    if (applyLegacyFollowScheduleBackfill && !pendingWrittenBeforeCreate) {
      _writeFollowScheduleBackfillStatus('pending');
    }
    final checkStateAdditions = <String, String>{
      'baseline_at': 'INTEGER',
      'source_activity_at': 'INTEGER',
      'next_check_at': 'INTEGER',
      'auto_hot_until': 'INTEGER',
      'manual_hot_until': 'INTEGER',
      'manual_hot_enabled': 'INTEGER NOT NULL DEFAULT 0',
      'old_schedule_jitter_applied': 'INTEGER NOT NULL DEFAULT 0',
      'source_update_metadata': 'TEXT',
    };
    for (final entry in checkStateAdditions.entries) {
      if (!checkStateColumns.contains(entry.key)) {
        _db.execute(
          'ALTER TABLE comic_check_state ADD COLUMN ${entry.key} ${entry.value}',
        );
      }
    }
    _db.execute('''CREATE INDEX IF NOT EXISTS idx_comic_check_state_next_check
         ON comic_check_state(next_check_at)''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS favorite_update_scan_state (
        source_key TEXT NOT NULL,
        folder_id TEXT NOT NULL,
        marker_scheme TEXT,
        last_attempt_at INTEGER,
        last_success_at INTEGER,
        retry_after INTEGER,
        check_failures INTEGER NOT NULL DEFAULT 0,
        last_page_count INTEGER NOT NULL DEFAULT 0,
        last_comic_count INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (source_key, folder_id)
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
    _db.execute('''CREATE INDEX IF NOT EXISTS idx_favorite_items_comic
         ON favorite_items (source_key, folder_id, comic_id)''');
    _rebuildMissingSearchText();
    // One-time migration: check/update state moves from favorite_items rows
    // (which are page snapshots and get rebuilt) to the comic-level table.
    // Only runs while the state table is empty, so a crash mid-migration is
    // safe (the INSERT below is atomic) and later starts never re-apply stale
    // row snapshots over live state.
    final stateExists = _db.select('SELECT 1 FROM comic_check_state LIMIT 1');
    if (stateExists.isEmpty) {
      _db.execute('''
        INSERT INTO comic_check_state
          (source_key, comic_id, last_update_time, update_marker,
           last_check_time, has_new_update, retry_after, check_failures,
           check_not_found_count, check_suspect_gone)
        SELECT source_key, comic_id,
               MAX(CASE WHEN rn = 1 THEN last_update_time END),
               MAX(CASE WHEN rn = 1 THEN update_marker END),
               MAX(last_check_time), MAX(has_new_update), MAX(retry_after),
               MAX(check_failures), MAX(check_not_found_count),
               MAX(check_suspect_gone)
        FROM (
          SELECT fi.source_key, fi.comic_id, fi.last_update_time,
                 fi.update_marker, fi.last_check_time, fi.has_new_update,
                 fi.retry_after, fi.check_failures, fi.check_not_found_count,
                 fi.check_suspect_gone,
                 ROW_NUMBER() OVER (
                   PARTITION BY fi.source_key, fi.comic_id
                   ORDER BY fi.last_check_time DESC
                 ) AS rn
          FROM favorite_items fi
          WHERE fi.last_check_time IS NOT NULL
             OR fi.has_new_update != 0
             OR fi.retry_after IS NOT NULL
             OR fi.check_failures != 0
             OR fi.check_not_found_count != 0
             OR fi.check_suspect_gone != 0
        )
        GROUP BY source_key, comic_id
      ''');
    }
    _migrateFollowScheduleState(
      applyLegacyBackfill: applyLegacyFollowScheduleBackfill,
    );
    if (applyLegacyFollowScheduleBackfill || backfillStatus != 'done') {
      _writeFollowScheduleBackfillStatus('done');
    }
    if (migrateLegacy) {
      await appdata.ensureInit();
      await _migrateLegacyLocalFavorites();
    }
  }

  void _writeFollowScheduleBackfillStatus(String status) {
    _db.execute('INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)', [
      _followScheduleBackfillKey,
      status,
    ]);
  }

  void _migrateFollowScheduleState({required bool applyLegacyBackfill}) {
    final now = DateTime.now();
    final rows = _db.select('SELECT * FROM comic_check_state');
    for (final row in rows) {
      final sourceKey = row['source_key'] as String;
      final comicId = row['comic_id'] as String;
      final oldBaseline = row['baseline_at'] as int?;
      final oldSource = row['source_activity_at'] as int?;
      final oldNext = row['next_check_at'] as int?;
      final oldAuto = row['auto_hot_until'] as int?;
      final oldManualEnabled = (row['manual_hot_enabled'] as int? ?? 0) != 0;
      final oldJitter = (row['old_schedule_jitter_applied'] as int? ?? 0) != 0;
      final manualHotMs = row['manual_hot_until'] as int?;
      final manualEnabled =
          manualHotMs != null &&
          manualHotMs > now.millisecondsSinceEpoch &&
          oldManualEnabled;

      if (!applyLegacyBackfill) {
        if (manualEnabled == oldManualEnabled) continue;
        _db.execute(
          '''UPDATE comic_check_state SET manual_hot_enabled = ?
             WHERE source_key = ? AND comic_id = ?''',
          [manualEnabled ? 1 : 0, sourceKey, comicId],
        );
        continue;
      }

      final lastCheckMs = row['last_check_time'] as int?;
      final baselineMs = oldBaseline ?? lastCheckMs;
      final sourceActivityMs =
          oldSource ??
          parseFollowUpdateActivityTime(
            row['last_update_time'] as String?,
            now: now,
          )?.millisecondsSinceEpoch;
      var autoHotMs = oldAuto;
      if (autoHotMs == null && sourceActivityMs != null) {
        final candidate = DateTime.fromMillisecondsSinceEpoch(
          sourceActivityMs,
        ).add(kFollowUpdateHotWindow);
        if (candidate.isAfter(now)) {
          autoHotMs = candidate.millisecondsSinceEpoch;
        }
      }
      var nextCheckMs = oldNext;
      if (nextCheckMs == null && lastCheckMs != null) {
        // The legacy scheduler considered a row due after 24 hours. Preserve
        // that due point during migration instead of pushing an old row out
        // by a new 7/14-day interval. A due legacy row stays NULL so the SQL
        // candidate query continues to select it immediately. The first
        // successful check will establish the new schedule and apply jitter.
        final legacyDue = DateTime.fromMillisecondsSinceEpoch(
          lastCheckMs,
        ).add(const Duration(hours: 24));
        if (legacyDue.isAfter(now)) {
          nextCheckMs = legacyDue.millisecondsSinceEpoch;
        }
      }
      if (oldBaseline == baselineMs &&
          oldSource == sourceActivityMs &&
          oldNext == nextCheckMs &&
          oldAuto == autoHotMs &&
          oldManualEnabled == manualEnabled) {
        continue;
      }
      _db.execute(
        '''UPDATE comic_check_state
           SET baseline_at = ?, source_activity_at = ?, next_check_at = ?,
               auto_hot_until = ?, manual_hot_enabled = ?,
               old_schedule_jitter_applied = ?
           WHERE source_key = ? AND comic_id = ?''',
        [
          baselineMs,
          sourceActivityMs,
          nextCheckMs,
          autoHotMs,
          manualEnabled ? 1 : 0,
          oldJitter ? 1 : 0,
          sourceKey,
          comicId,
        ],
      );
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
    _invalidateAllFavoriteSessionEpochs();
    _db.execute('BEGIN');
    try {
      _db.execute('DELETE FROM favorite_items');
      _db.execute('DELETE FROM favorite_pages');
      _db.execute('DELETE FROM favorite_folders');
      _db.execute('DELETE FROM favorite_membership');
      _db.execute('DELETE FROM favorite_update_scan_state');
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    _cacheGeneration++;
    _refreshing.clear();
    _fullCaching.clear();
    notifyListeners();
  }

  /// Changes only after [clearAllCache] commits. UI cache-first pages use this
  /// generation to discard their in-memory pages and PageStorage namespace.
  int get cacheGeneration => _cacheGeneration;

  static const _scanRunMetadataKey = 'follow_update_run';

  /// Returns the persisted scan run, or null when there is none (or its JSON
  /// is malformed, which is treated as "no run").
  ScanRunInfo? getCurrentScanRun() {
    final rows = _db.select('SELECT value FROM metadata WHERE key = ?', [
      _scanRunMetadataKey,
    ]);
    if (rows.isEmpty) return null;
    return ScanRunInfo.fromJson(rows.first['value']);
  }

  /// Clears any previous run (finished/canceled) and persists a fresh running
  /// run with its queue.
  ScanRunInfo createScanRun({
    required String mode,
    required bool ignoreRetryAfter,
    required int total,
    required List<(String, String)> items,
  }) {
    clearScanRun();
    final runId = DateTime.now().millisecondsSinceEpoch;
    _db.execute('BEGIN');
    try {
      for (final (sourceKey, comicId) in items) {
        _db.execute(
          '''INSERT OR REPLACE INTO scan_queue (run_id, source_key, comic_id, status)
             VALUES (?, ?, ?, 'pending')''',
          [runId, sourceKey, comicId],
        );
      }
      _db.execute(
        'INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)',
        [
          _scanRunMetadataKey,
          jsonEncode(
            ScanRunInfo(
              runId: runId,
              mode: mode,
              ignoreRetryAfter: ignoreRetryAfter,
              total: total,
              status: 'running',
              startedAt: DateTime.now(),
            ).toJson(),
          ),
        ],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return getCurrentScanRun()!;
  }

  /// Keys of the items already processed by [runId], as
  /// `'sourceKey\u0000comicId'`.
  Set<String> getDoneScanItems(int runId) {
    final rows = _db.select(
      '''SELECT source_key, comic_id FROM scan_queue
         WHERE run_id = ? AND status = 'done' ''',
      [runId],
    );
    return rows.map((r) => '${r['source_key']}\u0000${r['comic_id']}').toSet();
  }

  /// All keys queued for [runId] (pending or done), as
  /// `'sourceKey\u0000comicId'`.
  Set<String> getScanRunKeys(int runId) {
    final rows = _db.select(
      '''SELECT source_key, comic_id FROM scan_queue
         WHERE run_id = ?''',
      [runId],
    );
    return rows.map((r) => '${r['source_key']}\u0000${r['comic_id']}').toSet();
  }

  /// Completes stale detail queue rows for sources that now declare the list
  /// strategy, so an interrupted pre-migration run cannot request details.
  void markListStrategyScanItemsSkipped(
    int runId,
    Iterable<String> sourceKeys,
  ) {
    final keys = sourceKeys.toSet().toList();
    if (keys.isEmpty) return;
    final placeholders = keys.map((_) => '?').join(', ');
    _db.execute(
      '''UPDATE scan_queue
         SET status = 'done', result = 'skipped', error = NULL
         WHERE run_id = ? AND source_key IN ($placeholders)
           AND status = 'pending' ''',
      [runId, ...keys],
    );
  }

  /// Inserts [items] into [runId]'s queue as pending. Used when a resumed run
  /// re-builds its queue from the current cache and finds comics that were
  /// cached after the original run was persisted, so a second interruption
  /// excludes them via the done-set like every other item.
  void addScanRunItems(int runId, List<(String, String)> items) {
    if (items.isEmpty) return;
    _db.execute('BEGIN');
    try {
      for (final (sourceKey, comicId) in items) {
        _db.execute(
          '''INSERT OR IGNORE INTO scan_queue (run_id, source_key, comic_id, status)
             VALUES (?, ?, ?, 'pending')''',
          [runId, sourceKey, comicId],
        );
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void markScanItemDone(
    int runId,
    String sourceKey,
    String comicId, {
    required String result,
    String? error,
  }) {
    _db.execute(
      '''UPDATE scan_queue SET status = 'done', result = ?, error = ?
         WHERE run_id = ? AND source_key = ? AND comic_id = ?''',
      [result, error, runId, sourceKey, comicId],
    );
  }

  void updateScanRunStatus(int runId, String status) {
    final info = getCurrentScanRun();
    if (info == null || info.runId != runId) return;
    _db.execute('INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)', [
      _scanRunMetadataKey,
      jsonEncode(
        info
            .copyWith(
              status: status,
              finishedAt: status == 'finished'
                  ? DateTime.now()
                  : info.finishedAt,
            )
            .toJson(),
      ),
    ]);
  }

  void clearScanRun() {
    _db.execute('DELETE FROM scan_queue');
    _db.execute('DELETE FROM metadata WHERE key = ?', [_scanRunMetadataKey]);
  }

  /// Folder refs of every folder known to contain [comicId]; falls back to
  /// [fallback] when the membership table has no entry (e.g. single-folder
  /// sources that never refresh folders).
  List<NetworkFavoriteFolderRef> _comicFolders(
    NetworkFavoriteFolderRef fallback,
    String comicId,
  ) {
    final ids = getKnownFolderIds(fallback.sourceKey, comicId);
    if (ids.isEmpty) return [fallback];
    return [
      for (final id in ids)
        NetworkFavoriteFolderRef(sourceKey: fallback.sourceKey, folderId: id),
    ];
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

  /// Makes sure [folder] has a row in `favorite_folders`.
  ///
  /// Single-folder sources cache pages directly without calling
  /// [refreshFolders], so without this the folder would never be picked up
  /// by follow-up queries (`getFollowUpdateFolders`) even though its comics
  /// are cached.
  void _ensureFolder(NetworkFavoriteFolderRef folder) {
    final rows = _db.select(
      'SELECT 1 FROM favorite_folders WHERE source_key = ? AND folder_id = ?',
      [folder.sourceKey, folder.folderId],
    );
    if (rows.isEmpty) {
      _db.execute(
        '''INSERT INTO favorite_folders
           (source_key, folder_id, title, updated_at) VALUES (?, ?, ?, ?)''',
        [
          folder.sourceKey,
          folder.folderId,
          folder.title ?? '',
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
    }
  }

  FavoriteUpdateScanState? getFavoriteUpdateScanState(
    NetworkFavoriteFolderRef folder,
  ) {
    final rows = _db.select(
      '''SELECT * FROM favorite_update_scan_state
         WHERE source_key = ? AND folder_id = ?''',
      [folder.sourceKey, folder.folderId],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return FavoriteUpdateScanState(
      markerScheme: row['marker_scheme'] as String?,
      lastAttemptAt: _dateTimeFromRow(row['last_attempt_at']),
      lastSuccessAt: _dateTimeFromRow(row['last_success_at']),
      retryAfter: _dateTimeFromRow(row['retry_after']),
      checkFailures: row['check_failures'] as int? ?? 0,
      lastPageCount: row['last_page_count'] as int? ?? 0,
      lastComicCount: row['last_comic_count'] as int? ?? 0,
    );
  }

  void recordFavoriteUpdateScanAttempt(
    NetworkFavoriteFolderRef folder, {
    DateTime? attemptedAt,
  }) {
    final at = (attemptedAt ?? DateTime.now()).millisecondsSinceEpoch;
    _db.execute(
      '''INSERT INTO favorite_update_scan_state
           (source_key, folder_id, last_attempt_at)
         VALUES (?, ?, ?)
         ON CONFLICT(source_key, folder_id) DO UPDATE SET
           last_attempt_at = excluded.last_attempt_at''',
      [folder.sourceKey, folder.folderId, at],
    );
  }

  void recordFavoriteUpdateScanFailure(
    NetworkFavoriteFolderRef folder, {
    DateTime? failedAt,
  }) {
    final now = failedAt ?? DateTime.now();
    final existing = getFavoriteUpdateScanState(folder);
    final failures = (existing?.checkFailures ?? 0) + 1;
    final delay = switch (failures) {
      1 => const Duration(hours: 1),
      2 => const Duration(hours: 6),
      3 => const Duration(hours: 24),
      _ => const Duration(days: 7),
    };
    _db.execute(
      '''INSERT INTO favorite_update_scan_state
           (source_key, folder_id, last_attempt_at, retry_after, check_failures)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(source_key, folder_id) DO UPDATE SET
           last_attempt_at = excluded.last_attempt_at,
           retry_after = excluded.retry_after,
           check_failures = excluded.check_failures''',
      [
        folder.sourceKey,
        folder.folderId,
        now.millisecondsSinceEpoch,
        now.add(delay).millisecondsSinceEpoch,
        failures,
      ],
    );
  }

  String? _favoriteUpdateMetadataJson(FavoriteUpdateHint hint) {
    final metadata = <String, dynamic>{};
    if (hint.metadata != null) {
      try {
        metadata.addAll(hint.metadata!);
      } catch (e) {
        Log.warning('FavoriteUpdate', 'Dropped invalid source metadata: $e');
      }
    }
    // isNew is a diagnostic field, not authoritative update evidence.
    metadata['isNew'] = hint.isNew;
    try {
      final encoded = jsonEncode(metadata);
      if (encoded.length > 4096) {
        Log.warning(
          'FavoriteUpdate',
          'Dropped source metadata exceeding the 4096 UTF-16 code-unit limit',
        );
        return jsonEncode({'isNew': hint.isNew});
      }
      return encoded;
    } catch (e) {
      Log.warning('FavoriteUpdate', 'Dropped invalid source metadata: $e');
      return jsonEncode({'isNew': hint.isNew});
    }
  }

  bool _applyFavoriteUpdateHint(
    NetworkFavoriteFolderRef folder, {
    required FavoriteUpdateCheckData updateCheck,
    required String comicId,
    required FavoriteUpdateHint hint,
    required DateTime completedAt,
  }) {
    final candidateActivity = parseFollowUpdateActivityTime(
      hint.updateTime,
      now: completedAt,
    );
    final candidateMarker = encodeFollowUpdateMarker(
      updateCheck.markerScheme,
      hint.marker,
    );
    final rows = _db.select(
      '''SELECT * FROM comic_check_state
         WHERE source_key = ? AND comic_id = ? LIMIT 1''',
      [folder.sourceKey, comicId],
    );
    final previous = rows.isEmpty ? null : rows.first;
    final previousMarker = previous?['update_marker'] as String?;
    final previousHasMarker =
        previousMarker != null && previousMarker.isNotEmpty;
    final previousParts = previousHasMarker
        ? decodeFollowUpdateMarker(previousMarker)
        : null;
    final candidateParts = decodeFollowUpdateMarker(candidateMarker);
    final previousActivity = (previous?['last_update_time'] as String?) == null
        ? null
        : parseFollowUpdateActivityTime(
            previous!['last_update_time'] as String,
            now: completedAt,
          );
    final effectivePreviousActivity =
        previousActivity ?? _dateTimeFromRow(previous?['source_activity_at']);
    final schemeChanged =
        previousParts != null && previousParts.scheme != candidateParts.scheme;
    final sameScheme = previousParts != null && !schemeChanged;
    final candidateIsOlder =
        sameScheme &&
        effectivePreviousActivity != null &&
        candidateActivity != null &&
        candidateActivity.isBefore(effectivePreviousActivity);
    final markerSame = previousMarker == candidateMarker;
    final accepted =
        !previousHasMarker ||
        schemeChanged ||
        (!candidateIsOlder && !markerSame);
    final markerChanged = accepted && previousHasMarker && !schemeChanged;
    final remotePositive = hint.isNew == true;
    final detected = !previousHasMarker || schemeChanged
        ? remotePositive
        : markerChanged;
    final previousHasNew = (previous?['has_new_update'] as int? ?? 0) != 0;
    final baseline = _dateTimeFromRow(previous?['baseline_at']) ?? completedAt;
    final acceptedLastUpdateTime = accepted
        ? hint.updateTime
        : previous?['last_update_time'];
    final acceptedSourceActivity = accepted
        ? candidateActivity
        : _dateTimeFromRow(previous?['source_activity_at']);
    final sourceMetadata = _favoriteUpdateMetadataJson(hint);
    _db.execute(
      '''INSERT INTO comic_check_state
           (source_key, comic_id, last_update_time, update_marker,
            last_check_time, has_new_update, retry_after, check_failures,
            check_not_found_count, check_suspect_gone, baseline_at,
            source_activity_at, next_check_at, auto_hot_until,
            manual_hot_until, manual_hot_enabled, old_schedule_jitter_applied,
            source_update_metadata)
         VALUES (?, ?, ?, ?, ?, ?, NULL, 0, 0, 0, ?, ?, NULL, NULL, NULL, 0, 0, ?)
         ON CONFLICT(source_key, comic_id) DO UPDATE SET
           last_update_time = excluded.last_update_time,
           update_marker = excluded.update_marker,
           last_check_time = excluded.last_check_time,
           has_new_update = excluded.has_new_update,
           retry_after = NULL,
           check_failures = 0,
           check_not_found_count = 0,
           check_suspect_gone = 0,
           baseline_at = excluded.baseline_at,
           source_activity_at = excluded.source_activity_at,
           next_check_at = NULL,
           auto_hot_until = NULL,
           manual_hot_until = NULL,
           manual_hot_enabled = 0,
           old_schedule_jitter_applied = 0,
           source_update_metadata = excluded.source_update_metadata''',
      [
        folder.sourceKey,
        comicId,
        acceptedLastUpdateTime,
        accepted ? candidateMarker : previousMarker,
        completedAt.millisecondsSinceEpoch,
        (previousHasNew || detected) ? 1 : 0,
        baseline.millisecondsSinceEpoch,
        acceptedSourceActivity?.millisecondsSinceEpoch,
        sourceMetadata,
      ],
    );
    return detected;
  }

  void _validateFavoriteUpdateSnapshot(
    FavoriteData data,
    NetworkFavoriteFolderRef folder,
    FavoriteUpdateSnapshot snapshot,
    DateTime completedAt,
  ) {
    final updateCheck = data.updateCheck;
    if (updateCheck == null) {
      throw StateError('Favorite source does not support list update checks');
    }
    if (folder.sourceKey != data.key ||
        snapshot.pageSize < 1 ||
        snapshot.pageSize > 200 ||
        snapshot.total != snapshot.comics.length) {
      throw StateError('Invalid favorite update snapshot shape');
    }
    final ids = <String>{};
    for (final comic in snapshot.comics) {
      if (comic.sourceKey != data.key ||
          comic.id.trim().isEmpty ||
          !ids.add(comic.id)) {
        throw StateError('Invalid or duplicate comic ID in update snapshot');
      }
      final hint = comic.favoriteUpdate;
      if (hint == null ||
          hint.marker.trim().isEmpty ||
          (hint.updateTime != null &&
              (hint.updateTime!.trim().isEmpty ||
                  parseFollowUpdateActivityTime(
                        hint.updateTime,
                        now: completedAt,
                      ) ==
                      null))) {
        throw StateError('Invalid full update evidence for ${comic.id}');
      }
      // Validate the diagnostic payload before starting the transaction.
      _favoriteUpdateMetadataJson(hint);
    }
  }

  FavoriteUpdateSnapshotApplyResult applyCompleteFavoriteUpdateSnapshot(
    FavoriteData data,
    NetworkFavoriteFolderRef folder,
    FavoriteUpdateSnapshot snapshot, {
    required DateTime completedAt,
  }) {
    _validateFavoriteUpdateSnapshot(data, folder, snapshot, completedAt);
    final updateCheck = data.updateCheck!;
    final oldRows = _db.select(
      '''SELECT * FROM favorite_items
         WHERE source_key = ? AND folder_id = ?''',
      [folder.sourceKey, folder.folderId],
    );
    final oldItems = <String, FavoriteItem>{};
    for (final row in oldRows) {
      oldItems.putIfAbsent(
        row['comic_id'] as String,
        () => FavoriteItem.fromRow(row),
      );
    }
    final pageCount = snapshot.comics.isEmpty
        ? 0
        : (snapshot.comics.length + snapshot.pageSize - 1) ~/ snapshot.pageSize;
    final lastAttemptAt =
        getFavoriteUpdateScanState(folder)?.lastAttemptAt ?? completedAt;
    var updatedComicCount = 0;
    _db.execute('BEGIN');
    try {
      _ensureFolder(folder);
      _db.execute(
        '''DELETE FROM favorite_items WHERE source_key = ? AND folder_id = ?''',
        [folder.sourceKey, folder.folderId],
      );
      _db.execute(
        '''DELETE FROM favorite_pages WHERE source_key = ? AND folder_id = ?''',
        [folder.sourceKey, folder.folderId],
      );
      for (var page = 1; page <= pageCount; page++) {
        final start = (page - 1) * snapshot.pageSize;
        final pageComics = snapshot.comics
            .skip(start)
            .take(snapshot.pageSize)
            .toList();
        _db.execute(
          '''INSERT INTO favorite_pages
             (source_key, folder_id, page_index, request_token, next_token,
              max_page, updated_at)
             VALUES (?, ?, ?, ?, NULL, ?, ?)''',
          [
            folder.sourceKey,
            folder.folderId,
            page,
            'page:$page',
            pageCount,
            completedAt.millisecondsSinceEpoch,
          ],
        );
        for (var index = 0; index < pageComics.length; index++) {
          final comic = pageComics[index];
          final hint = comic.favoriteUpdate;
          final remoteItem = FavoriteItem.fromComic(comic);
          final previousItem = oldItems[remoteItem.id];
          final previousFavoriteTime = previousItem == null
              ? null
              : DateTime.tryParse(previousItem.time.replaceFirst(' ', 'T'));
          final item = FavoriteItem(
            id: remoteItem.id,
            name: remoteItem.name,
            coverPath: previousItem?.coverPath ?? remoteItem.coverPath,
            author: remoteItem.author,
            sourceKeyValue: remoteItem.sourceKey,
            tags: remoteItem.tags,
            chapterCount: remoteItem.chapterCount ?? previousItem?.chapterCount,
            remoteFavoriteId: remoteItem.favoriteId,
            favoriteTime: previousFavoriteTime,
          );
          final itemJson = item.toCacheJson();
          _db.execute(
            '''INSERT INTO favorite_items
               (source_key, folder_id, page_index, comic_id, display_order,
                comic_json, favorite_id, favorite_time, search_text)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
            [
              folder.sourceKey,
              folder.folderId,
              page,
              item.id,
              index,
              jsonEncode(itemJson),
              item.favoriteId,
              item.time,
              _buildSearchText(item.id, itemJson),
            ],
          );
          if (_applyFavoriteUpdateHint(
            folder,
            updateCheck: updateCheck,
            comicId: item.id,
            hint: hint!,
            completedAt: completedAt,
          )) {
            updatedComicCount++;
          }
        }
      }
      _rebuildMembership(folder);
      _db.execute(
        '''UPDATE favorite_folders
           SET updated_at = ?, full_cache_at = ?, full_cache_pages = ?,
               full_cache_comics = ?
           WHERE source_key = ? AND folder_id = ?''',
        [
          completedAt.millisecondsSinceEpoch,
          completedAt.millisecondsSinceEpoch,
          pageCount,
          snapshot.comics.length,
          folder.sourceKey,
          folder.folderId,
        ],
      );
      _db.execute(
        '''INSERT INTO favorite_update_scan_state
             (source_key, folder_id, marker_scheme, last_attempt_at,
              last_success_at, retry_after, check_failures,
              last_page_count, last_comic_count)
           VALUES (?, ?, ?, ?, ?, NULL, 0, ?, ?)
           ON CONFLICT(source_key, folder_id) DO UPDATE SET
             marker_scheme = excluded.marker_scheme,
             last_attempt_at = excluded.last_attempt_at,
             last_success_at = excluded.last_success_at,
             retry_after = NULL,
             check_failures = 0,
             last_page_count = excluded.last_page_count,
             last_comic_count = excluded.last_comic_count''',
        [
          folder.sourceKey,
          folder.folderId,
          updateCheck.markerScheme,
          lastAttemptAt.millisecondsSinceEpoch,
          completedAt.millisecondsSinceEpoch,
          pageCount,
          snapshot.comics.length,
        ],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    notifyListeners();
    return FavoriteUpdateSnapshotApplyResult(
      updatedComicCount: updatedComicCount,
      pageCount: pageCount,
      comicCount: snapshot.comics.length,
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
    final expectedEpoch = data.updateCheck == null
        ? null
        : captureFavoriteSessionEpoch(folder.sourceKey);
    final result = await data.loadComic!(page, folder.folderId);
    if (expectedEpoch != null &&
        !isFavoriteSessionEpochCurrent(folder.sourceKey, expectedEpoch)) {
      return const Res.error('Favorite session changed');
    }
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
          updateCheck: data.updateCheck,
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
    final expectedEpoch = data.updateCheck == null
        ? null
        : captureFavoriteSessionEpoch(folder.sourceKey);
    final result = await data.loadNext!(requestToken, folder.folderId);
    if (expectedEpoch != null &&
        !isFavoriteSessionEpochCurrent(folder.sourceKey, expectedEpoch)) {
      return const Res.error('Favorite session changed');
    }
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
          updateCheck: data.updateCheck,
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
    required FavoriteUpdateCheckData? updateCheck,
  }) {
    final now = DateTime.now();
    _db.execute('BEGIN');
    try {
      _ensureFolder(folder);
      final updateState = <String, FavoriteItem>{};
      for (final row in _db.select(
        '''SELECT source_key, comic_id, comic_json, favorite_id, favorite_time
           FROM favorite_items
           WHERE source_key = ? AND folder_id = ? AND page_index = ?''',
        [folder.sourceKey, folder.folderId, pageIndex],
      )) {
        updateState[row['comic_id'] as String] = FavoriteItem.fromRow(row);
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
        final comic = comics[index];
        final hint = comic.favoriteUpdate;
        final remoteItem = FavoriteItem.fromComic(comic);
        if (!seenIds.add(remoteItem.id)) continue;
        final previousItem = updateState[remoteItem.id];
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
               favorite_id, favorite_time, search_text)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
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
          ],
        );
        if (updateCheck != null && remoteItem.id.isNotEmpty) {
          if (hint != null && hint.marker.trim().isNotEmpty) {
            try {
              _applyFavoriteUpdateHint(
                folder,
                updateCheck: updateCheck,
                comicId: item.id,
                hint: hint,
                completedAt: now,
              );
            } catch (e) {
              Log.warning(
                'Favorite page refresh',
                'Ignoring invalid update hint for ${item.id}: $e',
              );
            }
          }
        }
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
  /// [timeBudget] time-boxes the sweep: when the budget runs out the loop
  /// stops at the next page boundary and already-refreshed pages stay
  /// committed; the next call picks up the stale remainder. Without a budget
  /// the sweep refreshes every stale page.
  Future<void> refreshCachedSummaries(
    FavoriteData data, {
    Duration minimumAge = backgroundSummaryRefreshAfter,
    Duration? timeBudget,
  }) async {
    if (data.updateCheck != null) return;
    final deadline = timeBudget == null ? null : DateTime.now().add(timeBudget);
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
      if (deadline != null && DateTime.now().isAfter(deadline)) return;
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
        // Refresh a few pages concurrently per batch; large folders otherwise
        // stall on one request at a time. The staleness check and the cache
        // re-read stay inside each batch entry.
        for (var i = 0; i < pages.length; i += _fullCacheBatchSize) {
          if (deadline != null && DateTime.now().isAfter(deadline)) return;
          await Future.wait([
            for (final page in pages.skip(i).take(_fullCacheBatchSize))
              () async {
                final cached = getCachedPage(folder, page);
                if (cached == null ||
                    DateTime.now().difference(cached.updatedAt) < minimumAge) {
                  return;
                }
                await refreshPage(
                  data,
                  folder,
                  page,
                  preserveExistingCover: true,
                );
              }(),
          ]);
        }
      } else if (data.loadNext != null) {
        String? token;
        while (true) {
          if (deadline != null && DateTime.now().isAfter(deadline)) return;
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

  /// Acquires the folder-level mutex shared by complete list scans and the
  /// user-triggered "cache all" operation. The caller must release it with
  /// [releaseFullCacheLock] in a `finally` block.
  bool tryAcquireFullCacheLock(NetworkFavoriteFolderRef folder) =>
      _fullCaching.add(_folderCacheKey(folder));

  void releaseFullCacheLock(NetworkFavoriteFolderRef folder) {
    _fullCaching.remove(_folderCacheKey(folder));
  }

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
    if (!tryAcquireFullCacheLock(folder)) {
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
        if (data.updateCheck != null) {
          await _cacheAllListSnapshot(data, folder, stream, isCanceled);
        } else if (data.loadComic != null) {
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
        releaseFullCacheLock(folder);
        await stream.close();
      }
    }();
    return stream.stream;
  }

  Future<void> _cacheAllListSnapshot(
    FavoriteData data,
    NetworkFavoriteFolderRef folder,
    StreamController<FavoriteFullCacheProgress> stream,
    bool Function() isCanceled,
  ) async {
    if (isCanceled()) {
      stream.add(
        const FavoriteFullCacheProgress(
          pagesCached: 0,
          comicsCached: 0,
          isCanceled: true,
        ),
      );
      return;
    }
    final expectedEpoch = captureFavoriteSessionEpoch(folder.sourceKey);
    void emitCanceled() {
      stream.add(
        FavoriteFullCacheProgress(
          pagesCached: 0,
          comicsCached: countCachedComics(folder),
          isCanceled: true,
        ),
      );
    }

    final attemptedAt = DateTime.now();
    recordFavoriteUpdateScanAttempt(folder, attemptedAt: attemptedAt);
    try {
      final result = await data.updateCheck!.load(folder.folderId);
      if (isCanceled() ||
          !isFavoriteSessionEpochCurrent(folder.sourceKey, expectedEpoch)) {
        emitCanceled();
        return;
      }
      if (result.error) {
        recordFavoriteUpdateScanFailure(folder);
        stream.add(
          FavoriteFullCacheProgress(
            pagesCached: 0,
            comicsCached: countCachedComics(folder),
            errorMessage: result.errorMessage,
          ),
        );
        return;
      }
      if (isCanceled() ||
          !isFavoriteSessionEpochCurrent(folder.sourceKey, expectedEpoch)) {
        emitCanceled();
        return;
      }
      final completed = DateTime.now();
      final applied = applyCompleteFavoriteUpdateSnapshot(
        data,
        folder,
        result.data,
        completedAt: completed,
      );
      stream.add(
        FavoriteFullCacheProgress(
          pagesCached: applied.pageCount,
          comicsCached: applied.comicCount,
          totalPages: applied.pageCount,
          isComplete: true,
        ),
      );
    } catch (e) {
      if (isCanceled() ||
          !isFavoriteSessionEpochCurrent(folder.sourceKey, expectedEpoch)) {
        emitCanceled();
        return;
      }
      recordFavoriteUpdateScanFailure(folder);
      stream.add(
        FavoriteFullCacheProgress(
          pagesCached: 0,
          comicsCached: countCachedComics(folder),
          errorMessage: e.toString(),
        ),
      );
    }
  }

  Future<void> _cacheAllNumberedPages(
    FavoriteData data,
    NetworkFavoriteFolderRef folder,
    StreamController<FavoriteFullCacheProgress> stream,
    bool Function() isCanceled,
  ) async {
    if (isCanceled()) {
      stream.add(
        FavoriteFullCacheProgress(
          pagesCached: 0,
          comicsCached: countCachedComics(folder),
          isCanceled: true,
        ),
      );
      return;
    }
    // Page 1 must land first: it reveals the total page count (or its
    // absence). Every later page is independent, so the rest is fetched in
    // concurrent batches.
    final first = await refreshPage(
      data,
      folder,
      1,
      preserveExistingCover: true,
    );
    if (first.error) {
      stream.add(
        FavoriteFullCacheProgress(
          pagesCached: 0,
          comicsCached: countCachedComics(folder),
          errorMessage: first.errorMessage,
        ),
      );
      return;
    }
    final totalPages = first.data.maxPage;
    if (totalPages == null) {
      // Some sources never report a page count; walk to the end instead of
      // giving up (see _cacheNumberedWalk).
      await _cacheNumberedWalk(data, folder, stream, isCanceled, first.data);
      return;
    }
    stream.add(
      FavoriteFullCacheProgress(
        pagesCached: 1,
        comicsCached: countCachedComics(folder),
        totalPages: totalPages,
      ),
    );
    await _cacheNumberedSweep(data, folder, stream, isCanceled, 2, totalPages);
  }

  /// Fetches pages [startPage]..[totalPages] concurrently, three at a time.
  /// Each completed page emits its own progress event; the first error
  /// aborts the sweep (pages already committed are kept) and the folder is
  /// marked complete only after the last page succeeds.
  Future<void> _cacheNumberedSweep(
    FavoriteData data,
    NetworkFavoriteFolderRef folder,
    StreamController<FavoriteFullCacheProgress> stream,
    bool Function() isCanceled,
    int startPage,
    int totalPages,
  ) async {
    var completed = startPage - 1;
    for (
      var next = startPage;
      next <= totalPages;
      next += _fullCacheBatchSize
    ) {
      if (isCanceled()) {
        stream.add(
          FavoriteFullCacheProgress(
            pagesCached: completed,
            comicsCached: countCachedComics(folder),
            totalPages: totalPages,
            isCanceled: true,
          ),
        );
        return;
      }
      final last = math.min(next + _fullCacheBatchSize - 1, totalPages);
      final results = await Future.wait([
        for (var p = next; p <= last; p++)
          refreshPage(data, folder, p, preserveExistingCover: true),
      ]);
      for (final result in results) {
        if (result.error) {
          stream.add(
            FavoriteFullCacheProgress(
              pagesCached: completed,
              comicsCached: countCachedComics(folder),
              totalPages: totalPages,
              errorMessage: result.errorMessage,
            ),
          );
          return;
        }
        completed++;
        stream.add(
          FavoriteFullCacheProgress(
            pagesCached: completed,
            comicsCached: countCachedComics(folder),
            totalPages: totalPages,
          ),
        );
      }
    }
    final comicsCached = countCachedComics(folder);
    _markFullCacheComplete(folder, totalPages, comicsCached);
    stream.add(
      FavoriteFullCacheProgress(
        pagesCached: totalPages,
        comicsCached: comicsCached,
        totalPages: totalPages,
        isComplete: true,
      ),
    );
  }

  /// Walks a source that never reports a page count. The end can only be
  /// discovered by fetching, so pages are fetched in the same concurrent
  /// batches as the numbered sweep. The walk ends at the first empty page
  /// (dropped again, together with any pages after it in the same batch), a
  /// page repeating the previous page's comic ids (sources that clamp their
  /// tail), or [fullCacheUnknownTotalCap] pages as a safety valve. Completed
  /// pages are kept and the folder is marked complete at the last non-empty
  /// page.
  Future<void> _cacheNumberedWalk(
    FavoriteData data,
    NetworkFavoriteFolderRef folder,
    StreamController<FavoriteFullCacheProgress> stream,
    bool Function() isCanceled,
    CachedFavoritePage firstPage,
  ) async {
    if (firstPage.comics.isEmpty) {
      // An empty first page means an empty folder; drop the empty page row
      // and complete with zero pages.
      _deletePageRows(folder, 1);
      _markFullCacheComplete(folder, 0, 0);
      stream.add(
        const FavoriteFullCacheProgress(
          pagesCached: 0,
          comicsCached: 0,
          isComplete: true,
        ),
      );
      return;
    }
    var lastNonEmpty = 1;
    var previousIds = {for (final c in firstPage.comics) c.id};
    var page = 2;
    var terminated = false;
    while (page <= fullCacheUnknownTotalCap && !terminated) {
      if (isCanceled()) {
        stream.add(
          FavoriteFullCacheProgress(
            pagesCached: lastNonEmpty,
            comicsCached: countCachedComics(folder),
            isCanceled: true,
          ),
        );
        return;
      }
      final last = math.min(
        page + _fullCacheBatchSize - 1,
        fullCacheUnknownTotalCap,
      );
      final results = await Future.wait([
        for (var p = page; p <= last; p++)
          refreshPage(data, folder, p, preserveExistingCover: true),
      ]);
      // Results keep input order, so repeat detection compares against the
      // page that precedes each entry even when requests finish out of order.
      for (var i = 0; i < results.length; i++) {
        final current = page + i;
        final result = results[i];
        if (result.error) {
          stream.add(
            FavoriteFullCacheProgress(
              pagesCached: lastNonEmpty,
              comicsCached: countCachedComics(folder),
              errorMessage: result.errorMessage,
            ),
          );
          return;
        }
        if (result.data.comics.isEmpty) {
          // Terminal page: drop it and anything fetched after it in this
          // batch, so the cache ends at the last real page.
          for (var p = current; p <= last; p++) {
            _deletePageRows(folder, p);
          }
          terminated = true;
          break;
        }
        final ids = {for (final c in result.data.comics) c.id};
        if (ids.length == previousIds.length && ids.containsAll(previousIds)) {
          // The source repeats the last page forever; nothing new beyond
          // here. The duplicate page is harmless and stays.
          terminated = true;
          break;
        }
        previousIds = ids;
        lastNonEmpty = current;
        stream.add(
          FavoriteFullCacheProgress(
            pagesCached: current,
            comicsCached: countCachedComics(folder),
          ),
        );
      }
      page = last + 1;
    }
    if (page > fullCacheUnknownTotalCap) {
      stream.add(
        FavoriteFullCacheProgress(
          pagesCached: lastNonEmpty,
          comicsCached: countCachedComics(folder),
          errorMessage:
              'Favorite source did not provide a page count (stopped after '
              '$fullCacheUnknownTotalCap pages)',
        ),
      );
      return;
    }
    final comicsCached = countCachedComics(folder);
    _markFullCacheComplete(folder, lastNonEmpty, comicsCached);
    stream.add(
      FavoriteFullCacheProgress(
        pagesCached: lastNonEmpty,
        comicsCached: comicsCached,
        isComplete: true,
      ),
    );
  }

  void _deletePageRows(NetworkFavoriteFolderRef folder, int pageIndex) {
    _db.execute(
      'DELETE FROM favorite_items '
      'WHERE source_key = ? AND folder_id = ? AND page_index = ?',
      [folder.sourceKey, folder.folderId, pageIndex],
    );
    _db.execute(
      'DELETE FROM favorite_pages '
      'WHERE source_key = ? AND folder_id = ? AND page_index = ?',
      [folder.sourceKey, folder.folderId, pageIndex],
    );
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
    var effectiveFavoriteId = isAdding
        ? favoriteId
        : favoriteId ??
              _cachedFavoriteId(folder.sourceKey, folder.folderId, comicId);
    if (!isAdding && effectiveFavoriteId == null) {
      // Items added through the app only exist in favorite_membership; the
      // source-side favorite id lives in favorite_items, which is populated
      // from the server list pages. Refresh the folder's first page once (a
      // just-added comic is the most recent one) so removal works for
      // sources that require the favorite id. Best effort: if the refresh
      // fails or the comic is not on the first page, removal proceeds
      // without the id as before.
      final refreshed = data.loadComic != null
          ? await refreshPage(data, folder, 1)
          : data.loadNext != null
          ? await refreshNextPage(data, folder, null)
          : null;
      if (refreshed != null && refreshed.success) {
        effectiveFavoriteId = _cachedFavoriteId(
          folder.sourceKey,
          folder.folderId,
          comicId,
        );
      }
    }
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
      'DELETE FROM favorite_update_scan_state WHERE source_key = ? AND folder_id = ?',
      [sourceKey, folderId],
    );
    _db.execute(
      'DELETE FROM favorite_folders WHERE source_key = ? AND folder_id = ?',
      [sourceKey, folderId],
    );
  }

  /// Loads the comic-level check state for every source touched by [rows].
  /// Keyed by `'sourceKey\u0000comicId'`; a missing key means "never checked".
  Map<String, Map<String, Object?>> _checkStateMap(Set<String> sourceKeys) {
    final map = <String, Map<String, Object?>>{};
    final keys = sourceKeys.toList();
    if (keys.isEmpty) return map;
    final placeholders = keys.map((_) => '?').join(', ');
    for (final row in _db.select(
      'SELECT * FROM comic_check_state WHERE source_key IN ($placeholders)',
      keys,
    )) {
      map['${row['source_key']}\u0000${row['comic_id']}'] = row;
    }
    return map;
  }

  Map<String, Map<String, Object?>> _checkStateForRows(List<Row> rows) =>
      _checkStateMap({for (final row in rows) row['source_key'] as String});

  /// Scan-eligible comics across [folders], filtered in SQL exactly like the
  /// old Dart-side filtering: suspect skip (unless [includeSuspect]), the
  /// [modeName] time window ('missing' = never checked, 'regular' = due by
  /// schedule, 'force' = everything) and the retry-after cooldown. The mode
  /// is passed as a string so this library never needs to import the scan
  /// runner.
  ///
  /// One row per (source, comic, folder); comics appearing in several
  /// folders are deduplicated by the queue builder, not here.
  List<ScanCandidate> getScanCandidates(
    List<NetworkFavoriteFolderRef> folders, {
    required String modeName,
    required bool ignoreRetryAfter,
    required bool includeSuspect,
    DateTime? now,
  }) {
    if (folders.isEmpty) return const [];
    final current = now ?? DateTime.now();
    final nowMs = current.millisecondsSinceEpoch;
    final where = <String>[_folderWhereClause(folders)];
    final args = <Object>[
      for (final f in folders) ...[f.sourceKey, f.folderId],
    ];
    if (!includeSuspect) {
      where.add('(cs.check_suspect_gone IS NULL OR cs.check_suspect_gone = 0)');
    }
    if (modeName == 'missing') {
      where.add('cs.last_check_time IS NULL');
    } else if (modeName == 'regular') {
      where.add(
        '(cs.last_check_time IS NULL OR cs.next_check_at IS NULL '
        'OR cs.next_check_at <= ?)',
      );
      args.add(nowMs);
    }
    if (!ignoreRetryAfter) {
      where.add('(cs.retry_after IS NULL OR cs.retry_after <= ?)');
      args.add(nowMs);
    }
    final rows = _db.select(
      '''SELECT fi.source_key, fi.comic_id, fi.folder_id,
                cs.last_check_time, cs.retry_after, cs.next_check_at
         FROM favorite_items fi
         LEFT JOIN comic_check_state cs
           ON cs.source_key = fi.source_key AND cs.comic_id = fi.comic_id
         WHERE ${where.join(' AND ')}
         GROUP BY fi.source_key, fi.comic_id, fi.folder_id
         ORDER BY fi.folder_id, fi.page_index, fi.display_order, fi.comic_id''',
      args,
    );
    final listStrategySources = {
      for (final folder in folders)
        if (ComicSource.find(folder.sourceKey)?.favoriteData?.updateCheck !=
            null)
          folder.sourceKey,
    };
    return [
      for (final row in rows)
        if (!listStrategySources.contains(row['source_key'] as String))
          ScanCandidate(
            sourceKey: row['source_key'] as String,
            comicId: row['comic_id'] as String,
            folderId: row['folder_id'] as String,
            lastCheckTime: row['last_check_time'] == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    row['last_check_time'] as int,
                  ),
            retryAfter: row['retry_after'] == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    row['retry_after'] as int,
                  ),
            nextCheckTime: row['next_check_at'] == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    row['next_check_at'] as int,
                  ),
          ),
    ];
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
    final state = _checkStateForRows(rows);
    return [
      for (final row in rows)
        _toFavoriteItemWithUpdateInfo(
          row,
          state['${row['source_key']}\u0000${row['comic_id']}'],
        ),
    ];
  }

  /// Fresh single-row update info for one comic, re-read right before it is
  /// checked so the persisted schedule and retry state reflect current data.
  FavoriteItemWithUpdateInfo? getComicUpdateInfo(
    String sourceKey,
    String comicId,
    String folderId,
  ) {
    final rows = _db.select(
      '''SELECT * FROM favorite_items
         WHERE source_key = ? AND folder_id = ? AND comic_id = ?
         LIMIT 1''',
      [sourceKey, folderId, comicId],
    );
    if (rows.isEmpty) return null;
    return _toFavoriteItemWithUpdateInfo(
      rows.first,
      _checkStateForRows(rows)['$sourceKey\u0000$comicId'],
    );
  }

  /// Toggles only the user-controlled hot-window flag. The transaction reads
  /// the latest deadline so repeated taps or two pages toggling at once cannot
  /// append multiple 14-day periods.
  FavoriteItemWithUpdateInfo? toggleManualHotWindow(
    String sourceKey,
    String comicId, {
    required bool enabled,
    DateTime? now,
  }) {
    final completedAt = now ?? DateTime.now();
    _db.execute('BEGIN');
    try {
      // A cached favorite can legitimately predate comic_check_state. Create
      // only the comic-level row here, inside the same transaction as the
      // toggle, so it remains a missing-baseline candidate.
      _db.execute(
        '''INSERT OR IGNORE INTO comic_check_state (source_key, comic_id)
           VALUES (?, ?)''',
        [sourceKey, comicId],
      );
      final rows = _db.select(
        '''SELECT * FROM comic_check_state
           WHERE source_key = ? AND comic_id = ? LIMIT 1''',
        [sourceKey, comicId],
      );
      if (rows.isEmpty) {
        throw StateError('Unable to create comic check state');
      }
      final state = rows.first;
      final existingUntil = _dateTimeFromRow(state['manual_hot_until']);
      final activeExisting =
          existingUntil != null && existingUntil.isAfter(completedAt);
      var manualUntil = existingUntil;
      if (enabled) {
        manualUntil = activeExisting
            ? existingUntil
            : completedAt.add(kFollowUpdateHotWindow);
      }
      final effectiveActivity =
          _dateTimeFromRow(state['source_activity_at']) ??
          _dateTimeFromRow(state['baseline_at']);
      final oldJitter =
          (state['old_schedule_jitter_applied'] as int? ?? 0) != 0;
      final autoUntil = _dateTimeFromRow(state['auto_hot_until']);
      final nextBefore = _dateTimeFromRow(state['next_check_at']);
      var jitterApplied = oldJitter;
      DateTime? nextCheck = nextBefore;
      if (effectiveActivity != null) {
        final decision = computeNextSchedule(
          completedAt: completedAt,
          effectiveActivityAt: effectiveActivity,
          autoHotUntil: autoUntil,
          manualHotEnabled: enabled,
          manualHotUntil: manualUntil,
          oldScheduleJitterApplied: oldJitter,
          sourceKey: sourceKey,
          comicId: comicId,
        );
        jitterApplied = decision.appliedOldScheduleJitter;
        if (!enabled) {
          nextCheck = decision.nextCheckAt;
        } else {
          final hotDeadline = completedAt.add(kFollowUpdateHotInterval);
          if (nextCheck == null || nextCheck.isAfter(hotDeadline)) {
            nextCheck = hotDeadline;
          }
        }
      }
      _db.execute(
        '''UPDATE comic_check_state
           SET manual_hot_enabled = ?, manual_hot_until = ?, next_check_at = ?,
               old_schedule_jitter_applied = ?
           WHERE source_key = ? AND comic_id = ?''',
        [
          enabled ? 1 : 0,
          manualUntil?.millisecondsSinceEpoch,
          nextCheck?.millisecondsSinceEpoch,
          jitterApplied ? 1 : 0,
          sourceKey,
          comicId,
        ],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    notifyListeners();
    final folderIds = getKnownFolderIds(sourceKey, comicId);
    for (final folderId in folderIds) {
      final result = getComicUpdateInfo(sourceKey, comicId, folderId);
      if (result != null) return result;
    }
    return null;
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
    final state = _checkStateForRows(rows);
    return [
      for (final row in rows)
        _toFavoriteItemWithUpdateInfo(
          row,
          state['${row['source_key']}\u0000${row['comic_id']}'],
        ),
    ];
  }

  FavoriteItemWithUpdateInfo _toFavoriteItemWithUpdateInfo(
    Row row,
    Map<String, Object?>? state,
  ) {
    Map<String, dynamic>? sourceUpdateMetadata;
    final rawMetadata = state?['source_update_metadata'];
    if (rawMetadata is String && rawMetadata.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawMetadata);
        if (decoded is Map) {
          sourceUpdateMetadata = Map<String, dynamic>.from(decoded);
        }
      } catch (e) {
        Log.warning(
          'FavoriteUpdate',
          'Ignoring corrupted source update metadata: $e',
        );
      }
    }
    return FavoriteItemWithUpdateInfo(
      FavoriteItem.fromRow(row),
      state?['last_update_time'] as String?,
      state?['update_marker'] as String?,
      (state?['has_new_update'] as int? ?? 0) != 0,
      state?['last_check_time'] as int?,
      state?['retry_after'] as int?,
      checkFailures: state?['check_failures'] as int? ?? 0,
      checkNotFoundCount: state?['check_not_found_count'] as int? ?? 0,
      isSuspectGone: (state?['check_suspect_gone'] as int? ?? 0) != 0,
      baselineAt: _dateTimeFromRow(state?['baseline_at']),
      sourceActivityAt: _dateTimeFromRow(state?['source_activity_at']),
      nextCheckAt: _dateTimeFromRow(state?['next_check_at']),
      autoHotUntil: _dateTimeFromRow(state?['auto_hot_until']),
      manualHotUntil: _dateTimeFromRow(state?['manual_hot_until']),
      manualHotEnabled: (state?['manual_hot_enabled'] as int? ?? 0) != 0,
      oldScheduleJitterApplied:
          (state?['old_schedule_jitter_applied'] as int? ?? 0) != 0,
      sourceUpdateMetadata: sourceUpdateMetadata,
    );
  }

  static DateTime? _dateTimeFromRow(Object? value) =>
      value is int ? DateTime.fromMillisecondsSinceEpoch(value) : null;

  /// Updates fields from a comic-detail JSON response without changing tags
  /// or other list metadata already in the device cache. The cover is only
  /// replaced when [cover] is explicitly provided and non-empty.
  void updateBasicInfo(
    NetworkFavoriteFolderRef folder,
    String comicId, {
    String? title,
    String? author,
    int? chapterCount,
    String? cover,
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
      if (cover != null && cover.trim().isNotEmpty) json['cover'] = cover;
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

  /// Same as [updateBasicInfo] but for every folder row of the comic.
  void updateBasicInfoEverywhere(
    NetworkFavoriteFolderRef fallback,
    String comicId, {
    String? title,
    String? author,
    int? chapterCount,
    String? cover,
  }) {
    for (final folder in _comicFolders(fallback, comicId)) {
      updateBasicInfo(
        folder,
        comicId,
        title: title,
        author: author,
        chapterCount: chapterCount,
        cover: cover,
      );
    }
  }

  /// Atomically records a successful detail check and updates every cached
  /// favorite snapshot for the same comic. The returned value is true only
  /// when a same-version marker changed, so callers can decide whether to
  /// replace a potentially signed cover URL.
  bool applySuccessfulComicCheck(
    NetworkFavoriteFolderRef fallback,
    String comicId, {
    String? updateTime,
    DateTime? sourceActivityAt,
    DateTime? completedAt,
    String? updateMarker,
    String? title,
    String? author,
    int? chapterCount,
    String? cover,
  }) {
    final sourceKey = fallback.sourceKey;
    final finishedAt = completedAt ?? DateTime.now();
    final candidateActivity =
        sourceActivityAt ??
        parseFollowUpdateActivityTime(updateTime, now: finishedAt);
    final folders = _comicFolders(fallback, comicId);
    var changed = false;
    _db.execute('BEGIN');
    try {
      final previousRows = _db.select(
        '''SELECT * FROM comic_check_state
           WHERE source_key = ? AND comic_id = ? LIMIT 1''',
        [sourceKey, comicId],
      );
      final previous = previousRows.isEmpty ? null : previousRows.first;
      final previousMarker = previous?['update_marker'] as String?;
      changed = _hasSameVersionMarkerChanged(previousMarker, updateMarker);
      final previousActivity = _dateTimeFromRow(
        previous?['source_activity_at'],
      );
      final acceptedActivity = candidateActivity == null
          ? previousActivity
          : previousActivity == null ||
                candidateActivity.isAfter(previousActivity)
          ? candidateActivity
          : previousActivity;
      final baseline = _dateTimeFromRow(previous?['baseline_at']) ?? finishedAt;
      var autoUntil = _dateTimeFromRow(previous?['auto_hot_until']);
      if (changed) {
        final candidateUntil = finishedAt.add(kFollowUpdateHotWindow);
        if (autoUntil == null || candidateUntil.isAfter(autoUntil)) {
          autoUntil = candidateUntil;
        }
      }
      final manualUntil = _dateTimeFromRow(previous?['manual_hot_until']);
      final manualEnabled =
          (previous?['manual_hot_enabled'] as int? ?? 0) != 0 &&
          manualUntil != null &&
          manualUntil.isAfter(finishedAt);
      var jitterApplied =
          (previous?['old_schedule_jitter_applied'] as int? ?? 0) != 0;
      final effectiveActivity = acceptedActivity ?? baseline;
      if (finishedAt.difference(effectiveActivity) <
          kFollowUpdateOldScheduleJitterAge) {
        jitterApplied = false;
      }
      final decision = computeNextSchedule(
        completedAt: finishedAt,
        effectiveActivityAt: effectiveActivity,
        autoHotUntil: autoUntil,
        manualHotEnabled: manualEnabled,
        manualHotUntil: manualUntil,
        oldScheduleJitterApplied: jitterApplied,
        sourceKey: sourceKey,
        comicId: comicId,
      );
      jitterApplied = decision.appliedOldScheduleJitter;
      _db.execute(
        '''INSERT INTO comic_check_state
            (source_key, comic_id, last_update_time, update_marker,
             last_check_time, has_new_update, baseline_at, source_activity_at,
             next_check_at, auto_hot_until, manual_hot_until,
             manual_hot_enabled, old_schedule_jitter_applied)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(source_key, comic_id) DO UPDATE SET
             last_update_time = COALESCE(
               excluded.last_update_time, comic_check_state.last_update_time),
             update_marker = COALESCE(
               excluded.update_marker, comic_check_state.update_marker),
             last_check_time = excluded.last_check_time,
             retry_after = NULL,
             check_failures = 0,
             check_not_found_count = 0,
             check_suspect_gone = 0,
             has_new_update = CASE WHEN ? THEN 1
                                   ELSE comic_check_state.has_new_update END,
             baseline_at = excluded.baseline_at,
             source_activity_at = COALESCE(
               excluded.source_activity_at, comic_check_state.source_activity_at),
             next_check_at = excluded.next_check_at,
             auto_hot_until = excluded.auto_hot_until,
             manual_hot_until = excluded.manual_hot_until,
             manual_hot_enabled = excluded.manual_hot_enabled,
             old_schedule_jitter_applied = excluded.old_schedule_jitter_applied''',
        [
          sourceKey,
          comicId,
          updateTime,
          updateMarker,
          finishedAt.millisecondsSinceEpoch,
          changed ? 1 : 0,
          baseline.millisecondsSinceEpoch,
          acceptedActivity?.millisecondsSinceEpoch,
          decision.nextCheckAt.millisecondsSinceEpoch,
          autoUntil?.millisecondsSinceEpoch,
          manualUntil?.millisecondsSinceEpoch,
          manualEnabled ? 1 : 0,
          jitterApplied ? 1 : 0,
          changed ? 1 : 0,
        ],
      );
      for (final folder in folders) {
        updateBasicInfo(
          folder,
          comicId,
          title: title,
          author: author,
          chapterCount: chapterCount,
          cover: changed ? cover : null,
        );
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    notifyListeners();
    return changed;
  }

  static bool _hasSameVersionMarkerChanged(
    String? previousMarker,
    String? updateMarker,
  ) {
    if (previousMarker == null || updateMarker == null) return false;
    final previousVersion = previousMarker.startsWith('v2|') ? 'v2' : 'v1';
    final updateVersion = updateMarker.startsWith('v2|') ? 'v2' : 'v1';
    // A marker format migration establishes a new baseline. This prevents
    // the first v2 scan from reporting every existing comic as changed.
    return previousVersion == updateVersion && previousMarker != updateMarker;
  }

  /// Records a completed detail check in the comic-level state table. The
  /// first marker only establishes a baseline; later marker changes are
  /// actual updates. A successful check clears every delist/retry marker.
  bool recordComicCheckEverywhere(
    String sourceKey,
    String comicId, {
    String? updateTime,
    DateTime? sourceActivityAt,
    DateTime? completedAt,
    String? updateMarker,
  }) {
    final finishedAt = completedAt ?? DateTime.now();
    final candidateActivity =
        sourceActivityAt ??
        parseFollowUpdateActivityTime(updateTime, now: finishedAt);
    _db.execute('BEGIN');
    try {
      final rows = _db.select(
        '''SELECT * FROM comic_check_state
           WHERE source_key = ? AND comic_id = ? LIMIT 1''',
        [sourceKey, comicId],
      );
      final previous = rows.isEmpty ? null : rows.first;
      final changed = _hasSameVersionMarkerChanged(
        previous?['update_marker'] as String?,
        updateMarker,
      );
      final previousActivity = _dateTimeFromRow(
        previous?['source_activity_at'],
      );
      final acceptedActivity = candidateActivity == null
          ? previousActivity
          : previousActivity == null ||
                candidateActivity.isAfter(previousActivity)
          ? candidateActivity
          : previousActivity;
      final baseline = _dateTimeFromRow(previous?['baseline_at']) ?? finishedAt;
      var autoUntil = _dateTimeFromRow(previous?['auto_hot_until']);
      if (changed) {
        final candidateUntil = finishedAt.add(kFollowUpdateHotWindow);
        if (autoUntil == null || candidateUntil.isAfter(autoUntil)) {
          autoUntil = candidateUntil;
        }
      }
      final manualUntil = _dateTimeFromRow(previous?['manual_hot_until']);
      final manualEnabled =
          (previous?['manual_hot_enabled'] as int? ?? 0) != 0 &&
          manualUntil != null &&
          manualUntil.isAfter(finishedAt);
      var jitterApplied =
          (previous?['old_schedule_jitter_applied'] as int? ?? 0) != 0;
      final effectiveActivity = acceptedActivity ?? baseline;
      if (finishedAt.difference(effectiveActivity) <
          kFollowUpdateOldScheduleJitterAge) {
        jitterApplied = false;
      }
      final decision = computeNextSchedule(
        completedAt: finishedAt,
        effectiveActivityAt: effectiveActivity,
        autoHotUntil: autoUntil,
        manualHotEnabled: manualEnabled,
        manualHotUntil: manualUntil,
        oldScheduleJitterApplied: jitterApplied,
        sourceKey: sourceKey,
        comicId: comicId,
      );
      _db.execute(
        '''INSERT INTO comic_check_state
            (source_key, comic_id, last_update_time, update_marker,
             last_check_time, has_new_update, baseline_at, source_activity_at,
             next_check_at, auto_hot_until, manual_hot_until,
             manual_hot_enabled, old_schedule_jitter_applied)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(source_key, comic_id) DO UPDATE SET
             last_update_time = COALESCE(
               excluded.last_update_time, comic_check_state.last_update_time),
             update_marker = COALESCE(
               excluded.update_marker, comic_check_state.update_marker),
             last_check_time = excluded.last_check_time,
             retry_after = NULL,
             check_failures = 0,
             check_not_found_count = 0,
             check_suspect_gone = 0,
             has_new_update = CASE WHEN ? THEN 1
                                   ELSE comic_check_state.has_new_update END,
             baseline_at = excluded.baseline_at,
             source_activity_at = COALESCE(
               excluded.source_activity_at, comic_check_state.source_activity_at),
             next_check_at = excluded.next_check_at,
             auto_hot_until = excluded.auto_hot_until,
             manual_hot_until = excluded.manual_hot_until,
             manual_hot_enabled = excluded.manual_hot_enabled,
             old_schedule_jitter_applied = excluded.old_schedule_jitter_applied''',
        [
          sourceKey,
          comicId,
          updateTime,
          updateMarker,
          finishedAt.millisecondsSinceEpoch,
          changed ? 1 : 0,
          baseline.millisecondsSinceEpoch,
          acceptedActivity?.millisecondsSinceEpoch,
          decision.nextCheckAt.millisecondsSinceEpoch,
          autoUntil?.millisecondsSinceEpoch,
          manualUntil?.millisecondsSinceEpoch,
          manualEnabled ? 1 : 0,
          decision.appliedOldScheduleJitter ? 1 : 0,
          changed ? 1 : 0,
        ],
      );
      _db.execute('COMMIT');
      return changed;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Marks [comicId] as temporarily skipped by automatic scans after it
  /// failed a check. The value is persisted so a restart does not retry the
  /// failed comic immediately.
  void markComicRetryLaterEverywhere(
    String sourceKey,
    String comicId, {
    Duration delay = const Duration(hours: 1),
    int failures = 0,
    DateTime? now,
  }) {
    _db.execute(
      '''INSERT INTO comic_check_state
          (source_key, comic_id, retry_after, check_failures)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(source_key, comic_id) DO UPDATE SET
           retry_after = excluded.retry_after,
           check_failures = excluded.check_failures''',
      [
        sourceKey,
        comicId,
        (now ?? DateTime.now()).add(delay).millisecondsSinceEpoch,
        failures,
      ],
    );
  }

  /// Records one bare-400 delist hit and returns the accumulated count.
  /// Reset by any successful check, a suspect mark or a source-wide clear.
  int markComicNotFoundHitEverywhere(String sourceKey, String comicId) {
    _db.execute(
      '''INSERT INTO comic_check_state
          (source_key, comic_id, check_not_found_count)
         VALUES (?, ?, 1)
         ON CONFLICT(source_key, comic_id) DO UPDATE SET
           check_not_found_count = comic_check_state.check_not_found_count + 1''',
      [sourceKey, comicId],
    );
    final rows = _db.select(
      '''SELECT check_not_found_count FROM comic_check_state
         WHERE source_key = ? AND comic_id = ?''',
      [sourceKey, comicId],
    );
    return rows.first['check_not_found_count'] as int;
  }

  /// Marks [comicId] as suspected removed. Such comics are skipped by all
  /// follow-up scans until the user clears the mark or removes the favorite.
  void markComicSuspectGoneEverywhere(String sourceKey, String comicId) {
    _db.execute(
      '''INSERT INTO comic_check_state
          (source_key, comic_id, check_suspect_gone, check_failures,
           check_not_found_count, last_check_time)
         VALUES (?, ?, 1, 0, 0, ?)
         ON CONFLICT(source_key, comic_id) DO UPDATE SET
           check_suspect_gone = 1,
           check_failures = 0,
           check_not_found_count = 0,
           retry_after = NULL,
           last_check_time = excluded.last_check_time''',
      [sourceKey, comicId, DateTime.now().millisecondsSinceEpoch],
    );
  }

  void clearComicSuspectGoneEverywhere(String sourceKey, String comicId) {
    _db.execute(
      '''UPDATE comic_check_state
          SET check_suspect_gone = 0, check_failures = 0,
              check_not_found_count = 0, retry_after = NULL
          WHERE source_key = ? AND comic_id = ?''',
      [sourceKey, comicId],
    );
    notifyListeners();
  }

  /// Clears every suspected-removed mark of [sourceKey] (including marks made
  /// by earlier runs). Used when the source is judged to be down: marks made
  /// against its delist-looking responses are unreliable, so they are dropped
  /// and the comics are re-evaluated by the next run once the source recovers.
  void clearComicSuspectGoneForSourceEverywhere(String sourceKey) {
    _db.execute(
      '''UPDATE comic_check_state
          SET check_suspect_gone = 0, check_failures = 0,
              check_not_found_count = 0, retry_after = NULL
          WHERE source_key = ? AND check_suspect_gone = 1''',
      [sourceKey],
    );
    notifyListeners();
  }

  bool isComicSuspectGone(String sourceKey, String comicId) {
    final rows = _db.select(
      '''SELECT 1 FROM comic_check_state
         WHERE source_key = ? AND comic_id = ? AND check_suspect_gone != 0
         LIMIT 1''',
      [sourceKey, comicId],
    );
    return rows.isNotEmpty;
  }

  /// Marks [comicId] as suspected removed. Used by the detail/reader page
  /// paths: the user opened the comic and saw a 404/400/delist response
  /// first-hand, so a single confirmed response is enough. Idempotent.
  void recordComicNotFoundEverywhere(String sourceKey, String comicId) {
    markComicSuspectGoneEverywhere(sourceKey, comicId);
    notifyListeners();
  }

  List<FavoriteItemWithUpdateInfo> getSuspectGoneComicsInFolders(
    Iterable<NetworkFavoriteFolderRef> folders,
  ) {
    final list = folders.toList();
    if (list.isEmpty) return const [];
    final rows = _db.select(
      '''SELECT fi.* FROM favorite_items fi
         WHERE ${_folderWhereClause(list)}
           AND (fi.source_key, fi.comic_id) IN (
             SELECT source_key, comic_id FROM comic_check_state
             WHERE check_suspect_gone != 0
           )
         GROUP BY fi.source_key, fi.comic_id
         ORDER BY fi.source_key, fi.comic_id''',
      list.expand((f) => [f.sourceKey, f.folderId]).toList(),
    );
    final state = _checkStateForRows(rows);
    return [
      for (final row in rows)
        _toFavoriteItemWithUpdateInfo(
          row,
          state['${row['source_key']}\u0000${row['comic_id']}'],
        ),
    ];
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

  void markReadInAllFolders(String sourceKey, String comicId) {
    _db.execute(
      '''UPDATE comic_check_state SET has_new_update = 0
         WHERE source_key = ? AND comic_id = ?''',
      [sourceKey, comicId],
    );
    notifyListeners();
  }

  /// Flushes update-check changes that are deliberately batched to avoid a UI
  /// notification for every comic in a follow-updates run.
  void notifyCacheChanged() => notifyListeners();

  /// Number of cached comics in [folder] that have never been checked at all.
  /// A comic only counts as checked once its detail request succeeded or its
  /// failure put it into the retry cooldown; a cooldown is not an unchecked
  /// gap (the scan already tried), so it must not surface as "baseline
  /// incomplete" in the UI.
  int countUncheckedComics(NetworkFavoriteFolderRef folder) {
    final row = _db
        .select(
          '''SELECT COUNT(DISTINCT fi.comic_id) AS count FROM favorite_items fi
             LEFT JOIN comic_check_state cs
               ON cs.source_key = fi.source_key AND cs.comic_id = fi.comic_id
             WHERE fi.source_key = ? AND fi.folder_id = ?
               AND cs.last_check_time IS NULL AND cs.retry_after IS NULL
               AND (cs.check_suspect_gone IS NULL OR cs.check_suspect_gone = 0)''',
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
  /// Retry cooldowns and failure counters are part of the baseline: without
  /// clearing them the never-checked semantics would count cooled comics as
  /// checked and the next scan would never retry them.
  void clearAllBaselines({DateTime? now}) {
    final currentMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    _db.execute('BEGIN');
    try {
      _db.execute('''
        UPDATE comic_check_state
        SET last_check_time = NULL,
            last_update_time = NULL,
            update_marker = NULL,
            has_new_update = 0,
            retry_after = NULL,
            check_failures = 0,
            source_update_metadata = NULL,
            baseline_at = NULL,
            source_activity_at = NULL,
            next_check_at = NULL,
            auto_hot_until = NULL,
            old_schedule_jitter_applied = 0,
            manual_hot_enabled = CASE
              WHEN manual_hot_until IS NOT NULL
               AND manual_hot_until > $currentMs
              THEN manual_hot_enabled ELSE 0 END
      ''');
      // List strategy baselines live at folder level; clear them together so
      // the next follow-up run rebuilds both detail and list baselines.
      _db.execute('DELETE FROM favorite_update_scan_state');
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    notifyListeners();
  }

  /// Drops list-strategy scan baselines after an explicit account session
  /// change. Detail-strategy sources are deliberately untouched.
  int captureFavoriteSessionEpoch(String sourceKey) =>
      _favoriteSessionEpochs.putIfAbsent(sourceKey, () => 0);

  bool isFavoriteSessionEpochCurrent(String sourceKey, int expectedEpoch) =>
      captureFavoriteSessionEpoch(sourceKey) == expectedEpoch;

  void _invalidateAllFavoriteSessionEpochs() {
    final sourceKeys = _favoriteSessionEpochs.keys.toList(growable: false);
    for (final sourceKey in sourceKeys) {
      _favoriteSessionEpochs[sourceKey] =
          _favoriteSessionEpochs[sourceKey]! + 1;
    }
  }

  void invalidateFavoriteSessionForSource(String sourceKey) {
    final source = ComicSource.find(sourceKey);
    if (source?.favoriteData?.updateCheck == null) return;
    _favoriteSessionEpochs[sourceKey] =
        captureFavoriteSessionEpoch(sourceKey) + 1;
    _db.execute('BEGIN');
    try {
      _db.execute(
        'DELETE FROM favorite_update_scan_state WHERE source_key = ?',
        [sourceKey],
      );
      _db.execute(
        '''UPDATE comic_check_state
           SET last_update_time = NULL,
               update_marker = NULL,
               last_check_time = NULL,
               has_new_update = 0,
               retry_after = NULL,
               check_failures = 0,
               check_not_found_count = 0,
               check_suspect_gone = 0,
               source_update_metadata = NULL,
               baseline_at = NULL,
               source_activity_at = NULL,
               next_check_at = NULL,
               auto_hot_until = NULL,
               manual_hot_until = NULL,
               manual_hot_enabled = 0,
               old_schedule_jitter_applied = 0
           WHERE source_key = ?''',
        [sourceKey],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    notifyListeners();
  }

  int countUpdates(NetworkFavoriteFolderRef folder) {
    final row = _db
        .select(
          '''SELECT COUNT(DISTINCT fi.comic_id) AS count FROM favorite_items fi
             JOIN comic_check_state cs
               ON cs.source_key = fi.source_key AND cs.comic_id = fi.comic_id
             WHERE fi.source_key = ? AND fi.folder_id = ? AND cs.has_new_update != 0''',
          [folder.sourceKey, folder.folderId],
        )
        .first;
    return row['count'] as int;
  }

  static String _folderWhereClause(List<NetworkFavoriteFolderRef> folders) {
    if (folders.isEmpty) return '0';
    return '(${folders.map((f) => '(fi.source_key = ? AND fi.folder_id = ?)').join(' OR ')})';
  }

  int _countDistinctComicsInFolders(
    Iterable<NetworkFavoriteFolderRef> folders, {
    String? stateCondition,
  }) {
    final list = folders.toList();
    if (list.isEmpty) return 0;
    final row = _db.select('''SELECT COUNT(*) AS count FROM (
             SELECT fi.source_key, fi.comic_id FROM favorite_items fi
             LEFT JOIN comic_check_state cs
               ON cs.source_key = fi.source_key AND cs.comic_id = fi.comic_id
             WHERE ${_folderWhereClause(list)}
             ${stateCondition == null ? '' : 'AND ($stateCondition)'}
             GROUP BY fi.source_key, fi.comic_id
           )''', list.expand((f) => [f.sourceKey, f.folderId]).toList()).first;
    return row['count'] as int;
  }

  int countCachedComicsInFolders(Iterable<NetworkFavoriteFolderRef> folders) =>
      _countDistinctComicsInFolders(folders);

  /// Comics that have never been attempted: no successful check, no pending
  /// retry cooldown and no suspect mark. Comics in a cooldown were already
  /// tried, so they are not "unchecked" even though they may still lack a
  /// successful check; a suspect comic was checked and judged as likely
  /// removed, which is also a completed attempt.
  int countUncheckedComicsInFolders(
    Iterable<NetworkFavoriteFolderRef> folders,
  ) => _countDistinctComicsInFolders(
    folders,
    stateCondition:
        'cs.last_check_time IS NULL AND cs.retry_after IS NULL'
        ' AND (cs.check_suspect_gone IS NULL OR cs.check_suspect_gone = 0)',
  );

  /// Comics that still need a check right now: never attempted, or whose
  /// retry cooldown has already expired.
  int countPendingUncheckedComicsInFolders(
    Iterable<NetworkFavoriteFolderRef> folders,
  ) => _countDistinctComicsInFolders(
    folders,
    stateCondition:
        '(cs.last_check_time IS NULL AND cs.retry_after IS NULL'
        ' AND (cs.check_suspect_gone IS NULL OR cs.check_suspect_gone = 0))'
        ' OR (cs.retry_after IS NOT NULL AND cs.retry_after <= ${DateTime.now().millisecondsSinceEpoch})',
  );

  int countUpdatesInFolders(Iterable<NetworkFavoriteFolderRef> folders) =>
      _countDistinctComicsInFolders(
        folders,
        stateCondition: 'cs.has_new_update != 0',
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
      '''SELECT * FROM favorite_items fi
         WHERE ${_folderWhereClause(list)}
         GROUP BY fi.source_key, fi.comic_id
         ORDER BY fi.source_key, fi.comic_id
         LIMIT ? OFFSET ?''',
      [
        ...list.expand((f) => [f.sourceKey, f.folderId]),
        limit,
        offset,
      ],
    );
    final state = _checkStateForRows(rows);
    return [
      for (final row in rows)
        _toFavoriteItemWithUpdateInfo(
          row,
          state['${row['source_key']}\u0000${row['comic_id']}'],
        ),
    ];
  }

  List<FavoriteItemWithUpdateInfo> getUpdatedComicsInFolders(
    Iterable<NetworkFavoriteFolderRef> folders,
  ) {
    final list = folders.toList();
    if (list.isEmpty) return const [];
    final rows = _db.select(
      '''SELECT fi.* FROM favorite_items fi
         JOIN comic_check_state cs
           ON cs.source_key = fi.source_key AND cs.comic_id = fi.comic_id
         WHERE ${_folderWhereClause(list)} AND cs.has_new_update != 0
         GROUP BY fi.source_key, fi.comic_id
         ORDER BY cs.last_update_time DESC, fi.source_key, fi.comic_id''',
      list.expand((f) => [f.sourceKey, f.folderId]).toList(),
    );
    final state = _checkStateForRows(rows);
    return [
      for (final row in rows)
        _toFavoriteItemWithUpdateInfo(
          row,
          state['${row['source_key']}\u0000${row['comic_id']}'],
        ),
    ];
  }
}
