import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/data.dart';

import 'import_rollback_cases.dart';

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
  for (final payload in [
    'appdata.json',
    'cookie.db',
    'comic_source/demo.data',
  ]) {
    for (final open in [true, false]) {
      test(
        'partial import $payload failure preserves history open=$open',
        () => verifyPartialImportFailure(payload: payload, historyOpen: open),
      );
    }
  }
  test(
    'original read failure leaves unrelated history open and releases commit',
    () => verifyPartialImportFailure(
      payload: 'comic_source/demo.data',
      failOriginalRead: true,
    ),
  );

  test(
    'import ignores runtime scripts and rejects unsafe archive paths',
    () async {
      final root = await Directory.systemTemp.createTemp('catalog-import-');
      addTearDown(() => root.delete(recursive: true));
      final wasInitialized = App.isInitialized;
      final oldDataPath = wasInitialized ? App.dataPath : null;
      final oldCachePath = wasInitialized ? App.cachePath : null;
      App.dataPath = '${root.path}/data';
      App.cachePath = '${root.path}/cache';
      await Directory(App.cachePath).create(recursive: true);
      addTearDown(() {
        if (wasInitialized) {
          App.dataPath = oldDataPath!;
          App.cachePath = oldCachePath!;
        }
      });

      final scripts = await _zip(root, {
        'comic_source/source.js': utf8.encode('globalThis.sideEffect = true;'),
      });
      final result = await importAppData(scripts);
      expect(result.sourceImported, isFalse);
      expect(
        File('${App.dataPath}/comic_source/source.js').existsSync(),
        isFalse,
      );

      final unsafe = await _zip(root, {
        'comic_source/../escape.data': utf8.encode('{}'),
      });
      expect(() => importAppData(unsafe), throwsA(isA<FormatException>()));
    },
  );

  test(
    'bad databases, bad source data, and replace failures preserve data',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'catalog-import-safety-',
      );
      addTearDown(() => root.delete(recursive: true));
      App.dataPath = '${root.path}/data';
      App.cachePath = '${root.path}/cache';
      await Directory(App.dataPath).create(recursive: true);
      await Directory(App.cachePath).create(recursive: true);
      await Directory('${App.dataPath}/comic_source').create(recursive: true);

      final history = File('${App.dataPath}/history.db');
      final cookie = File('${App.dataPath}/cookie.db');
      final source = File('${App.dataPath}/comic_source/demo.data');
      await history.writeAsString('old history');
      await cookie.writeAsString('old cookie');
      await source.writeAsString('{"account":["user","password"]}');

      final invalidDb = await _zip(root, {
        'history.db': utf8.encode('not a sqlite database'),
      });
      expect(() => importAppData(invalidDb), throwsA(isA<Object>()));
      expect(await history.readAsString(), 'old history');
      expect(await cookie.readAsString(), 'old cookie');
      expect(await source.readAsString(), '{"account":["user","password"]}');

      final invalidSource = await _zip(root, {
        'comic_source/demo.data': utf8.encode('{invalid'),
      });
      expect(() => importAppData(invalidSource), throwsA(isA<Object>()));
      expect(await source.readAsString(), '{"account":["user","password"]}');

      final validDbPath = '${root.path}/valid.db';
      final db = sqlite3.open(validDbPath);
      db.execute('''
        CREATE TABLE history (
          id TEXT PRIMARY KEY, title TEXT, subtitle TEXT, cover TEXT,
          time INTEGER, type INTEGER, ep INTEGER, page INTEGER,
          readEpisode TEXT, max_page INTEGER
        )
      ''');
      db.dispose();
      final validDb = await File(validDbPath).readAsBytes();
      final replacementFailure = await _zip(root, {'history.db': validDb});
      appdata.atomicReplace = (_, _) async {
        throw const FileSystemException('injected replace failure');
      };
      addTearDown(() => appdata.atomicReplace = null);
      expect(
        () => importAppData(replacementFailure),
        throwsA(isA<FileSystemException>()),
      );
      expect(await history.readAsString(), 'old history');
    },
  );
}
