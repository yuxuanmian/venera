import 'dart:async';
import 'dart:convert';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/channel.dart';

class ComicUpdateResult {
  final bool updated;
  final String? errorMessage;

  ComicUpdateResult(this.updated, this.errorMessage);
}

/// A date alone misses multiple releases on the same day. A chapter count
/// gives sources without a date a stable signal as well.
final _notFoundPattern = RegExp(
  r'404|410|invalid status code:\s*40[14]|not found|不存在|已下架',
  caseSensitive: false,
);

bool isNotFoundError(String message) => _notFoundPattern.hasMatch(message);

Duration retryDelayForFailures(int failures) {
  if (failures <= 1) return const Duration(hours: 1);
  if (failures == 2) return const Duration(hours: 6);
  if (failures == 3) return const Duration(hours: 24);
  return const Duration(days: 7);
}

String? comicUpdateMarker(ComicDetails info) {
  final values = <String>[];
  final updateTime = info.findUpdateTime();
  if (updateTime != null) values.add('time:$updateTime');
  final chapterCount = info.chapters?.length;
  if (chapterCount != null) values.add('chapters:$chapterCount');
  return values.isEmpty ? null : values.join('|');
}

Future<ComicUpdateResult> updateComic(
  FavoriteItemWithUpdateInfo c,
  NetworkFavoriteFolderRef folder, {
  NetworkFavoriteCacheManager? cache,
}) async {
  final manager = cache ?? NetworkFavoriteCacheManager();
  int retries = 3;
  while (true) {
    try {
      var comicSource = c.type.comicSource;
      if (comicSource == null) {
        manager.markComicRetryLater(folder, c.id);
        return ComicUpdateResult(false, "Comic source not found");
      }
      if (comicSource.loadComicInfo == null) {
        manager.markComicRetryLater(folder, c.id);
        return ComicUpdateResult(false, 'Comic source does not load details');
      }
      var newInfo = (await comicSource.loadComicInfo!(c.id)).data;

      final author = newInfo.subTitle?.trim();
      manager.updateBasicInfo(
        folder,
        c.id,
        title: newInfo.title,
        author: author?.isNotEmpty == true ? author : newInfo.findAuthor(),
        chapterCount: newInfo.chapters?.length,
      );

      final updated = manager.recordComicCheck(
        folder,
        c.id,
        updateTime: newInfo.findUpdateTime(),
        updateMarker: comicUpdateMarker(newInfo),
      );
      return ComicUpdateResult(updated, null);
    } catch (e, s) {
      Log.error("Check Updates", e, s);
      final message = e.toString();
      if (isNotFoundError(message)) {
        final notFoundCount = c.checkNotFoundCount + 1;
        if (notFoundCount >= 2 || c.isSuspectGone) {
          manager.markComicSuspectGone(folder, c.id);
        } else {
          manager.markComicNotFound(folder, c.id, notFoundCount: notFoundCount);
        }
        return ComicUpdateResult(false, message);
      }
      await Future.delayed(const Duration(seconds: 2));
      retries--;
      if (retries == 0) {
        final failures = c.checkFailures + 1;
        manager.markComicRetryLater(
          folder,
          c.id,
          delay: retryDelayForFailures(failures),
          failures: failures,
        );
        return ComicUpdateResult(false, message);
      }
    }
  }
}

class UpdateProgress {
  final int total;
  final int current;
  final int errors;
  final int updated;
  final FavoriteItemWithUpdateInfo? comic;
  final String? errorMessage;

  UpdateProgress(
    this.total,
    this.current,
    this.errors,
    this.updated, [
    this.comic,
    this.errorMessage,
  ]);
}

bool get followUpdatesEnabled =>
    appdata.settings['followUpdatesEnabled'] == true;

List<NetworkFavoriteFolderRef> getFollowUpdateFolders() {
  final enabled = appdata.settings['favorites'];
  if (enabled is! List) return const [];
  final cache = NetworkFavoriteCacheManager();
  return cache.getAllCachedFolders().where((folder) {
    final source = ComicSource.find(folder.sourceKey);
    return enabled.contains(folder.sourceKey) &&
        source?.isLogged == true &&
        source?.loadComicInfo != null &&
        cache.countCachedComics(folder) > 0;
  }).toList();
}

/// Progress of a background baseline-establishing run.
class BaselineStatus {
  const BaselineStatus({
    required this.isRunning,
    required this.total,
    required this.completed,
    required this.errors,
    required this.updated,
    this.currentComic,
  });

  final bool isRunning;
  final int total;
  final int completed;
  final int errors;
  final int updated;
  final String? currentComic;
}

/// Selection rule used when checking a remote favorite folder.
enum FollowUpdateMode {
  /// Only comics that have never completed a check.
  missing,

  /// Comics with no check yet plus those checked more than 24 hours ago.
  regular,

  /// Every cached comic, regardless of previous check time.
  force,
}

void updateFolderBase(
  NetworkFavoriteFolderRef folder,
  StreamController<UpdateProgress> stream,
  FollowUpdateMode mode, {
  bool Function()? isCanceled,
  bool ignoreRetryAfter = false,
  NetworkFavoriteCacheManager? cache,
}) async {
  final manager = cache ?? NetworkFavoriteCacheManager();
  var comics = manager.getComicsWithUpdatesInfo(folder);
  int total = comics.length;
  int current = 0;
  int errors = 0;
  int updated = 0;
  int checked = 0;

  stream.add(UpdateProgress(total, current, errors, updated));

  var comicsToUpdate = <FavoriteItemWithUpdateInfo>[];
  var notFoundRetries = <FavoriteItemWithUpdateInfo>[];

  for (var comic in comics) {
    if (comic.isSuspectGone) continue;
    final lastCheckTime = comic.lastCheckTime;
    if (mode == FollowUpdateMode.missing) {
      if (lastCheckTime != null) continue;
    } else if (mode == FollowUpdateMode.regular) {
      if (lastCheckTime != null &&
          DateTime.now().difference(lastCheckTime).inDays < 1) {
        current++;
        stream.add(UpdateProgress(total, current, errors, updated));
        continue;
      }
    }
    final retryAfter = comic.retryAfter;
    if (!ignoreRetryAfter &&
        retryAfter != null &&
        retryAfter.isAfter(DateTime.now())) {
      continue;
    }
    comicsToUpdate.add(comic);
  }

  total = comicsToUpdate.length;
  current = 0;
  stream.add(UpdateProgress(total, current, errors, updated));

  var channel = Channel<FavoriteItemWithUpdateInfo>(10);
  var consecutiveErrors = 0;
  var usingFallback = false;
  final threads =
      ((appdata.settings['followUpdateThreads'] as num?)?.toInt().clamp(
                1,
                16,
              ) ??
              5)
          .toInt();
  final aggressiveBatchDelay =
      (appdata.settings['followUpdateBatchDelay'] as num?)?.toDouble() ?? 5;

  // Producer
  () async {
    var c = 0;
    for (var comic in comicsToUpdate) {
      if (isCanceled?.call() == true) break;
      await channel.push(comic);
      c++;
      // Throttle
      const batchSize = 5;
      if (c % batchSize == 0) {
        final delay = usingFallback ? 10.0 : aggressiveBatchDelay;
        if (delay > 0) {
          await Future.delayed(Duration(milliseconds: (delay * 1000).round()));
        }
      }
    }
    channel.close();
  }();

  // Consumers
  var updateFutures = <Future>[];
  for (var i = 0; i < threads; i++) {
    var f = () async {
      while (true) {
        var comic = await channel.pop();
        if (comic == null) {
          break;
        }
        if (isCanceled?.call() == true) {
          channel.close();
          break;
        }
        var result = await updateComic(comic, folder, cache: manager);
        current++;
        if (result.errorMessage != null) {
          consecutiveErrors++;
          if (consecutiveErrors >= 10) usingFallback = true;
          if (isNotFoundError(result.errorMessage!)) {
            notFoundRetries.add(comic);
          }
        } else {
          consecutiveErrors = 0;
        }
        if (result.updated) {
          updated++;
        }
        if (result.errorMessage != null) {
          errors++;
        } else {
          checked++;
        }
        stream.add(
          UpdateProgress(
            total,
            current,
            errors,
            updated,
            comic,
            result.errorMessage,
          ),
        );
      }
    }();
    updateFutures.add(f);
  }

  await Future.wait(updateFutures);

  // A single 404 is only a pending failure. After the queue is fully
  // consumed, re-check each not-found comic once; a second consecutive 404
  // marks it as suspected removed, while a successful re-check clears it.
  if (notFoundRetries.isNotEmpty && isCanceled?.call() != true) {
    for (final comic in notFoundRetries) {
      if (isCanceled?.call() == true) break;
      if (manager.isComicSuspectGone(comic.sourceKey, comic.id)) continue;
      FavoriteItemWithUpdateInfo? fresh;
      for (final c in manager.getComicsWithUpdatesInfo(folder)) {
        if (c.id == comic.id) {
          fresh = c;
          break;
        }
      }
      if (fresh == null) continue;
      final result = await updateComic(fresh, folder, cache: manager);
      if (result.errorMessage == null) {
        checked++;
        if (result.updated) updated++;
        if (errors > 0) errors--;
        consecutiveErrors = 0;
      }
    }
  }

  stream.add(UpdateProgress(total, current, errors, updated));

  if (checked > 0) {
    manager.notifyCacheChanged();
  }

  stream.close();
}

Stream<UpdateProgress> updateFolder(
  NetworkFavoriteFolderRef folder,
  FollowUpdateMode mode, {
  bool Function()? isCanceled,
  bool ignoreRetryAfter = false,
  NetworkFavoriteCacheManager? cache,
}) {
  var stream = StreamController<UpdateProgress>();
  updateFolderBase(
    folder,
    stream,
    mode,
    isCanceled: isCanceled,
    ignoreRetryAfter: ignoreRetryAfter,
    cache: cache,
  );
  return stream.stream;
}

Future<bool> recheckFavoriteComic(String sourceKey, String comicId) async {
  final manager = NetworkFavoriteCacheManager();
  final folderIds = manager.getKnownFolderIds(sourceKey, comicId);
  var succeeded = false;
  for (final folderId in folderIds) {
    final folder = NetworkFavoriteFolderRef(
      sourceKey: sourceKey,
      folderId: folderId,
    );
    for (final item in manager.getComicsWithUpdatesInfo(folder)) {
      if (item.id == comicId) {
        final result = await updateComic(item, folder, cache: manager);
        if (result.errorMessage == null) succeeded = true;
        break;
      }
    }
  }
  manager.notifyCacheChanged();
  return succeeded;
}

Future<String> getUpdatedComicsAsJsonInFolders(
  Iterable<NetworkFavoriteFolderRef> folders,
) async {
  var updatedComics = NetworkFavoriteCacheManager().getUpdatedComicsInFolders(
    folders,
  );
  var jsonList = updatedComics
      .map(
        (c) => {
          'id': c.id,
          'name': c.name,
          'coverUrl': c.coverPath,
          'author': c.author,
          'chapterCount': c.chapterCount,
          'type': c.sourceKey,
          'updateTime': c.updateTime,
          'tags': c.tags,
        },
      )
      .toList();
  return jsonEncode(jsonList);
}
