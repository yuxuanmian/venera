import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/utils/data.dart';

final class _FailOriginalRead extends IOOverrides {
  _FailOriginalRead(this.target);
  final String target;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return p.equals(path, target) ? _UnreadableFile(file) : file;
  }
}

class _UnreadableFile implements File {
  _UnreadableFile(this.file);
  final File file;
  @override
  String get path => file.path;
  @override
  Directory get parent => file.parent;
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<Uint8List> readAsBytes() async =>
      throw const FileSystemException('injected original read failure');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Shared by host tests and the native Windows runner. All databases are real;
/// only the selected I/O failure is injected.
Future<void> verifyPartialImportFailure({
  required String payload,
  bool historyOpen = true,
  bool failOriginalRead = false,
}) async {
  final root = await Directory.systemTemp.createTemp('partial-import-');
  final oldData = App.isInitialized ? App.dataPath : null;
  final oldCache = App.isInitialized ? App.cachePath : null;
  final oldHistory = HistoryManager.cache;
  final oldCookie = SingleInstanceCookieJar.instance;
  final oldHook = appdata.atomicReplace;
  final oldDocument = appdata.toJson();
  App.dataPath = root.path;
  App.cachePath = '${root.path}/cache';
  await Directory(App.cachePath).create();
  HistoryManager.cache = HistoryManager.create();
  SingleInstanceCookieJar.instance = null;
  final history = HistoryManager();
  try {
    await history.init();
    final before = History.fromMap({
      'id': 'before',
      'title': 'before',
      'subtitle': '',
      'cover': '',
      'time': 1,
      'type': 1,
      'ep': 1,
      'page': 1,
      'readEpisode': <String>[],
    });
    history.addHistory(before);
    if (!historyOpen) history.close();
    final cookie = SingleInstanceCookieJar('${root.path}/cookie.db');
    final uri = Uri.parse('https://example.test/');
    cookie.saveFromResponse(uri, [Cookie('session', 'before')]);
    final document = File('${root.path}/appdata.json');
    await document.writeAsString(jsonEncode(oldDocument));
    final originalDocument = await document.readAsBytes();
    final source = File('${root.path}/comic_source/demo.data');
    await source.parent.create();
    await source.writeAsString('{"marker":"before"}');

    List<int> bytes;
    if (payload == 'cookie.db') {
      final db = sqlite3.open('${root.path}/payload.db');
      db.execute(
        'CREATE TABLE cookies (name TEXT, value TEXT, domain TEXT, '
        'path TEXT, expires INTEGER, secure INTEGER, httpOnly INTEGER)',
      );
      db.dispose();
      bytes = await File('${root.path}/payload.db').readAsBytes();
    } else {
      bytes = utf8.encode(
        payload == 'appdata.json'
            ? '{"settings":{"enabledSources":[]}}'
            : '{"marker":"after"}',
      );
    }
    final archive = Archive()
      ..addFile(ArchiveFile(payload, bytes.length, bytes));
    // The read-failure case also owns an appdata handle before reading originals.
    if (failOriginalRead) {
      final settings = utf8.encode('{"settings":{"enabledSources":[]}}');
      archive.addFile(ArchiveFile('appdata.json', settings.length, settings));
    }
    final backup = File('${root.path}/partial.venera');
    await backup.writeAsBytes(ZipEncoder().encode(archive));
    var failOnce = true;
    appdata.atomicReplace = (from, to) async {
      if (failOnce && p.equals(to.path, p.join(root.path, payload))) {
        failOnce = false;
        throw const FileSystemException('injected partial import failure');
      }
      final hook = appdata.atomicReplace;
      appdata.atomicReplace = null;
      try {
        await appdata.replaceFileAtomically(from, to);
      } finally {
        appdata.atomicReplace = hook;
      }
    };
    final attempt = failOriginalRead
        ? IOOverrides.runWithIOOverrides(
            () => importAppData(backup),
            _FailOriginalRead(source.path),
          )
        : importAppData(backup);
    await expectLater(attempt, throwsA(isA<FileSystemException>()));
    expect(history.hasOpenConnection, historyOpen);
    expect(history.isInitialized, historyOpen);
    if (!historyOpen) await history.init();
    expect(history.getAll().single.id, 'before');
    before.id = 'after-failure';
    history.addHistory(before);
    expect(history.count(), 2);
    expect(SingleInstanceCookieJar.instance!.hasOpenConnection, isTrue);
    expect(
      SingleInstanceCookieJar.instance!.loadForRequestCookieHeader(uri),
      contains('session=before'),
    );
    expect(await document.readAsBytes(), originalDocument);
    expect(await source.readAsString(), '{"marker":"before"}');
    appdata.atomicReplace = null;
    await appdata.saveData(false).timeout(const Duration(seconds: 3));
    await importAppData(backup).timeout(const Duration(seconds: 3));
    expect(history.count(), 2);
  } finally {
    appdata.atomicReplace = oldHook;
    history.close();
    SingleInstanceCookieJar.instance?.dispose();
    HistoryManager.cache = oldHistory;
    SingleInstanceCookieJar.instance = oldCookie;
    for (final entry in (oldDocument['settings'] as Map).entries) {
      appdata.settings[entry.key as String] = entry.value;
    }
    appdata.searchHistory = List<String>.from(
      oldDocument['searchHistory'] as List,
    );
    if (oldData != null) App.dataPath = oldData;
    if (oldCache != null) App.cachePath = oldCache;
    await root.delete(recursive: true);
  }
}
