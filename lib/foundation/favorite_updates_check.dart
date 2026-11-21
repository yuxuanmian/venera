import 'dart:async';

import 'package:flutter/foundation.dart';

import 'comic_source/comic_source.dart';
import 'favorite_updates_query.dart';
import 'favorites.dart';
import 'follow_updates.dart';
import 'follow_updates_service.dart';
import 'log.dart';

enum FavoriteUpdatesCheckPhase {
  idle,
  syncing,
  waiting,
  checking,
  failedSync,
  failedCheck,
}

/// A page observes the work for its source and account. Opening another page for
/// the same source joins that work, even if the original page has been closed.
class FavoriteUpdatesCheck extends ChangeNotifier {
  FavoriteUpdatesCheck(this.data);

  final FavoriteData data;
  static final _active = <(FavoriteData, int, String), _FavoriteUpdatesWork>{};
  _FavoriteUpdatesWork? _work;
  bool _disposed = false;

  FavoriteUpdatesCheckPhase get phase =>
      _work?.value ?? FavoriteUpdatesCheckPhase.idle;

  Future<void> start({bool retry = false}) async {
    if (_disposed || !favoriteUpdatesSupported(data)) return;
    final cache = NetworkFavoriteCacheManager();
    final key = (
      data,
      cache.captureFavoriteSessionEpoch(data.key),
      data.cacheScope,
    );
    final retryCheck =
        retry &&
        phase == FavoriteUpdatesCheckPhase.failedCheck &&
        favoriteUpdatesCacheReady(data);
    final work = _active.putIfAbsent(key, () {
      final next = _FavoriteUpdatesWork(data, cache, key.$2, key.$3);
      next.done = Future.microtask(() => next.run(prepare: !retryCheck))
          .whenComplete(() {
            if (identical(_active[key], next)) _active.remove(key);
          });
      return next;
    });
    if (!identical(work, _work)) {
      _work?.removeListener(notifyListeners);
      _work = work..addListener(notifyListeners);
      notifyListeners();
    }
    await work.done;
  }

  @override
  void dispose() {
    _disposed = true;
    _work?.removeListener(notifyListeners);
    super.dispose();
  }
}

class _FavoriteUpdatesWork extends ValueNotifier<FavoriteUpdatesCheckPhase> {
  _FavoriteUpdatesWork(this.data, this.cache, this.epoch, this.scope)
    : super(FavoriteUpdatesCheckPhase.idle);

  final FavoriteData data;
  final NetworkFavoriteCacheManager cache;
  final int epoch;
  final String scope;
  late final Future<void> done;

  bool get isCurrent =>
      ComicSource.find(data.key)?.favoriteData == data &&
      cache.isFavoriteSessionEpochCurrent(data.key, epoch) &&
      data.cacheScope == scope &&
      favoriteUpdatesSupported(data);

  Future<void> run({required bool prepare}) async {
    try {
      if (!isCurrent) return;
      final prepared = !prepare || await _prepareFavorites();
      if (!isCurrent) return;
      if (!prepared) {
        value = FavoriteUpdatesCheckPhase.failedSync;
        return;
      }
      final checked = await _checkUpdates();
      if (isCurrent) {
        value = checked
            ? FavoriteUpdatesCheckPhase.idle
            : value == FavoriteUpdatesCheckPhase.syncing
            ? FavoriteUpdatesCheckPhase.failedSync
            : FavoriteUpdatesCheckPhase.failedCheck;
      }
    } catch (error, stackTrace) {
      Log.error(
        'Favorite updates',
        'Check failed: ${error.runtimeType}',
        stackTrace,
      );
      if (isCurrent) {
        value = value == FavoriteUpdatesCheckPhase.syncing
            ? FavoriteUpdatesCheckPhase.failedSync
            : FavoriteUpdatesCheckPhase.failedCheck;
      }
    }
  }

  Future<bool> _prepareFavorites() async {
    final progress = data.usesCollectionCache
        ? await cache.collections.continueForUpdates(
            data,
            isCanceled: () => !isCurrent,
          )
        : cache.continueLegacyFavoriteSync(data);
    if (progress != null && !await _waitForSync(progress)) return false;
    if (data.multiFolder &&
        data.cacheAllFolder == null &&
        (cache.needsFavoriteDirectoryReload(data.key) ||
            (favoriteUpdateFolders(data).isEmpty &&
                !cache.hasLoadedFavoriteDirectory(data.key)))) {
      value = FavoriteUpdatesCheckPhase.syncing;
      final result = await cache.refreshFolders(
        data,
        isCurrent: () => isCurrent,
      );
      if (result.error) return false;
    }
    for (final folder in favoriteUpdateFolders(data)) {
      if (!isCurrent) return false;
      if (cache.getFullCacheStatus(folder).isComplete &&
          !(data.usesCollectionCache &&
              cache.collections.hasPendingSync(data, folder))) {
        continue;
      }
      final completed = await _waitForSync(
        cache.cacheAllPages(
          data,
          folder,
          isCanceled: () => !isCurrent,
          adoptRemoteCover: false,
        ),
      );
      if (!completed) return false;
    }
    return favoriteUpdatesCacheReady(data);
  }

  Future<bool> _waitForSync(Stream<FavoriteFullCacheProgress> progress) async {
    value = FavoriteUpdatesCheckPhase.syncing;
    FavoriteFullCacheProgress? last;
    await for (final update in progress) {
      last = update;
    }
    return last?.isComplete == true;
  }

  Future<bool> _checkUpdates() async {
    final folders = favoriteUpdateFolders(data);
    if (folders.isEmpty) return true;
    if (sourceDeclaresUnreadSignal(data.key)) {
      if (!data.usesCollectionCache) return true;
      for (final folder in folders) {
        if (!isCurrent) return false;
        final ok = await cache.collections.refreshUnreadIfNeeded(
          data,
          folder,
          onChecking: _showChecking,
          onSyncing: () => value = FavoriteUpdatesCheckPhase.syncing,
          isCanceled: () => !isCurrent,
        );
        if (!ok) return false;
      }
      return true;
    }
    return followUpdateCoordinator.checkFavoriteSource(
      data.key,
      isCurrent: () => isCurrent,
      onWaiting: () => value = FavoriteUpdatesCheckPhase.waiting,
      onChecking: _showChecking,
    );
  }

  void _showChecking() => value = FavoriteUpdatesCheckPhase.checking;
}
