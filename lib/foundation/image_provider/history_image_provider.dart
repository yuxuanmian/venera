import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/images.dart';
import '../history.dart';
import 'base_image_provider.dart';
import 'history_image_provider.dart' as image_provider;

class HistoryImageProvider
    extends BaseImageProvider<image_provider.HistoryImageProvider> {
  /// Image provider for normal image.
  ///
  /// [url] is the url of the image. Local file path is also supported.
  const HistoryImageProvider(this.history);

  final History history;

  @override
  Future<LoadResult> load(chunkEvents, checkStop) async {
    var url = history.cover;
    if (!url.contains('/')) {
      var localComic = LocalManager().find(history.id, history.type);
      if (localComic != null) {
        var data = await localComic.coverFile.readAsBytes();
        checkStop();
        return (bytes: data, cacheKey: null);
      }
      var comicSource =
          history.type.comicSource ?? (throw "Comic source not found.");
      var comic = await comicSource.loadComicInfo!(history.id);
      checkStop();
      if (comic.error) {
        throw comic.errorMessage ?? "Error: Failed to load comic info.";
      }
      url = comic.data.cover;
      if (url != history.cover) {
        // Only persist when the URL actually changed; otherwise every image
        // load would trigger a DB write and a rebuild of the history list.
        history.cover = url;
        HistoryManager().addHistory(history);
      }
    }
    // History.sourceKey falls back to "Unknown:..." for uninstalled sources,
    // while ComicType.sourceKey would throw a null check error.
    var sourceKey = history.sourceKey;
    final cacheKey = ImageDownloader.thumbnailCacheKey(
      url,
      sourceKey,
      history.id,
    );
    await for (var progress in ImageDownloader.loadThumbnail(
      url,
      sourceKey,
      history.id,
    )) {
      checkStop();
      chunkEvents.add(
        ImageChunkEvent(
          cumulativeBytesLoaded: progress.currentBytes,
          expectedTotalBytes: progress.totalBytes,
        ),
      );
      if (progress.imageBytes != null) {
        return (bytes: progress.imageBytes!, cacheKey: cacheKey);
      }
    }
    throw "Error: Empty response body.";
  }

  @override
  Future<HistoryImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => "history${history.id}${history.type.value}";
}
