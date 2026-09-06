import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/utils/data.dart';

Future<File> _archive(Directory root, Map<String, List<int>> files) async {
  final archive = Archive();
  for (final item in files.entries) {
    archive.addFile(ArchiveFile(item.key, item.value.length, item.value));
  }
  final file = File('${root.path}/database-lifecycle.venera');
  await file.writeAsBytes(ZipEncoder().encode(archive));
  return file;
}

void _createHistoryView(String path) {
  final db = sqlite3.open(path);
  try {
    db.execute('''
      CREATE VIEW history AS SELECT
        'view-id' AS id, 'title' AS title, '' AS subtitle, '' AS cover,
        1 AS time, 1 AS type, 1 AS ep, 1 AS page,
        '' AS readEpisode, 1 AS max_page;
    ''');
  } finally {
    db.dispose();
  }
}

void _createValidHistory(String path, {String id = 'original'}) {
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
      [id, 'Title', '', '', 1, 1, 1, 1, '', 1],
    );
  } finally {
    db.dispose();
  }
}

void main() {
  test(
    'half-initialized history connection is released and retryable',
    () async {
      final root = await Directory.systemTemp.createTemp('catalog-db-life-');
      addTearDown(() async {
        HistoryManager().close();
        HistoryManager.cache = null;
        await root.delete(recursive: true);
      });
      App.dataPath = root.path;

      final path = '${root.path}/history.db';
      _createHistoryView(path);
      final manager = HistoryManager();
      expect(manager.isInitialized, isFalse);
      expect(() => manager.init(), throwsA(isA<Exception>()));
      expect(manager.isInitialized, isFalse);
      expect(manager.hasOpenConnection, isFalse);
      expect(() => manager.close(), returnsNormally);

      File(path).deleteSync();
      _createValidHistory(path);
      await manager.init();
      expect(manager.isInitialized, isTrue);
      expect(manager.count(), 1);
      manager.close();
      expect(manager.hasOpenConnection, isFalse);
      expect(() => manager.close(), returnsNormally);
    },
  );

  test(
    'view-shaped history backup is rejected before destination replacement',
    () async {
      final root = await Directory.systemTemp.createTemp('catalog-db-view-');
      addTearDown(() async {
        HistoryManager().close();
        HistoryManager.cache = null;
        await root.delete(recursive: true);
      });
      App.dataPath = '${root.path}/data';
      App.cachePath = '${root.path}/cache';
      await Directory(App.dataPath).create(recursive: true);
      await Directory(App.cachePath).create(recursive: true);

      final target = File('${App.dataPath}/history.db');
      await target.writeAsString('old-history');
      final cookie = File('${App.dataPath}/cookie.db');
      await cookie.writeAsString('old-cookie');
      final account = File('${App.dataPath}/comic_source/account.data');
      await account.parent.create(recursive: true);
      await account.writeAsString('{"account":"old"}');
      final appdataFile = File('${App.dataPath}/appdata.json');
      await appdataFile.writeAsString('{"settings":{"marker":"old"}}');
      final viewDb = '${root.path}/view.db';
      _createHistoryView(viewDb);
      final archive = await _archive(root, {
        'history.db': await File(viewDb).readAsBytes(),
      });

      expect(() => importAppData(archive), throwsA(isA<FormatException>()));
      expect(await target.readAsString(), 'old-history');
      expect(await cookie.readAsString(), 'old-cookie');
      expect(await account.readAsString(), '{"account":"old"}');
      expect(await appdataFile.readAsString(), '{"settings":{"marker":"old"}}');
    },
  );
}
