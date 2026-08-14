import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/cache_manager.dart';

void main() {
  late Directory tempDir;
  late Directory cacheDir;
  late String dbPath;
  final managers = <CacheManager>[];

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('venera_cache_test');
    cacheDir = Directory('${tempDir.path}/cache');
    dbPath = '${tempDir.path}/cache.db';
  });

  tearDown(() {
    for (final manager in managers) {
      manager.dispose();
    }
    managers.clear();
    tempDir.deleteSync(recursive: true);
  });

  CacheManager createManager() {
    final manager = CacheManager.test(cachePath: cacheDir.path, dbPath: dbPath);
    managers.add(manager);
    return manager;
  }

  test('write and find round-trips through the cache', () async {
    final manager = createManager();
    await manager.ready;

    await manager.writeCache('key1', [1, 2, 3]);
    final file = await manager.findCache('key1');
    expect(file, isNotNull);
    expect(await file!.readAsBytes(), [1, 2, 3]);
    expect(manager.currentSize, 3);

    expect(await manager.findCache('missing'), isNull);
    manager.flushPendingExpiryUpdates();
  });

  test('an expired entry is removed and reports a miss', () async {
    final manager = createManager();
    await manager.ready;

    await manager.writeCache('expired', [1, 2, 3], -1000);
    expect(await manager.findCache('expired'), isNull);

    // The row and the file are gone.
    final db = sqlite3.open(dbPath);
    expect(
      db.select('SELECT * FROM cache WHERE key = ?', ['expired']),
      isEmpty,
    );
    db.dispose();
    expect(
      Directory(cacheDir.path).listSync(recursive: true).whereType<File>(),
      isEmpty,
    );
  });

  test(
    'a hit renews the sliding expiry and the batch flush persists it',
    () async {
      final manager = createManager();
      await manager.ready;

      // Short-lived entry: it would expire 100ms after writing without renewal.
      await manager.writeCache('key1', [1, 2, 3], 100);
      expect(await manager.findCache('key1'), isNotNull);

      await Future<void>.delayed(const Duration(milliseconds: 150));
      // Still a hit: the in-memory expiry was renewed on access.
      expect(await manager.findCache('key1'), isNotNull);

      // The renewal must be durable after the batched flush.
      manager.flushPendingExpiryUpdates();
      final db = sqlite3.open(dbPath);
      final row = db.select('SELECT expires FROM cache WHERE key = ?', [
        'key1',
      ]);
      expect(row, hasLength(1));
      final expires = row.first['expires'] as int;
      expect(
        expires - DateTime.now().millisecondsSinceEpoch,
        greaterThan(6 * 24 * 60 * 60 * 1000),
      );
      db.dispose();
    },
  );

  test('eviction removes entries ordered by expiry (oldest first)', () async {
    final manager = CacheManager.test(
      cachePath: cacheDir.path,
      dbPath: dbPath,
      limitSizeBytes: 5,
    );
    managers.add(manager);
    await manager.ready;

    await manager.writeCache('old', [1, 2, 3], 1000);
    await manager.writeCache('new', [1, 2, 3, 4, 5], 10000);

    expect(await manager.findCache('old'), isNull);
    expect(await manager.findCache('new'), isNotNull);
    expect(manager.currentSize, lessThanOrEqualTo(5));
    manager.flushPendingExpiryUpdates();
  });

  test('startup scan deletes orphan files and keeps managed files', () async {
    final first = createManager();
    await first.ready;
    await first.writeCache('managed', [1, 2, 3]);

    // A file nobody recorded in the DB: an orphan.
    final orphanDir = Directory('${cacheDir.path}/7');
    orphanDir.createSync(recursive: true);
    File('${orphanDir.path}/stray.bin').writeAsBytesSync([9, 9, 9]);

    final second = createManager();
    await second.ready;

    expect(
      File('${orphanDir.path}/stray.bin').existsSync(),
      isFalse,
      reason: 'orphan files are deleted at startup',
    );
    expect(
      await second.findCache('managed'),
      isNotNull,
      reason: 'files recorded in the DB survive the scan',
    );
    expect(second.currentSize, 3);
    second.flushPendingExpiryUpdates();
  });

  test('a hit whose file vanished is dropped from the index', () async {
    final manager = createManager();
    await manager.ready;

    await manager.writeCache('vanished', [1, 2, 3]);
    final file = await manager.findCache('vanished');
    await file!.delete();

    expect(await manager.findCache('vanished'), isNull);
    final db = sqlite3.open(dbPath);
    expect(
      db.select('SELECT * FROM cache WHERE key = ?', ['vanished']),
      isEmpty,
    );
    db.dispose();
    manager.flushPendingExpiryUpdates();
  });

  test('writeCache is atomic and leaves no temp files behind', () async {
    final manager = createManager();
    await manager.ready;

    await manager.writeCache('atomic', List.filled(1024, 7));
    final file = await manager.findCache('atomic');
    expect(file, isNotNull);
    expect(await file!.readAsBytes(), List.filled(1024, 7));
    expect(
      Directory(cacheDir.path)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.contains('.tmp-')),
      isEmpty,
      reason: 'temp files must be renamed away after a successful write',
    );
    manager.flushPendingExpiryUpdates();
  });

  test('a write during the startup scan is not deleted as an orphan', () async {
    // The orphan scan captures its managed-set snapshot at the start; a file
    // written while it runs must not be treated as unmanaged.
    final manager = createManager();
    await manager.writeCache('early', [1, 2, 3]);
    await manager.ready;

    expect(
      await manager.findCache('early'),
      isNotNull,
      reason: 'an entry written before the scan finished must survive',
    );
    expect(manager.currentSize, 3);
    manager.flushPendingExpiryUpdates();
  });
}
