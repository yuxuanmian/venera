import 'dart:convert';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/tracking/source_revision_store.dart';
import 'package:venera/foundation/tracking/source_import_transaction.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/utils/ext.dart';
import 'package:zip_flutter/zip_flutter.dart';

import 'io.dart';

class AppDataImportResult {
  const AppDataImportResult({
    this.sourceImported = false,
    this.sourceSkipped = false,
  });

  final bool sourceImported;
  final bool sourceSkipped;
}

Future<File> exportAppData([bool sync = true]) async {
  var time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  var cacheFilePath = FilePath.join(App.cachePath, '$time.venera');
  var cacheFile = File(cacheFilePath);
  var dataPath = App.dataPath;
  if (await cacheFile.exists()) {
    await cacheFile.delete();
  }
  await Isolate.run(() {
    var zipFile = ZipFile.open(cacheFilePath);
    var historyFile = FilePath.join(dataPath, "history.db");
    var appdata = FilePath.join(
      dataPath,
      sync ? "syncdata.json" : "appdata.json",
    );
    var cookies = FilePath.join(dataPath, "cookie.db");
    zipFile.addFile("history.db", historyFile);
    zipFile.addFile("appdata.json", appdata);
    zipFile.addFile("cookie.db", cookies);
    final sourceRoot = Directory(FilePath.join(dataPath, 'comic_source'));
    if (sourceRoot.existsSync()) {
      for (final entity in sourceRoot.listSync(recursive: true)) {
        if (entity is! File) continue;
        final relative = p
            .relative(entity.path, from: sourceRoot.path)
            .replaceAll('\\', '/');
        if (_isTemporarySourcePath(relative)) continue;
        SourceRevisionStore.validateSafeRelativePath(relative);
        zipFile.addFile('comic_source/$relative', entity.path);
      }
    }
    zipFile.close();
  });
  return cacheFile;
}

Future<AppDataImportResult> importAppData(
  File file, [
  bool checkVersion = false,
]) async {
  final sourceCloudAtStart =
      App.cloudTracking.cloudEnabled || App.cloudTracking.pendingCloudEnable;
  final sourceEpochAtStart = App.cloudTracking.operationEpoch;
  var sourceImported = false;
  var sourceSkipped = false;
  final cacheDir = await Directory(App.cachePath).createTemp('source-import-');
  final cacheDirPath = cacheDir.path;
  try {
    await Isolate.run(() {
      ZipFile.openAndExtract(file.path, cacheDirPath);
    });
    var historyFile = cacheDir.joinFile("history.db");
    var appdataFile = cacheDir.joinFile("appdata.json");
    var cookieFile = cacheDir.joinFile("cookie.db");
    if (checkVersion && appdataFile.existsSync()) {
      var data = jsonDecode(await appdataFile.readAsString());
      var version = data["settings"]["dataVersion"];
      if (version is int && version <= appdata.settings["dataVersion"]) {
        return const AppDataImportResult();
      }
    }
    if (await historyFile.exists()) {
      HistoryManager().close();
      File(FilePath.join(App.dataPath, "history.db")).deleteIfExistsSync();
      historyFile.renameSync(FilePath.join(App.dataPath, "history.db"));
      HistoryManager().init();
    }
    if (await appdataFile.exists()) {
      var content = await appdataFile.readAsString();
      var data = jsonDecode(content);
      appdata.syncData(data);
    }
    if (await cookieFile.exists()) {
      SingleInstanceCookieJar.instance?.dispose();
      File(FilePath.join(App.dataPath, "cookie.db")).deleteIfExistsSync();
      cookieFile.renameSync(FilePath.join(App.dataPath, "cookie.db"));
      SingleInstanceCookieJar.instance = SingleInstanceCookieJar(
        FilePath.join(App.dataPath, "cookie.db"),
      )..init();
    }
    var comicSourceDir = FilePath.join(cacheDirPath, "comic_source");
    if (Directory(comicSourceDir).existsSync()) {
      _validateImportedSourceTree(Directory(comicSourceDir));
      final sourceRoot = Directory(FilePath.join(App.dataPath, "comic_source"));
      if (sourceCloudAtStart ||
          !App.cloudTracking.customizationAllowed ||
          App.cloudTracking.operationEpoch != sourceEpochAtStart) {
        sourceSkipped = true;
        Log.info(
          "Import data",
          "Skipped comic source scripts because Cloud owns source runtimes.",
        );
      } else {
        await App.cloudTracking.withCommitLock(() async {
          if (sourceCloudAtStart ||
              !App.cloudTracking.customizationAllowed ||
              App.cloudTracking.operationEpoch != sourceEpochAtStart) {
            sourceSkipped = true;
            return;
          }
          void requireCurrent() {
            App.cloudTracking.requireCurrentCommit(
              sourceEpochAtStart,
              expectedCloud: false,
            );
            if (App.cloudTracking.pendingCloudEnable) {
              throw StateError('Cloud was requested during source import.');
            }
          }

          await SourceImportTransaction(sourceRoot).replace(
            Directory(comicSourceDir),
            requireCurrent: requireCurrent,
            denyRuntime: App.cloudTracking.denySourceRuntimes,
            reload: () =>
                App.cloudTracking.reloadSourcesLocked(sourceEpochAtStart),
          );
          sourceImported = true;
        });
        if (sourceImported) await App.cloudTracking.refreshNow();
      }
    }
    return AppDataImportResult(
      sourceImported: sourceImported,
      sourceSkipped: sourceSkipped,
    );
  } finally {
    cacheDir.deleteIgnoreError(recursive: true);
  }
}

bool _isTemporarySourcePath(String relative) {
  final segments = p.posix.split(relative);
  return segments.contains('.custom-drafts') ||
      segments.any((segment) => segment.endsWith('.tmp'));
}

void _validateImportedSourceTree(Directory sourceRoot) {
  final root = p.absolute(sourceRoot.path);
  for (final entity in sourceRoot.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is Link) {
      throw const FormatException('source archive contains a link');
    }
    final relative = p.relative(entity.path, from: root).replaceAll('\\', '/');
    SourceRevisionStore.validateSafeRelativePath(relative);
    if (_isTemporarySourcePath(relative)) {
      throw const FormatException('source archive contains staging data');
    }
  }

  final managed = Directory(p.join(root, '.managed'));
  if (!managed.existsSync()) return;
  final store = SourceRevisionStore(sourceRoot);
  for (final name in const [
    'active-artifacts.json',
    'active-artifacts.json.lkg',
  ]) {
    final file = File(p.join(managed.path, name));
    if (!file.existsSync()) continue;
    final registry = ActiveArtifactRegistry.fromJson(
      jsonDecode(file.readAsStringSync()),
    );
    for (final artifact in [
      ...registry.artifacts,
      ...registry.recoverableArtifacts,
    ]) {
      if (_isTemporarySourcePath(artifact.relativePath)) {
        throw const FormatException('registry references staging data');
      }
      store.readBytesSync(artifact);
    }
  }
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
