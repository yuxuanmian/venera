import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/utils/data.dart';

/// Regression: `exportAppData` used to put `history.db` and `cookie.db` into the
/// archive with a plain file read.
///
/// Those databases use the rollback journal, so their pages are rewritten **in
/// place** while a transaction is open.  A copy taken during a write is
/// therefore a half-applied transaction: it fails `PRAGMA integrity_check` with
/// `wrong # of entries in index …` / `row N missing from index …`, and the
/// import then rejects the whole archive with `history.db failed SQLite
/// integrity check` — which is what a fresh app hit after a WebDAV round trip.
///
/// The export now copies through SQLite's online backup API, so the archive
/// always carries a transactionally consistent database.

const String _historySchema = '''
  CREATE TABLE history (
    id TEXT PRIMARY KEY, title TEXT, subtitle TEXT, cover TEXT, time INTEGER,
    type INTEGER, ep INTEGER, page INTEGER, readEpisode TEXT, max_page INTEGER
  )
''';

const String _insertHistory =
    'INSERT INTO history VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

List<Object?> _row(int index, String prefix) => [
  '$prefix$index',
  'title-$index',
  '',
  '',
  1,
  1,
  1,
  1,
  '',
  1,
];

String _integrityOf(String path) {
  final db = sqlite3.open(path);
  try {
    final result = db.select('PRAGMA integrity_check');
    return result.isEmpty ? '<empty>' : result.first.values.first.toString();
  } on SqliteException catch (error) {
    // Badly damaged images are reported by throwing instead of by returning
    // problem rows; both mean "not ok".
    return 'threw:${error.resultCode}';
  } finally {
    db.dispose();
  }
}

int _rowCount(String path) {
  final db = sqlite3.open(path);
  try {
    return db.select('SELECT COUNT(*) FROM history').first.values.first as int;
  } finally {
    db.dispose();
  }
}

/// A `history` database with [committed] finished rows and an **open** write
/// transaction whose inserts have already spilled into the file.
///
/// The spilled pages are the point: they are what a concurrent reader sees as a
/// half-applied transaction.  The returned connection owns the transaction, so
/// the caller decides when it commits and must dispose it.  [onPending] runs
/// after each uncommitted insert, which is where a test samples the file the way
/// the old export did.
Database _historyUnderTransaction(
  String path, {
  int committed = 600,
  void Function(int index)? onPending,
}) {
  final db = sqlite3.open(path);
  db.execute('PRAGMA cache_size = 1');
  db.execute(_historySchema);
  final done = db.prepare(_insertHistory);
  for (var i = 0; i < committed; i++) {
    done.execute(_row(i, 'c'));
  }
  done.dispose();

  db.execute('BEGIN IMMEDIATE');
  final pending = db.prepare(_insertHistory);
  for (var i = 0; i < 400; i++) {
    pending.execute(_row(i, 'u'));
    onPending?.call(i);
  }
  pending.dispose();
  return db;
}

void _seedHistory(String path, {int rows = 600}) {
  final db = sqlite3.open(path);
  try {
    db.execute(_historySchema);
    final insert = db.prepare(_insertHistory);
    for (var i = 0; i < rows; i++) {
      insert.execute(_row(i, 'c'));
    }
    insert.dispose();
  } finally {
    db.dispose();
  }
}

Future<File> _zip(Directory root, Map<String, List<int>> files) async {
  final archive = Archive();
  for (final item in files.entries) {
    archive.addFile(ArchiveFile(item.key, item.value.length, item.value));
  }
  final file = File('${root.path}/backup.venera');
  await file.writeAsBytes(ZipEncoder().encode(archive));
  return file;
}

void main() {
  test('a quiet database is snapshotted', () async {
    final root = await Directory.systemTemp.createTemp('backup-quiet-');
    addTearDown(() => root.delete(recursive: true));
    final live = '${root.path}/history.db';
    final snapshot = '${root.path}/snapshot.db';
    _seedHistory(live);

    final copied = await writeSqliteBackupSnapshot(
      sourcePath: live,
      destinationPath: snapshot,
      entryName: 'history.db',
    );

    expect(copied, isTrue);
    expect(_integrityOf(snapshot), 'ok');
    expect(_rowCount(snapshot), 600);
  });

  test(
    'a database written during the copy is snapshotted consistently',
    () async {
      final root = await Directory.systemTemp.createTemp('backup-live-');
      addTearDown(() => root.delete(recursive: true));
      final live = '${root.path}/history.db';
      final snapshot = '${root.path}/snapshot.db';
      final writer = _historyUnderTransaction(live);
      addTearDown(writer.dispose);

      // The writer commits while the copy is running — how a real device looks
      // when the user reads a comic during a WebDAV upload.
      final commit = Future<void>.delayed(
        const Duration(milliseconds: 400),
        () {
          writer.execute('COMMIT');
        },
      );

      final copied = await writeSqliteBackupSnapshot(
        sourcePath: live,
        destinationPath: snapshot,
        entryName: 'history.db',
      );
      await commit;

      expect(copied, isTrue);
      expect(_integrityOf(snapshot), 'ok');
      expect(
        _rowCount(snapshot),
        anyOf(600, 1000),
        reason:
            'the snapshot is the state before or after the commit, never a '
            'half-applied transaction',
      );
    },
  );

  test(
    'a database that stays locked fails the export instead of hanging it',
    () async {
      final root = await Directory.systemTemp.createTemp('backup-locked-');
      addTearDown(() => root.delete(recursive: true));
      final live = '${root.path}/history.db';
      final writer = _historyUnderTransaction(live);
      addTearDown(writer.dispose);

      await expectLater(
        writeSqliteBackupSnapshot(
          sourcePath: live,
          destinationPath: '${root.path}/snapshot.db',
          entryName: 'history.db',
          timeout: const Duration(milliseconds: 300),
        ),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'the torn copy the export used to make is rejected by the import',
    () async {
      final root = await Directory.systemTemp.createTemp('backup-torn-');
      addTearDown(() => root.delete(recursive: true));
      final live = '${root.path}/history.db';
      final torn = '${root.path}/torn.db';
      final snapshot = '${root.path}/snapshot.db';

      // The old export: read the file while its transaction is still open.
      // Copies are sampled at several instants — whether a given one is torn
      // depends on where the page cache had spilled — and the first torn one is
      // what the old export could upload without noticing.
      final samples = <List<int>>[];
      final writer = _historyUnderTransaction(
        live,
        onPending: (index) {
          if (index % 10 == 0) {
            samples.add(File(live).readAsBytesSync());
          }
        },
      );
      // Disposing twice is harmless; this also runs when an expectation above
      // fails, so the connection cannot keep the directory locked.
      addTearDown(() {
        try {
          writer.dispose();
        } on Object {
          // already closed
        }
      });

      List<int>? tornBytes;
      for (final sample in samples) {
        File(torn).writeAsBytesSync(sample);
        if (_integrityOf(torn) != 'ok') {
          tornBytes = sample;
          break;
        }
      }
      expect(
        tornBytes,
        isNotNull,
        reason: 'a file copy taken mid-transaction is not a backup',
      );
      File(torn).writeAsBytesSync(tornBytes!);

      // The new export: a consistent snapshot of the same live database.
      writer.execute('ROLLBACK');
      writer.dispose();
      final copied = await writeSqliteBackupSnapshot(
        sourcePath: live,
        destinationPath: snapshot,
        entryName: 'history.db',
      );
      expect(copied, isTrue);
      expect(_integrityOf(snapshot), 'ok');

      final wasInitialized = App.isInitialized;
      final oldDataPath = wasInitialized ? App.dataPath : null;
      final oldCachePath = wasInitialized ? App.cachePath : null;
      App.dataPath = '${root.path}/data';
      App.cachePath = '${root.path}/cache';
      await Directory(App.dataPath).create(recursive: true);
      await Directory(App.cachePath).create(recursive: true);
      addTearDown(() {
        if (wasInitialized) {
          App.dataPath = oldDataPath!;
          App.cachePath = oldCachePath!;
        }
      });

      final fromSnapshot = await _zip(root, {
        'history.db': await File(snapshot).readAsBytes(),
      });
      await importAppData(fromSnapshot);
      expect(
        _integrityOf('${App.dataPath}/history.db'),
        'ok',
        reason: 'the archive the export now produces imports cleanly',
      );
      expect(_rowCount('${App.dataPath}/history.db'), 600);

      await File('${App.dataPath}/history.db').delete();
      final fromTornCopy = await _zip(root, {
        'history.db': await File(torn).readAsBytes(),
      });
      await expectLater(
        importAppData(fromTornCopy),
        throwsA(
          anyOf(
            // Depending on where the page cache spilled, SQLite reports the
            // damage as problem rows from `integrity_check` (the message the
            // user saw) or as a malformed image.  Both must be refused.
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('history.db failed SQLite integrity check'),
            ),
            isA<SqliteException>().having(
              (error) => error.message,
              'message',
              contains('malformed'),
            ),
          ),
        ),
      );
    },
  );

  test('a missing or unusable database is left out instead of poisoning the '
      'archive', () async {
    final root = await Directory.systemTemp.createTemp('backup-absent-');
    addTearDown(() => root.delete(recursive: true));

    expect(
      await writeSqliteBackupSnapshot(
        sourcePath: '${root.path}/never-written.db',
        destinationPath: '${root.path}/copy.db',
        entryName: 'history.db',
      ),
      isFalse,
      reason: 'a device that never wrote history has nothing to back up',
    );

    // An empty database is a real SQLite file but has no `history` table, so
    // the import would reject it; it must not be exported either.
    final empty = '${root.path}/empty.db';
    sqlite3.open(empty).dispose();
    expect(
      await writeSqliteBackupSnapshot(
        sourcePath: empty,
        destinationPath: '${root.path}/empty-copy.db',
        entryName: 'history.db',
      ),
      isFalse,
    );
  });
}
