import 'dart:async';
import 'dart:convert';
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
  NetworkFavoriteFolderRef folder,
) async {
  int retries = 3;
  while (true) {
    try {
      var comicSource = c.type.comicSource;
      if (comicSource == null) {
        return ComicUpdateResult(false, "Comic source not found");
      }
      if (comicSource.loadComicInfo == null) {
        return ComicUpdateResult(false, 'Comic source does not load details');
      }
      var newInfo = (await comicSource.loadComicInfo!(c.id)).data;

      final author = newInfo.subTitle?.trim();
      NetworkFavoriteCacheManager().updateBasicInfo(
        folder,
        c.id,
        title: newInfo.title,
        author: author?.isNotEmpty == true ? author : newInfo.findAuthor(),
        chapterCount: newInfo.chapters?.length,
      );

      final updated = NetworkFavoriteCacheManager().recordComicCheck(
        folder,
        c.id,
        updateTime: newInfo.findUpdateTime(),
        updateMarker: comicUpdateMarker(newInfo),
      );
      return ComicUpdateResult(updated, null);
    } catch (e, s) {
      Log.error("Check Updates", e, s);
      await Future.delayed(const Duration(seconds: 2));
      retries--;
      if (retries == 0) {
        return ComicUpdateResult(false, e.toString());
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

void updateFolderBase(
  NetworkFavoriteFolderRef folder,
  StreamController<UpdateProgress> stream,
  bool ignoreCheckTime,
) async {
  var comics = NetworkFavoriteCacheManager().getComicsWithUpdatesInfo(folder);
  int total = comics.length;
  int current = 0;
  int errors = 0;
  int updated = 0;
  int checked = 0;

  stream.add(UpdateProgress(total, current, errors, updated));

  var comicsToUpdate = <FavoriteItemWithUpdateInfo>[];

  for (var comic in comics) {
    if (!ignoreCheckTime) {
      var lastCheckTime = comic.lastCheckTime;
      if (lastCheckTime != null &&
          DateTime.now().difference(lastCheckTime).inDays < 1) {
        current++;
        stream.add(UpdateProgress(total, current, errors, updated));
        continue;
      }
    }
    comicsToUpdate.add(comic);
  }

  total = comicsToUpdate.length;
  current = 0;
  stream.add(UpdateProgress(total, current, errors, updated));

  var channel = Channel<FavoriteItemWithUpdateInfo>(10);

  // Producer
  () async {
    var c = 0;
    for (var comic in comicsToUpdate) {
      await channel.push(comic);
      c++;
      // Throttle
      if (c % 5 == 0) {
        var delay = c % 100 + 1;
        if (delay > 10) {
          delay = 10;
        }
        await Future.delayed(Duration(seconds: delay));
      }
    }
    channel.close();
  }();

  // Consumers
  var updateFutures = <Future>[];
  for (var i = 0; i < 5; i++) {
    var f = () async {
      while (true) {
        var comic = await channel.pop();
        if (comic == null) {
          break;
        }
        var result = await updateComic(comic, folder);
        current++;
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

  if (checked > 0) {
    NetworkFavoriteCacheManager().notifyCacheChanged();
  }

  stream.close();
}

Stream<UpdateProgress> updateFolder(
  NetworkFavoriteFolderRef folder,
  bool ignoreCheckTime,
) {
  var stream = StreamController<UpdateProgress>();
  updateFolderBase(folder, stream, ignoreCheckTime);
  return stream.stream;
}

Future<String> getUpdatedComicsAsJson(NetworkFavoriteFolderRef folder) async {
  var comics = NetworkFavoriteCacheManager().getComicsWithUpdatesInfo(folder);
  var updatedComics = comics.where((c) => c.hasNewUpdate).toList();
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
