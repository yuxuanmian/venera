import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import 'app.dart';

/// One row of the in-memory cache index.
class _CacheEntry {
  _CacheEntry({required this.dir, required this.name, required this.expires});

  final String dir;

  final String name;

  /// Expiry timestamp in milliseconds since epoch. Renewed (sliding) on
  /// every [CacheManager.findCache] hit.
  int expires;

  String get relativePath => '$dir/$name';
}

class CacheManager {
  static const int defaultDuration = 7 * 24 * 60 * 60 * 1000;

  /// How often the batched sliding-expiry updates are flushed to the DB.
  static const _flushInterval = Duration(seconds: 2);

  static String get defaultCachePath => '${App.cachePath}/cache';

  static CacheManager? instance;

  late final String _cachePath;

  late Database _db;

  int? _currentSize;

  /// size in bytes
  int get currentSize => _currentSize ?? 0;

  int dir = 0;

  int _limitSize = 2 * 1024 * 1024 * 1024;

  /// In-memory index of all non-expired cache rows. The read path never
  /// touches the DB: [findCache] is a map lookup plus an async file stat.
  final Map<String, _CacheEntry> _index = {};

  /// Keys whose sliding expiry was renewed in memory but not yet flushed.
  final Set<String> _dirtyExpiry = {};

  Timer? _flushTimer;

  final Completer<void> _ready = Completer<void>();

  bool _isChecking = false;

  /// Scans a cache directory in a background isolate: returns the total size
  /// of the files that have an entry in [managed] and collects the rest as
  /// orphans. No database access happens here; membership checks are pure
  /// in-memory set lookups against `dir/name` paths.
  static Future<(int, List<String>)> _scanFiles(
    Set<String> managed,
    String rootDir,
  ) {
    return Isolate.run(() async {
      int totalSize = 0;
      final unmanaged = <String>[];
      await for (final entity in Directory(rootDir).list(recursive: true)) {
        if (entity is File) {
          final segments = entity.uri.pathSegments;
          final name = segments.last;
          final dir = segments.elementAtOrNull(segments.length - 2) ?? "*";
          if (managed.contains('$dir/$name')) {
            totalSize += await entity.length();
          } else {
            unmanaged.add(entity.path);
          }
        }
      }
      return (totalSize, unmanaged);
    });
  }

  CacheManager._create({
    String? cachePath,
    String? dbPath,
    int? limitSizeBytes,
  }) {
    _cachePath = cachePath ?? defaultCachePath;
    _limitSize = limitSizeBytes ?? 2 * 1024 * 1024 * 1024;
    Directory(_cachePath).createSync(recursive: true);
    _db = sqlite3.open(dbPath ?? '${App.dataPath}/cache.db');

    // WAL + synchronous=NORMAL makes every INSERT/UPDATE cheap: fsync is
    // deferred to the WAL checkpoint instead of running on every commit.
    // NORMAL is only enabled when WAL actually took effect; with a plain
    // rollback journal NORMAL would risk database corruption on power loss.
    final mode = _db.select('PRAGMA journal_mode=WAL');
    if (mode.isNotEmpty && mode.first.values.first == 'wal') {
      _db.execute('PRAGMA synchronous=NORMAL');
    }
    _db.execute('''
      CREATE TABLE IF NOT EXISTS cache (
        key TEXT PRIMARY KEY NOT NULL,
        dir TEXT NOT NULL,
        name TEXT NOT NULL,
        expires INTEGER NOT NULL,
        type TEXT
      )
    ''');

    _loadIndex();
    unawaited(
      _finishInit().whenComplete(() {
        if (!_ready.isCompleted) {
          _ready.complete();
        }
      }),
    );
  }

  /// Loads the cache table into memory, dropping rows that already expired.
  /// The files of expired rows are cleaned up by the startup orphan scan,
  /// since they are not part of the managed set anymore.
  void _loadIndex() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final expiredKeys = <String>[];
    for (final row in _db.select('SELECT key, dir, name, expires FROM cache')) {
      final key = row['key'] as String;
      final dir = row['dir'] as String;
      final name = row['name'] as String;
      final expires = row['expires'] as int;
      if (expires < now) {
        expiredKeys.add(key);
      } else {
        _index[key] = _CacheEntry(dir: dir, name: name, expires: expires);
      }
    }
    _deleteRows(expiredKeys);
  }

  /// Startup pass: orphan scan, size accounting and an initial size check.
  /// Errors here behave like the previous fire-and-forget scan.
  Future<void> _finishInit() async {
    final managed = _index.values.map((e) => e.relativePath).toSet();
    final (totalSize, unmanaged) = await _scanFiles(managed, _cachePath);
    for (final path in unmanaged) {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }
    _currentSize = totalSize;
    await checkCache();
  }

  /// Completes after the startup pass (index load, orphan scan, size
  /// accounting and the initial size check) is done.
  Future<void> get ready => _ready.future;

  /// Get the singleton instance of CacheManager.
  factory CacheManager() => instance ??= CacheManager._create();

  /// Creates an independent manager for tests, using explicit paths.
  factory CacheManager.test({
    required String cachePath,
    required String dbPath,
    int limitSizeBytes = 2 * 1024 * 1024 * 1024,
  }) => CacheManager._create(
    cachePath: cachePath,
    dbPath: dbPath,
    limitSizeBytes: limitSizeBytes,
  );

  /// set cache size limit in MB
  void setLimitSize(int size) {
    _limitSize = size * 1024 * 1024;
  }

  /// Write cache to disk.
  Future<void> writeCache(
    String key,
    List<int> data, [
    int duration = defaultDuration,
  ]) async {
    // The old row (if any) is located through the in-memory index, avoiding
    // the SELECT the previous implementation needed for every write.
    final old = _index[key];
    if (old != null) {
      final oldFile = File('$_cachePath/${old.relativePath}');
      var oldSize = 0;
      if (await oldFile.exists()) {
        oldSize = await oldFile.length();
        await oldFile.delete();
      }
      _index.remove(key);
      _db.execute('DELETE FROM cache WHERE key = ?', [key]);
      if (_currentSize != null) {
        _currentSize = _currentSize! - oldSize;
      }
    }
    this.dir++;
    this.dir %= 100;
    var dir = this.dir;
    var name = md5.convert(key.codeUnits).toString();
    var file = File('$_cachePath/$dir/$name');
    await file.create(recursive: true);
    await file.writeAsBytes(data);
    var expires = DateTime.now().millisecondsSinceEpoch + duration;
    // The insert stays immediate: if the process dies right after the file
    // write, the row is already durable and the file is never orphaned.
    _db.execute(
      '''
      INSERT OR REPLACE INTO cache (key, dir, name, expires) VALUES (?, ?, ?, ?)
    ''',
      [key, dir.toString(), name, expires],
    );
    _index[key] = _CacheEntry(
      dir: dir.toString(),
      name: name,
      expires: expires,
    );
    if (_currentSize != null) {
      _currentSize = _currentSize! + data.length;
    }
    await checkCacheIfRequired();
  }

  /// Find cache by key.
  /// If cache is expired, it will be deleted and return null.
  /// If cache is not found, it will return null.
  /// If cache is found, it will return the file, and renew the expiry time.
  Future<File?> findCache(String key) async {
    final entry = _index[key];
    if (entry == null) {
      return null;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (entry.expires < now) {
      // expired
      _index.remove(key);
      _db.execute('DELETE FROM cache WHERE key = ?', [key]);
      final file = File('$_cachePath/${entry.relativePath}');
      if (await file.exists()) {
        await file.delete();
      }
      return null;
    }
    final file = File('$_cachePath/${entry.relativePath}');
    if (await file.exists()) {
      // Sliding renewal: update memory immediately, batch the DB write.
      entry.expires = now + defaultDuration;
      _markDirty(key);
      return file;
    }
    // The file is missing (e.g. the system cleared the cache directory).
    _index.remove(key);
    _db.execute('DELETE FROM cache WHERE key = ?', [key]);
    return null;
  }

  /// Queues a sliding-expiry renewal for batched flushing.
  void _markDirty(String key) {
    _dirtyExpiry.add(key);
    _flushTimer ??= Timer.periodic(
      _flushInterval,
      (_) => flushPendingExpiryUpdates(),
    );
  }

  /// Flushes the batched sliding-expiry updates in one transaction. Losing a
  /// batch (e.g. power loss) only reverts the renewal, never the row itself.
  void flushPendingExpiryUpdates() {
    if (_dirtyExpiry.isEmpty) {
      _flushTimer?.cancel();
      _flushTimer = null;
      return;
    }
    final expires = DateTime.now().millisecondsSinceEpoch + defaultDuration;
    final stmt = _db.prepare('UPDATE cache SET expires = ? WHERE key = ?');
    try {
      _db.execute('BEGIN');
      for (final key in _dirtyExpiry) {
        stmt.execute([expires, key]);
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      stmt.dispose();
    }
    _dirtyExpiry.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  /// Deletes rows by key in a single transaction.
  void _deleteRows(List<String> keys) {
    if (keys.isEmpty) {
      return;
    }
    final stmt = _db.prepare('DELETE FROM cache WHERE key = ?');
    try {
      _db.execute('BEGIN');
      for (final key in keys) {
        stmt.execute([key]);
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      stmt.dispose();
    }
  }

  /// Check cache size and delete expired cache.
  /// Only check cache if current size is greater than limit size.
  Future<void> checkCacheIfRequired() {
    if (_currentSize != null && _currentSize! > _limitSize) {
      return checkCache();
    }
    return Future.value();
  }

  /// Deletes expired entries and, while the cache is over the size limit,
  /// evicts entries ordered by expiry time (oldest first, i.e. least
  /// recently used). All selection happens in memory; the DB only receives
  /// batched deletes.
  Future<void> checkCache() async {
    if (_isChecking) {
      return;
    }
    _isChecking = true;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final expired = _index.entries
          .where((e) => e.value.expires < now)
          .toList();
      final expiredKeys = <String>[];
      for (final e in expired) {
        final file = File('$_cachePath/${e.value.relativePath}');
        if (await file.exists()) {
          final size = await file.length();
          await file.delete();
          if (_currentSize != null) {
            _currentSize = _currentSize! - size;
          }
        }
        _index.remove(e.key);
        expiredKeys.add(e.key);
      }
      _deleteRows(expiredKeys);

      final sorted = _index.entries.toList()
        ..sort((a, b) => a.value.expires.compareTo(b.value.expires));
      if (_currentSize != null &&
          _currentSize! > _limitSize &&
          sorted.isEmpty) {
        // There are files unmanaged by the cache manager. Clear all cache.
        await Directory(_cachePath).delete(recursive: true);
        Directory(_cachePath).createSync(recursive: true);
      }
      var victimIndex = 0;
      while (_currentSize != null &&
          _currentSize! > _limitSize &&
          victimIndex < sorted.length) {
        final removedKeys = <String>[];
        final end = victimIndex + 10 > sorted.length
            ? sorted.length
            : victimIndex + 10;
        for (final e in sorted.sublist(victimIndex, end)) {
          final file = File('$_cachePath/${e.value.relativePath}');
          if (await file.exists()) {
            final size = await file.length();
            await file.delete();
            if (_currentSize != null) {
              _currentSize = _currentSize! - size;
            }
          }
          _index.remove(e.key);
          removedKeys.add(e.key);
          if (_currentSize != null && _currentSize! <= _limitSize) {
            break;
          }
        }
        _deleteRows(removedKeys);
        victimIndex = end;
      }
    } finally {
      _isChecking = false;
    }
  }

  /// Delete cache by key.
  Future<void> delete(String key) async {
    final entry = _index[key];
    if (entry == null) {
      return;
    }
    final file = File('$_cachePath/${entry.relativePath}');
    var fileSize = 0;
    if (await file.exists()) {
      fileSize = await file.length();
      await file.delete();
    }
    _index.remove(key);
    _db.execute('DELETE FROM cache WHERE key = ?', [key]);
    if (_currentSize != null) {
      _currentSize = _currentSize! - fileSize;
    }
  }

  /// Delete all cache.
  Future<void> clear() async {
    await Directory(_cachePath).delete(recursive: true);
    Directory(_cachePath).createSync(recursive: true);
    _db.execute('''
      DELETE FROM cache
    ''');
    _index.clear();
    _dirtyExpiry.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
    _currentSize = 0;
  }

  /// Closes the underlying database.
  ///
  /// Only intended for tests: the app-wide singleton lives for the whole
  /// process lifetime.
  void dispose() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _db.dispose();
  }
}
