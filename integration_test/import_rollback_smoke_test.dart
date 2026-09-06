import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/utils/data.dart';

import '../test/catalog/import_rollback_cases.dart';

Future<File> _zip(Directory root, Map<String, List<int>> files) async {
  final archive = Archive();
  for (final item in files.entries) {
    archive.addFile(ArchiveFile(item.key, item.value.length, item.value));
  }
  final file = File(p.join(root.path, 'import-rollback.venera'));
  await file.writeAsBytes(ZipEncoder().encode(archive));
  return file;
}

void _createHistory(String path, String id) {
  final db = sqlite3.open(path);
  try {
    db.execute('''
      CREATE TABLE history (
        id TEXT PRIMARY KEY, title TEXT, subtitle TEXT, cover TEXT,
        time INTEGER, type INTEGER, ep INTEGER, page INTEGER,
        readEpisode TEXT, max_page INTEGER
      );
    ''');
    db.execute(
      'INSERT INTO history (id,title,subtitle,cover,time,type,ep,page,readEpisode,max_page) VALUES (?,?,?,?,?,?,?,?,?,?)',
      [id, id, '', '', 1, 1, 1, 1, '', 1],
    );
  } finally {
    db.dispose();
  }
}

void _createCookies(String path, String value) {
  final db = sqlite3.open(path);
  try {
    db.execute('''
      CREATE TABLE cookies (
        name TEXT NOT NULL, value TEXT NOT NULL, domain TEXT NOT NULL,
        path TEXT, expires INTEGER, secure INTEGER, httpOnly INTEGER,
        PRIMARY KEY (name, domain, path)
      );
    ''');
    db.execute(
      'INSERT INTO cookies (name,value,domain,path,expires,secure,httpOnly) VALUES (?,?,?,?,?,?,?)',
      ['session', value, 'example.test', '/', null, 0, 0],
    );
  } finally {
    db.dispose();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows partial import failure keeps history usable', (_) async {
    await verifyPartialImportFailure(payload: 'appdata.json');
    await verifyPartialImportFailure(
      payload: 'comic_source/demo.data',
      failOriginalRead: true,
    );
  });

  testWidgets(
    'Windows import failure after database replacement restores open user state',
    (_) async {
      final root = await Directory.systemTemp.createTemp(
        'venera-import-rollback-windows-',
      );
      final oldDataPath = App.isInitialized ? App.dataPath : null;
      final oldCachePath = App.isInitialized ? App.cachePath : null;
      final historyManager = HistoryManager();
      final oldHistoryInitialized = historyManager.isInitialized;
      final oldCookie = SingleInstanceCookieJar.instance;
      App.dataPath = root.path;
      App.cachePath = p.join(root.path, 'cache');
      await Directory(App.cachePath).create(recursive: true);

      final oldHistory = p.join(root.path, 'history.db');
      final oldCookiePath = p.join(root.path, 'cookie.db');
      final importedRoot = await Directory(
        p.join(root.path, 'payload'),
      ).create();
      _createHistory(oldHistory, 'before');
      _createCookies(oldCookiePath, 'before');
      await historyManager.init();
      SingleInstanceCookieJar.instance = SingleInstanceCookieJar(oldCookiePath);
      final appdataFile = File(p.join(root.path, 'appdata.json'));
      await appdataFile.writeAsString(
        jsonEncode({
          'settings': {
            'enabledSources': <String>['copy_manga'],
          },
        }),
        flush: true,
      );

      final importedHistory = p.join(importedRoot.path, 'history.db');
      final importedCookie = p.join(importedRoot.path, 'cookie.db');
      _createHistory(importedHistory, 'after');
      _createCookies(importedCookie, 'after');
      final backup = await _zip(root, {
        'history.db': await File(importedHistory).readAsBytes(),
        'cookie.db': await File(importedCookie).readAsBytes(),
        'appdata.json': utf8.encode(
          jsonEncode({
            'settings': {
              'enabledSources': <String>['copy_manga'],
            },
          }),
        ),
      });

      var failAppdataOnce = true;
      appdata.atomicReplace = (source, target) async {
        if (p.basename(target.path) == 'appdata.json' && failAppdataOnce) {
          failAppdataOnce = false;
          throw const FileSystemException('injected post-database failure');
        }
        final previous = appdata.atomicReplace;
        appdata.atomicReplace = null;
        try {
          await appdata.replaceFileAtomically(source, target);
        } finally {
          appdata.atomicReplace = previous;
        }
      };
      try {
        await expectLater(
          importAppData(backup),
          throwsA(isA<FileSystemException>()),
        );
        expect(historyManager.isInitialized, isTrue);
        expect(historyManager.count(), 1);
        expect(historyManager.getAll().single.id, 'before');
        expect(
          SingleInstanceCookieJar.instance!.loadForRequestCookieHeader(
            Uri.parse('https://example.test/'),
          ),
          contains('session=before'),
        );
        expect(await appdataFile.readAsString(), contains('copy_manga'));

        // The same files can be imported after recovery, proving no stale native
        // handle or write lock survived the failed transaction.
        appdata.atomicReplace = null;
        await importAppData(backup);
        expect(historyManager.count(), 1);
        expect(historyManager.getAll().single.id, 'after');
      } finally {
        appdata.atomicReplace = null;
        if (SingleInstanceCookieJar.instance != null) {
          SingleInstanceCookieJar.instance!.dispose();
        }
        historyManager.close();
        if (oldCookie != null) SingleInstanceCookieJar.instance = oldCookie;
        if (oldHistoryInitialized && oldDataPath != null) {
          // The test's global singleton cannot safely be reopened against the
          // caller's profile here; normal integration runs start in isolation.
          App.dataPath = oldDataPath;
        }
        if (oldCachePath != null) App.cachePath = oldCachePath;
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
  );
}
