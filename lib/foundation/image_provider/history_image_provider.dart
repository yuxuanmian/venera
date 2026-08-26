import 'dart:async' show Future, FutureOr, StreamController;
import 'dart:convert' show jsonEncode;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/images.dart';
import '../history.dart';
import 'base_image_provider.dart';
import 'cover_recovery.dart';
import 'history_image_provider.dart' as image_provider;

typedef HistoryImageLoad =
    Future<LoadResult> Function(
      String url,
      StreamController<ImageChunkEvent> chunkEvents,
      void Function() checkStop,
      FutureOr<void> Function()? onDecodeSuccess,
    );

typedef HistoryCoverUpdater =
    bool Function({
      required String id,
      required HistoryType type,
      required String expectedCover,
      required String newCover,
    });

class HistoryImageProvider
    extends BaseImageProvider<image_provider.HistoryImageProvider> {
  /// Image provider for a history entry.
  ///
  /// All request identity fields are captured when the provider is created.
  /// [history] is retained only so a successfully recovered cover can be
  /// written back to the mutable history object.
  HistoryImageProvider(
    this.history, {
    @visibleForTesting Future<String> Function()? loadComicCover,
    @visibleForTesting HistoryImageLoad? loadUrl,
    @visibleForTesting HistoryCoverUpdater? updateCoverIfUnchanged,
  }) : _cover = history.cover,
       _type = history.type,
       _sourceKey = history.sourceKey,
       _id = history.id,
       _loadComicCoverOverride = loadComicCover,
       _loadUrlOverride = loadUrl,
       _updateCoverIfUnchangedOverride = updateCoverIfUnchanged,
       _key = jsonEncode([
         'history',
         history.type.value,
         history.sourceKey,
         history.id,
         history.cover,
       ]);

  final History history;
  final String _cover;
  final HistoryType _type;
  final String _sourceKey;
  final String _id;
  final Future<String> Function()? _loadComicCoverOverride;
  final HistoryImageLoad? _loadUrlOverride;
  final HistoryCoverUpdater? _updateCoverIfUnchangedOverride;
  final String _key;

  @override
  bool get retryLoadErrors => false;

  @visibleForTesting
  ({String cover, String id, String sourceKey, HistoryType type})
  get requestSnapshot =>
      (cover: _cover, id: _id, sourceKey: _sourceKey, type: _type);

  @override
  Future<LoadResult> load(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
  ) async {
    var url = _cover;
    var wasPlaceholder = false;

    if (!url.contains('/')) {
      final localComic = LocalManager().find(_id, _type);
      if (localComic != null) {
        final data = await localComic.coverFile.readAsBytes();
        checkStop();
        return LoadResult(bytes: data, cacheKey: null);
      }

      url = await _loadComicCover();
      checkStop();
      wasPlaceholder = true;
    }

    String? resolvedUrl;
    var refreshed = false;

    void onDecodeSuccess() {
      final actualUrl = resolvedUrl;
      if (actualUrl == null) {
        return;
      }
      if (shouldPersistCoverUpdate(
        wasPlaceholder: wasPlaceholder,
        refreshed: refreshed,
        resolvedUrl: actualUrl,
        currentCover: history.cover,
      )) {
        final updateCoverIfUnchanged = _updateCoverIfUnchangedOverride;
        final updated = updateCoverIfUnchanged != null
            ? updateCoverIfUnchanged(
                id: _id,
                type: _type,
                expectedCover: _cover,
                newCover: actualUrl,
              )
            : HistoryManager().updateCoverIfUnchanged(
                id: _id,
                type: _type,
                expectedCover: _cover,
                newCover: actualUrl,
              );
        if (updated && history.cover == _cover) {
          history.cover = actualUrl;
        }
      }
    }

    final result = await recoverCover<LoadResult>(
      initialUrl: url,
      load: (actualUrl) => _loadUrl(
        actualUrl,
        chunkEvents,
        checkStop,
        onDecodeSuccess: onDecodeSuccess,
      ),
      refreshUrl: () async {
        final refreshedUrl = await _loadComicCover();
        checkStop();
        return refreshedUrl;
      },
    );

    resolvedUrl = result.url;
    refreshed = result.refreshed;

    return result.value;
  }

  Future<String> _loadComicCover() async {
    final loadComicCoverOverride = _loadComicCoverOverride;
    if (loadComicCoverOverride != null) {
      return loadComicCoverOverride();
    }

    final comicSource = ComicSource.find(_sourceKey);
    final loadComicInfo = comicSource?.loadComicInfo;
    if (loadComicInfo == null) {
      throw 'Comic source not found.';
    }

    final comic = await loadComicInfo(_id);
    if (comic.error) {
      throw comic.errorMessage ?? 'Error: Failed to load comic info.';
    }
    return comic.data.cover;
  }

  Future<LoadResult> _loadUrl(
    String url,
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop, {
    FutureOr<void> Function()? onDecodeSuccess,
  }) async {
    final loadUrlOverride = _loadUrlOverride;
    if (loadUrlOverride != null) {
      return loadUrlOverride(url, chunkEvents, checkStop, onDecodeSuccess);
    }

    final cacheKey = ImageDownloader.thumbnailCacheKey(url, _sourceKey, _id);
    await for (final progress in ImageDownloader.loadThumbnail(
      url,
      _sourceKey,
      _id,
    )) {
      checkStop();
      chunkEvents.add(
        ImageChunkEvent(
          cumulativeBytesLoaded: progress.currentBytes,
          expectedTotalBytes: progress.totalBytes,
        ),
      );
      if (progress.imageBytes != null) {
        return LoadResult(
          bytes: progress.imageBytes!,
          cacheKey: cacheKey,
          onDecodeSuccess: onDecodeSuccess,
          reloadAfterDecodeFailure: () => _loadUrl(
            url,
            chunkEvents,
            checkStop,
            onDecodeSuccess: onDecodeSuccess,
          ),
        );
      }
    }
    throw 'Error: Empty response body.';
  }

  @override
  Future<HistoryImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => _key;
}

@visibleForTesting
bool shouldPersistCoverUpdate({
  required bool wasPlaceholder,
  required bool refreshed,
  required String resolvedUrl,
  required String currentCover,
}) {
  return (wasPlaceholder || refreshed) &&
      resolvedUrl.isNotEmpty &&
      resolvedUrl != currentCover;
}
