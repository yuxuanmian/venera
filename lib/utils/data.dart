import 'dart:convert';
import 'dart:isolate';

import 'package:archive/archive.dart' hide ZipFile;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/utils/ext.dart';
import 'package:zip_flutter/zip_flutter.dart';

import 'io.dart';

class AppDataImportResult {
  const AppDataImportResult({this.sourceImported = false});

  final bool sourceImported;
}

Future<File> exportAppData([bool sync = true]) async {
  var time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  var cacheFilePath = FilePath.join(App.cachePath, '$time.venera');
  var cacheFile = File(cacheFilePath);
  var dataPath = App.dataPath;
  if (await cacheFile.exists()) {
    await cacheFile.delete();
  }
  final projectedPath = FilePath.join(App.cachePath, '$time-export.json');
  final projected = File(projectedPath);
  await projected.writeAsString(
    jsonEncode(appdata.toUserDataJson()),
    flush: true,
  );
  await Isolate.run(() {
    var zipFile = ZipFile.open(cacheFilePath);
    var historyFile = FilePath.join(dataPath, "history.db");
    var cookies = FilePath.join(dataPath, "cookie.db");
    zipFile.addFile("history.db", historyFile);
    zipFile.addFile("appdata.json", projectedPath);
    zipFile.addFile("cookie.db", cookies);
    final sourceRoot = Directory(FilePath.join(dataPath, 'comic_source'));
    if (sourceRoot.existsSync()) {
      for (final entity in sourceRoot.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final fileName = p.basename(entity.path);
        if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*\.data$').hasMatch(fileName)) {
          continue;
        }
        zipFile.addFile('comic_source/$fileName', entity.path);
      }
    }
    zipFile.close();
  });
  await projected.deleteIgnoreError();
  return cacheFile;
}

Future<AppDataImportResult> importAppData(
  File file, [
  bool checkVersion = false,
]) async {
  var sourceImported = false;
  final cacheDir = await Directory(App.cachePath).createTemp('source-import-');
  final staged = <_StagedImport>[];
  PreparedAppDataCommit? userCommit;
  try {
    final archive = await _readImportArchive(file);
    final entries = <String, ArchiveFile>{};
    for (final entry in archive.files) {
      final name = _validateArchiveEntry(entry);
      if (!entry.isFile) continue;
      if (entries.containsKey(name)) {
        throw const FormatException('archive contains duplicate paths');
      }
      entries[name] = entry;
    }

    ArchiveFile? entry(String name) => entries[name];
    final appdataEntry = entry('appdata.json') ?? entry('syncdata.json');
    Map<String, dynamic>? importedDocument;
    if (appdataEntry != null) {
      final decoded = jsonDecode(
        utf8.decode(appdataEntry.content as List<int>),
      );
      if (decoded is! Map) {
        throw const FormatException('appdata in archive is not an object');
      }
      importedDocument = Map<String, dynamic>.from(decoded);
    }
    _validateImportedDocument(importedDocument);
    if (checkVersion && importedDocument != null) {
      final data = importedDocument;
      final persistedSettings = data['settings'];
      final version = persistedSettings is Map
          ? persistedSettings['dataVersion']
          : null;
      if (version is int && version <= appdata.settings["dataVersion"]) {
        return const AppDataImportResult();
      }
    }

    final historyEntry = entry('history.db');
    if (historyEntry != null) {
      final target = File(FilePath.join(App.dataPath, 'history.db'));
      final bytes = List<int>.from(historyEntry.content as List<int>);
      final stage = await _stageAdjacent(target, bytes);
      try {
        _validateSqlite(stage, 'history.db');
      } catch (_) {
        await stage.deleteIgnoreError();
        rethrow;
      }
      staged.add(_StagedImport(target: target, stage: stage));
    }
    final cookieEntry = entry('cookie.db');
    if (cookieEntry != null) {
      final cookiePath = FilePath.join(App.dataPath, "cookie.db");
      final target = File(cookiePath);
      final stage = await _stageAdjacent(
        target,
        List<int>.from(cookieEntry.content as List<int>),
      );
      try {
        _validateSqlite(stage, 'cookie.db');
      } catch (_) {
        await stage.deleteIgnoreError();
        rethrow;
      }
      staged.add(_StagedImport(target: target, stage: stage));
    }
    final sourceRoot = Directory(FilePath.join(App.dataPath, "comic_source"));
    for (final item in entries.entries) {
      if (!item.key.startsWith('comic_source/')) continue;
      final fileName = item.key.substring('comic_source/'.length);
      if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*\.data$').hasMatch(fileName)) {
        // JS, registry, candidate and legacy state files are deliberately
        // ignored, even when they are otherwise safe archive paths.
        continue;
      }
      final destination = File(FilePath.join(sourceRoot.path, fileName));
      final key = fileName.substring(0, fileName.length - '.data'.length);
      final bytes = List<int>.from(item.value.content as List<int>);
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        throw FormatException('$fileName must contain a JSON object');
      }
      final stage = await _stageAdjacent(destination, bytes);
      staged.add(
        _StagedImport(
          target: destination,
          stage: stage,
          sourceKey: key,
          decodedSourceData: Map<String, dynamic>.from(decoded),
        ),
      );
    }

    // Prepare the merged appdata document before changing any destination
    // file. The write lock also prevents a concurrent settings save from
    // changing the basis for this import.
    if (importedDocument != null) {
      userCommit = await appdata.prepareUserDataCommit(importedDocument);
    }

    final replaced = <_OriginalImportFile>[];
    final historyManager = HistoryManager();
    final historyWasOpen = historyManager.hasOpenConnection;
    final cookieWasOpen = SingleInstanceCookieJar.instance != null;
    var historyClosed = false;
    var historyReplaced = false;
    var cookieClosed = false;
    try {
      for (final item in staged) {
        replaced.add(
          _OriginalImportFile(
            target: item.target,
            bytes: await item.target.exists()
                ? await item.target.readAsBytes()
                : null,
          ),
        );
      }
      if (staged.any((item) => p.basename(item.target.path) == 'history.db')) {
        if (historyManager.hasOpenConnection) {
          historyManager.close();
          historyClosed = true;
        }
      }
      if (staged.any((item) => p.basename(item.target.path) == 'cookie.db')) {
        final cookie = SingleInstanceCookieJar.instance;
        if (cookie != null) {
          cookie.dispose();
          cookieClosed = true;
        }
      }
      for (final item in staged) {
        await appdata.replaceFileAtomically(item.stage, item.target);
        item.replaced = true;
        if (p.basename(item.target.path) == 'history.db') {
          historyReplaced = true;
        }
      }
      if (historyReplaced && historyWasOpen) {
        await historyManager.init();
      }
      if (cookieClosed) {
        final cookiePath = FilePath.join(App.dataPath, 'cookie.db');
        SingleInstanceCookieJar.instance = SingleInstanceCookieJar(cookiePath);
      }
      if (importedDocument != null) {
        // The document was validated and prepared before any target file was
        // touched. Replace it only after imported databases have reopened so a
        // normal failure can restore the old files and appdata independently.
        final commit = userCommit!;
        await commit.replace();
        commit.installMemorySilently();
        commit.release();
        appdata.notifyMemoryChanged();
        userCommit = null;
      }
      for (final item in staged) {
        if (item.sourceKey == null || item.decodedSourceData == null) continue;
        final source = ComicSource.find(item.sourceKey!);
        if (source != null) {
          source.data = Map<String, dynamic>.from(item.decodedSourceData!);
        }
        sourceImported = true;
      }
      if (sourceImported) ComicSourceManager().notifyStateChange();
    } catch (_) {
      // Imported databases may have been opened successfully before a later
      // appdata replacement failed. Close those new handles before restoring
      // the original files; this is required for Windows rename semantics.
      // Only this import's connections need closing. A partial backup or an
      // original-file read failure must not shut down unrelated history work.
      if ((historyClosed || historyReplaced) &&
          historyManager.hasOpenConnection) {
        historyManager.close();
      }
      if (cookieClosed) {
        SingleInstanceCookieJar.instance?.dispose();
        SingleInstanceCookieJar.instance = null;
      }
      if (userCommit != null && !userCommit.isReleased) {
        try {
          await userCommit.rollback();
        } catch (error, stack) {
          Log.error('Import Data', 'Failed to restore appdata: $error', stack);
        }
      }
      for (final item in staged.reversed.where((item) => item.replaced)) {
        try {
          final original = replaced.firstWhere(
            (candidate) => candidate.target.path == item.target.path,
          );
          if (original.bytes == null) {
            if (await item.target.exists()) await item.target.delete();
          } else {
            final restore = await _stageAdjacent(item.target, original.bytes!);
            await appdata.replaceFileAtomically(restore, item.target);
          }
        } catch (error, stack) {
          Log.error(
            'Import Data',
            'Failed to restore ${item.target.path}: $error',
            stack,
          );
        }
      }
      if (historyWasOpen && (historyClosed || historyReplaced)) {
        try {
          if (historyManager.hasOpenConnection) historyManager.close();
          await historyManager.init();
        } catch (error, stack) {
          Log.error('Import Data', 'Failed to reopen history: $error', stack);
        }
      }
      if (cookieWasOpen && cookieClosed) {
        try {
          SingleInstanceCookieJar.instance = SingleInstanceCookieJar(
            FilePath.join(App.dataPath, 'cookie.db'),
          );
        } catch (error, stack) {
          Log.error('Import Data', 'Failed to reopen cookies: $error', stack);
        }
      } else if (cookieClosed) {
        SingleInstanceCookieJar.instance = null;
      }
      rethrow;
    } finally {
      if (userCommit != null && !userCommit.isReleased) {
        try {
          await userCommit.discard();
        } catch (error, stack) {
          Log.error(
            'Import Data',
            'Failed to discard appdata commit: $error',
            stack,
          );
        }
      }
      for (final item in staged) {
        await item.stage.deleteIgnoreError();
      }
    }
    return AppDataImportResult(sourceImported: sourceImported);
  } finally {
    for (final item in staged) {
      await item.stage.deleteIgnoreError();
    }
    cacheDir.deleteIgnoreError(recursive: true);
  }
}

class _StagedImport {
  _StagedImport({
    required this.target,
    required this.stage,
    this.sourceKey,
    this.decodedSourceData,
  });

  final File target;
  final File stage;
  final String? sourceKey;
  final Map<String, dynamic>? decodedSourceData;
  bool replaced = false;
}

class _OriginalImportFile {
  const _OriginalImportFile({required this.target, required this.bytes});

  final File target;
  final List<int>? bytes;
}

Future<File> _stageAdjacent(File target, List<int> bytes) async {
  await target.parent.create(recursive: true);
  final stage = File('${target.path}.import-${const Uuid().v4()}.tmp');
  await stage.writeAsBytes(bytes, flush: true);
  return stage;
}

void _validateSqlite(File file, String name) {
  final db = sqlite3.open(file.path);
  try {
    final result = db.select('PRAGMA integrity_check');
    if (result.isEmpty || result.first.values.first.toString() != 'ok') {
      throw FormatException('$name failed SQLite integrity check');
    }
    final table = name == 'history.db' ? 'history' : 'cookies';
    final required = name == 'history.db'
        ? const {
            'id',
            'title',
            'subtitle',
            'cover',
            'time',
            'type',
            'ep',
            'page',
            'readEpisode',
            'max_page',
          }
        : const {
            'name',
            'value',
            'domain',
            'path',
            'expires',
            'secure',
            'httpOnly',
          };
    final object = db.select(
      'SELECT type FROM sqlite_master WHERE name = ? LIMIT 1',
      [table],
    );
    if (object.isEmpty || object.first['type'] != 'table') {
      throw FormatException('$name requires a real $table table');
    }
    final columns = db.select('PRAGMA table_info($table)');
    final actual = columns
        .map((row) => row['name'])
        .whereType<String>()
        .toSet();
    if (!actual.containsAll(required)) {
      throw FormatException('$name has incompatible $table schema');
    }
  } finally {
    db.dispose();
  }
}

void _validateImportedDocument(Map<String, dynamic>? document) {
  if (document == null) return;
  final settings = document['settings'];
  if (settings != null && settings is! Map) {
    throw const FormatException('imported settings must be an object');
  }
  if (settings is Map && settings.containsKey('enabledSources')) {
    SourcePreferences.normalizeSelection(settings['enabledSources']);
  }
  final history = document['searchHistory'];
  if (history != null &&
      (history is! List || !history.every((item) => item is String))) {
    throw const FormatException('imported searchHistory must be strings');
  }
}

Future<Archive> _readImportArchive(File file) async {
  final bytes = await file.readAsBytes();
  // A bounded decode prevents a malformed backup from allocating an
  // unbounded amount of memory before its entry names can be checked.
  if (bytes.length > 128 << 20) {
    throw const FormatException('backup archive is too large');
  }
  try {
    return ZipDecoder().decodeBytes(bytes, verify: true);
  } catch (error) {
    throw FormatException('invalid backup archive: $error');
  }
}

String _validateArchiveEntry(ArchiveFile entry) {
  final raw = entry.name.replaceAll('\\', '/');
  if (raw.isEmpty ||
      raw.contains('\u0000') ||
      raw.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(raw)) {
    throw const FormatException('backup archive contains an unsafe path');
  }
  final comparable = raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
  final normalized = p.posix.normalize(comparable);
  if (normalized != comparable ||
      normalized == '.' ||
      raw.split('/').contains('..')) {
    throw const FormatException('backup archive contains an unsafe path');
  }
  if (entry.isSymbolicLink) {
    throw const FormatException('backup archive contains a link');
  }
  return normalized;
}

Future<void> importPicaData(File file) async {
  var cacheDirPath = FilePath.join(App.cachePath, 'temp_data');
  var cacheDir = Directory(cacheDirPath);
  if (cacheDir.existsSync()) {
    cacheDir.deleteSync(recursive: true);
  }
  cacheDir.createSync();
  try {
    await Isolate.run(() {
      ZipFile.openAndExtract(file.path, cacheDirPath);
    });
    // Pica local_favorite.db is intentionally ignored: favorites are now
    // source-owned remote data and the device cache is not importable.
    var historyFile = cacheDir.joinFile("history.db");
    if (historyFile.existsSync()) {
      var db = sqlite3.open(historyFile.path);
      try {
        for (var comic in db.select("SELECT * FROM history;")) {
          HistoryManager().addHistory(
            History.fromMap({
              "type": switch (comic['type']) {
                0 => 'picacg'.hashCode,
                1 => 'ehentai'.hashCode,
                2 => 'jm'.hashCode,
                3 => 'hitomi'.hashCode,
                4 => 'wnacg'.hashCode,
                5 => 'nhentai'.hashCode,
                _ => comic['type'],
              },
              "id": comic['target'],
              "max_page": comic["max_page"],
              "ep": comic["ep"],
              "page": comic["page"],
              "time": comic["time"],
              "title": comic["title"],
              "subtitle": comic["subtitle"],
              "cover": comic["cover"],
              "readEpisode": [comic["ep"]],
            }),
          );
        }
        List<ImageFavoritesComic> imageFavoritesComicList =
            ImageFavoriteManager().comics;
        for (var comic in db.select("SELECT * FROM image_favorites;")) {
          String sourceKey = comic["id"].split("-")[0];
          // 换名字了, 绅士漫画
          if (sourceKey.toLowerCase() == "htmanga") {
            sourceKey = "wnacg";
          }
          if (ComicSource.find(sourceKey) == null) {
            continue;
          }
          String id = comic["id"].split("-")[1];
          int page = comic["page"];
          // 章节和page是从1开始的, pica 可能有从 0 开始的, 得转一下
          int ep = comic["ep"] == 0 ? 1 : comic["ep"];
          String title = comic["title"];
          String epName = "";
          ImageFavoritesComic? tempComic = imageFavoritesComicList
              .firstWhereOrNull((e) => e.id == id && e.sourceKey == sourceKey);
          ImageFavorite curImageFavorite = ImageFavorite(
            page,
            "",
            null,
            "",
            id,
            ep,
            sourceKey,
            epName,
          );
          if (tempComic == null) {
            tempComic = ImageFavoritesComic(
              id,
              [],
              title,
              sourceKey,
              [],
              [],
              DateTime.now(),
              "",
              {},
              "",
              1,
            );
            tempComic.imageFavoritesEp = [
              ImageFavoritesEp("", ep, [curImageFavorite], epName, 1),
            ];
            imageFavoritesComicList.add(tempComic);
          } else {
            ImageFavoritesEp? tempEp = tempComic.imageFavoritesEp
                .firstWhereOrNull((e) => e.ep == ep);
            if (tempEp == null) {
              tempComic.imageFavoritesEp.add(
                ImageFavoritesEp("", ep, [curImageFavorite], epName, 1),
              );
            } else {
              // 如果已经有这个page了, 就不添加了
              if (tempEp.imageFavorites.firstWhereOrNull(
                    (e) => e.page == page,
                  ) ==
                  null) {
                tempEp.imageFavorites.add(curImageFavorite);
              }
            }
          }
        }
        for (var temp in imageFavoritesComicList) {
          ImageFavoriteManager().addOrUpdateOrDelete(
            temp,
            temp == imageFavoritesComicList.last,
          );
        }
      } catch (e, stack) {
        Log.error("Import Data", "Failed to import history: $e", stack);
      } finally {
        db.dispose();
      }
    }
  } finally {
    cacheDir.deleteIgnoreError(recursive: true);
  }
}
