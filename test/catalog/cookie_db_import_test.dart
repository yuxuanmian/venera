import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/utils/data.dart';

/// Regression: importing a backup used to replace the cookie-jar singleton with
/// a **new object**.
///
/// The jar object is captured by `AppDio`'s cookie interceptor
/// (`network/app_dio.dart:204`) and cached by the JS engine's `Network` bridge
/// (`foundation/js_engine.dart:120`), so replacing the singleton left those
/// holders pointing at a closed database: every source request after an import
/// failed with `Bad state: cookie database is not initialized` — login,
/// favorites, search and scan all broke until the app was restarted, because
/// only a new process rebuilt the jar.
///
/// The import now closes the connection and reopens the **same** object onto the
/// replaced file, which is what `history.db` already did.

const String _cookieSchema = '''
  CREATE TABLE cookies (
    name TEXT NOT NULL,
    value TEXT NOT NULL,
    domain TEXT NOT NULL,
    path TEXT,
    expires INTEGER,
    secure INTEGER,
    httpOnly INTEGER,
    PRIMARY KEY (name, domain, path)
  )
''';

void _seedCookieDatabase(
  String path, {
  required String name,
  required String value,
}) {
  final db = sqlite3.open(path);
  try {
    db.execute(_cookieSchema);
    db.execute(
      'INSERT INTO cookies (name, value, domain, path, secure, httpOnly) '
      'VALUES (?, ?, ?, ?, 0, 0)',
      [name, value, 'manwa.me', '/'],
    );
  } finally {
    db.dispose();
  }
}

Future<File> _zipCookieDatabase(Directory root, List<int> bytes) async {
  final archive = Archive();
  archive.addFile(ArchiveFile('cookie.db', bytes.length, bytes));
  final file = File('${root.path}/backup.venera');
  await file.writeAsBytes(ZipEncoder().encode(archive));
  return file;
}

void main() {
  final uri = Uri.parse('https://manwa.me/');
  late Directory root;
  late SingleInstanceCookieJar jar;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cookie-import-');
    App.dataPath = '${root.path}/data';
    App.cachePath = '${root.path}/cache';
    await Directory(App.dataPath).create(recursive: true);
    await Directory(App.cachePath).create(recursive: true);
    // Build the singleton against this test's directory instead of the real
    // application support directory.
    SingleInstanceCookieJar.instance = null;
    jar = SingleInstanceCookieJar('${App.dataPath}/cookie.db');
    // Seeded through the same entry point the app uses for `set-cookie`
    // (`CookieManagerSql.onResponse`).
    jar.saveFromResponseCookieHeader(uri, [
      'session=before; Domain=manwa.me; Path=/',
    ]);
  });

  tearDown(() {
    SingleInstanceCookieJar.instance?.dispose();
    SingleInstanceCookieJar.instance = null;
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // SQLite may release a native handle just after dispose (Windows).
    }
  });

  test('an imported cookie.db keeps the captured jar usable', () async {
    // What `AppDio` does once, when it is constructed.
    final capturedByDio = jar;
    expect(capturedByDio.loadForRequestCookieHeader(uri), contains('before'));

    final imported = '${root.path}/imported-cookie.db';
    _seedCookieDatabase(imported, name: 'session', value: 'after');
    final archive = await _zipCookieDatabase(
      root,
      await File(imported).readAsBytes(),
    );

    await importAppData(archive);

    expect(
      identical(SingleInstanceCookieJar.instance, capturedByDio),
      isTrue,
      reason: 'the singleton must keep its identity across an import',
    );
    expect(
      capturedByDio.loadForRequestCookieHeader(uri),
      contains('after'),
      reason:
          'the captured jar must be reopened onto the imported file, not left '
          'closed or pointing at the replaced one',
    );
  });

  test('replacing the singleton instead would strand its holders', () {
    final capturedByDio = jar;

    // The old import path: dispose the singleton, then build a new one.
    jar.dispose();
    SingleInstanceCookieJar.instance = SingleInstanceCookieJar(
      '${App.dataPath}/cookie.db',
    );

    expect(
      () => capturedByDio.loadForRequestCookieHeader(uri),
      throwsStateError,
      reason:
          'this is the failure the import used to cause for the rest of the '
          'session: `cookie database is not initialized`',
    );
  });
}
