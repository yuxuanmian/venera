part of 'favorites.dart';

/// A visible list can keep reading this version after a newer one is published.
class FavoriteCollectionVisit {
  FavoriteCollectionVisit._(this._owner, this._fetch, this._published);

  final FavoriteCollectionCache _owner;
  final _FavoritePages _fetch;
  final Object pageStorageKey = Object();
  Map<int, CachedFavoritePage> _published;
  final Map<int, List<String>> _usedPages = {};
  final Map<String, Comic> _recent = {};
  final Set<String> _seenRecent = {};
  final Set<String> _removed = {};
  bool _local = false;
  bool _opened = false;
  bool _wantsSync = false;
  bool _allowAuto = true;
  bool cacheFailed = false;
  bool _cacheWarningPending = false;

  NetworkFavoriteFolderRef get folder => _fetch.folder;
  bool get isCurrent => _fetch.isCurrent;
  List<Comic> get recent => _recent.values.toList(growable: false);
  bool wasRemoved(String id) => _removed.contains(id);
  bool isRecent(String id) => _recent.containsKey(id);

  Future<Res<List<Comic>>> loadPage(int page) => _owner._load(this, page);
  void markRecentShown() => _owner._markRecentShown(this);

  bool takeCacheWarning() {
    final pending = _cacheWarningPending;
    _cacheWarningPending = false;
    return pending;
  }
}

class FavoriteCollectionCache {
  FavoriteCollectionCache(this._cache);

  static const _numberedBatchSize = 4;

  final NetworkFavoriteCacheManager _cache;
  final mutations = ValueNotifier<int>(0);
  final Map<NetworkFavoriteFolderRef, FavoriteCollectionVisit> _visits = {};
  final Set<NetworkFavoriteFolderRef> _openAtHome = {};
  final Map<(String, String), Set<String>> _detailFolders = {};
  FavoriteCollectionVisit? _visible;
  _FavoriteCollectionSync? _sync;
  Timer? _settle;
  bool _settled = false;

  @visibleForTesting
  Duration settleDelay = const Duration(milliseconds: 400);

  FavoriteCollectionVisit open(
    FavoriteData data,
    NetworkFavoriteFolderRef folder, {
    bool restart = false,
    bool usePublished = false,
  }) {
    final existing = _visits[folder];
    final openAtHome = _openAtHome.remove(folder);
    if (!restart &&
        !openAtHome &&
        existing != null &&
        existing._fetch.data == data &&
        existing.isCurrent) {
      return existing;
    }
    final visit = FavoriteCollectionVisit._(
      this,
      _FavoritePages(_cache, data, folder),
      _readPublished(folder),
    );
    if (usePublished) {
      visit._local = true;
      visit._opened = true;
    }
    for (final row in _pending(folder)) {
      final id = row['comic_id'] as String;
      if (row['is_added'] == 0) {
        visit._removed.add(id);
      } else if (row['comic_json'] case final String json) {
        visit._recent[id] = Comic.fromJson(jsonDecode(json), folder.sourceKey);
      }
    }
    _visits[folder] = visit;
    return visit;
  }

  void show(FavoriteCollectionVisit visit) {
    if (identical(_visible, visit)) return;
    _visible = visit;
    _sync?.wake();
    _schedule();
  }

  void hide(FavoriteCollectionVisit visit) {
    if (!identical(_visible, visit)) return;
    _visible = null;
    _settle?.cancel();
    _settled = false;
    if (_sync case final run? when !run.manual) _schedule();
  }

  void _schedule() {
    _settle?.cancel();
    _settled = false;
    _settle = Timer(settleDelay, _onSettled);
  }

  void _onSettled() {
    _settled = true;
    final run = _sync;
    if (run != null && !run.manual && run.fetch != _visible?._fetch) {
      _finish(run, canceled: true);
    }
    _tryAutomatic();
  }

  @visibleForTesting
  void settleNow() {
    _settle?.cancel();
    _onSettled();
  }

  void _tryAutomatic() {
    final visible = _visible;
    if (_settled && _sync == null && visible != null && visible._wantsSync) {
      visible._wantsSync = false;
      _start(visible._fetch);
    }
  }

  void invalidate([String? sourceKey]) {
    bool matches(NetworkFavoriteFolderRef folder) =>
        sourceKey == null || folder.sourceKey == sourceKey;
    _visits.removeWhere((folder, _) => matches(folder));
    _detailFolders.removeWhere(
      (key, _) => sourceKey == null || key.$1 == sourceKey,
    );
    _openAtHome.removeWhere(matches);
    if (_visible case final visible? when matches(visible.folder)) {
      _visible = null;
      _settled = false;
      _settle?.cancel();
    }
    if (sourceKey == null) _settle?.cancel();
    if (_sync case final run? when matches(run.fetch.folder)) {
      _finish(run, canceled: true);
    }
  }

  void settingsChanged(String sourceKey) {
    invalidate(sourceKey);
    mutations.value++;
  }

  List<Row> _pending(NetworkFavoriteFolderRef folder) => _cache._db.select(
    '''SELECT comic_id, is_added, comic_json, needs_sync FROM favorite_pending_changes
       WHERE source_key = ? AND folder_id = ? ORDER BY rowid''',
    [folder.sourceKey, folder.folderId],
  );

  Set<String>? detailFolders(String sourceKey, String comicId) =>
      _detailFolders[(sourceKey, comicId)];

  void rememberDetailFolders(
    String sourceKey,
    String comicId,
    Iterable<String> folders,
  ) {
    _detailFolders[(sourceKey, comicId)] = folders.toSet();
  }

  /// A gallery can belong to one category while also appearing in its All list.
  void recordFavoriteMutation(
    FavoriteData data,
    NetworkFavoriteFolderRef folder,
    String id,
    bool added,
    Comic? comic,
  ) {
    final changes = {folder: added};
    if (data.cacheAllFolder case final allFolder?) {
      NetworkFavoriteFolderRef ref(String id) =>
          NetworkFavoriteFolderRef(sourceKey: folder.sourceKey, folderId: id);
      changes[ref(allFolder)] = added;
      if (data.singleFolderForSingleComic) {
        final known = _cache.getKnownFolderIds(folder.sourceKey, id)
          ..addAll(_cache._publishedFolderIds(folder.sourceKey, id));
        for (final other in known.difference({folder.folderId, allFolder})) {
          changes[ref(other)] = false;
        }
      }
    }
    _cache._db.execute('BEGIN');
    try {
      for (final change in changes.entries) {
        _persistChange(change.key, id, change.value, comic);
      }
      _cache._db.execute('COMMIT');
    } catch (_) {
      _cache._db.execute('ROLLBACK');
      rethrow;
    }
    for (final change in changes.entries) {
      _applyChange(change.key, id, change.value, comic);
    }
    _detailFolders.remove((folder.sourceKey, id));
    mutations.value++;
  }

  void recordChange(
    NetworkFavoriteFolderRef folder,
    String id,
    bool added,
    Comic? comic,
  ) {
    _persistChange(folder, id, added, comic);
    _applyChange(folder, id, added, comic);
    mutations.value++;
  }

  void _persistChange(
    NetworkFavoriteFolderRef folder,
    String id,
    bool added,
    Comic? comic,
  ) {
    _cache._db.execute(
      '''INSERT OR REPLACE INTO favorite_pending_changes
       (source_key, folder_id, comic_id, is_added, comic_json) VALUES (?, ?, ?, ?, ?)''',
      [
        folder.sourceKey,
        folder.folderId,
        id,
        added ? 1 : 0,
        added && comic != null ? jsonEncode(comic.toJson()) : null,
      ],
    );
  }

  void _applyChange(
    NetworkFavoriteFolderRef folder,
    String id,
    bool added,
    Comic? comic,
  ) {
    if (added) _openAtHome.add(folder);
    if (!added &&
        !_pending(
          folder,
        ).any((row) => row['is_added'] == 1 && row['needs_sync'] == 1)) {
      _openAtHome.remove(folder);
    }
    if (_visits[folder] case final visit?) {
      visit._wantsSync = false;
      visit._allowAuto = false;
      if (added) {
        visit._removed.remove(id);
        visit._seenRecent.remove(id);
        if (comic != null) visit._recent[id] = comic;
      } else {
        visit._recent.remove(id);
        visit._removed.add(id);
      }
    }
    if (_sync case final run? when run.fetch.folder == folder) {
      _finish(run, canceled: true);
    }
  }

  void _markRecentShown(FavoriteCollectionVisit visit) {
    if (!visit.isCurrent) return;
    final folder = visit.folder;
    for (final id in visit._recent.keys) {
      if (!visit._seenRecent.add(id)) continue;
      final args = [folder.sourceKey, folder.folderId, id];
      _cache._db.execute(
        '''UPDATE favorite_pending_changes SET seen = 1
        WHERE source_key = ? AND folder_id = ? AND comic_id = ? AND is_added = 1 AND seen = 0''',
        args,
      );
      _cache._db.execute(
        '''DELETE FROM favorite_pending_changes
        WHERE source_key = ? AND folder_id = ? AND comic_id = ? AND needs_sync = 0 AND seen = 1''',
        args,
      );
    }
  }

  Map<int, CachedFavoritePage> _readPublished(NetworkFavoriteFolderRef folder) {
    final rows = _cache._db.select(
      '''SELECT request_token FROM favorite_pages
      WHERE source_key = ? AND folder_id = ? ORDER BY page_index''',
      [folder.sourceKey, folder.folderId],
    );
    final pages = <int, CachedFavoritePage>{};
    for (final row in rows) {
      final page = _cache._getCachedPage(
        folder,
        row['request_token'] as String,
      )!;
      pages[page.pageIndex] = page;
    }
    return pages;
  }

  Future<Res<CachedFavoritePage>> fetchForDisplay(
    FavoriteData data,
    NetworkFavoriteFolderRef folder,
    int page,
  ) async {
    final result = await _FavoritePages(_cache, data, folder).load(page);
    if (result.error) return Res.fromErrorRes(result);
    return Res(
      CachedFavoritePage(
        comics: result.data.comics.map(FavoriteItem.fromComic).toList(),
        pageIndex: page,
        maxPage: result.data.maxPage,
        nextToken: result.data.next,
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<Res<List<Comic>>> _load(
    FavoriteCollectionVisit visit,
    int page,
  ) async {
    final fetch = visit._fetch;
    if (!fetch.isCurrent) return const Res.error('Favorite session changed');

    Res<List<Comic>> serve(List<Comic> comics, int? maxPage) {
      visit._usedPages[page] = [for (final comic in comics) comic.id];
      return Res(comics, subData: maxPage);
    }

    if (visit._published[page] case final cached? when visit._local) {
      return serve(cached.comics, cached.maxPage);
    }
    final reply = await fetch.load(page, foreground: true);
    if (!fetch.isCurrent) return const Res.error('Favorite session changed');
    if (reply.error) {
      if (visit._published[1] case final cached?
          when !visit._opened && page == 1) {
        visit._local = true;
        visit._opened = true;
        return serve(cached.comics, cached.maxPage);
      }
      return Res.fromErrorRes(reply);
    }
    final remote = reply.data;
    if (!visit._opened && page == 1) {
      visit._opened = true;
      final status = _cache.getFullCacheStatus(visit.folder);
      final old = visit._published[1];
      final publishedScope =
          _cache._db
              .select(
                '''SELECT cache_scope FROM favorite_folders
        WHERE source_key = ? AND folder_id = ?''',
                [visit.folder.sourceKey, visit.folder.folderId],
              )
              .firstOrNull?['cache_scope'] ??
          '';
      final expectedPages = remote.maxPage ?? status.pageCount;
      final matches =
          status.isComplete &&
          old != null &&
          publishedScope == fetch.scope &&
          status.pageCount == expectedPages &&
          visit._published.length == math.max(1, expectedPages) &&
          (remote.total == null || status.comicCount == remote.total) &&
          (!fetch.usesCursor ||
              (old.nextToken == null) == (remote.next == null)) &&
          listEquals(
            old.comics.map((c) => c.id).toList(),
            remote.comics.map((c) => c.id).toList(),
          );
      final needsSync =
          !matches ||
          _pending(visit.folder).any((row) => row['needs_sync'] == 1);
      visit._wantsSync = needsSync && visit._allowAuto;
      visit._local = !needsSync;
      _cache._ensureFolder(visit.folder);
      _cache._db.execute(
        '''UPDATE favorite_folders SET last_probe_at = ?
        WHERE source_key = ? AND folder_id = ?''',
        [
          DateTime.now().millisecondsSinceEpoch,
          visit.folder.sourceKey,
          visit.folder.folderId,
        ],
      );
      if (identical(_visible, visit) && visit._wantsSync) _tryAutomatic();
    }
    final covers = _cache._loadFavoriteCoverProvenance(visit.folder.sourceKey, {
      for (final comic in remote.comics) comic.id,
    });
    return serve(
      [
        for (final comic in remote.comics)
          _withKnownCover(comic, covers[comic.id]),
      ],
      visit._local
          ? (visit._published[page]?.maxPage ?? remote.maxPage)
          : fetch.usesCursor && remote.next == null
          ? page
          : remote.maxPage,
    );
  }

  Comic _withKnownCover(Comic comic, _FavoriteCoverProvenance? known) {
    if (known == null) return comic;
    final cover = comic.cover.trim();
    final replacement = cover.isEmpty
        ? known.latestCover
        : known.confirmedCoverFor(cover);
    if (replacement == null || replacement == comic.cover) return comic;
    return Comic.fromJson({
      ...comic.toJson(),
      'cover': replacement,
    }, comic.sourceKey);
  }

  Stream<FavoriteFullCacheProgress> cacheAll(
    FavoriteData data,
    NetworkFavoriteFolderRef folder, {
    required bool Function() isCanceled,
  }) async* {
    var other = _sync;
    while (other != null && other.manual && other.fetch.folder != folder) {
      await other.done.future;
      other = _sync;
    }
    if (isCanceled()) {
      yield const FavoriteFullCacheProgress(
        pagesCached: 0,
        comicsCached: 0,
        isCanceled: true,
      );
      return;
    }
    final current = _sync;
    if (current != null && current.fetch.folder != folder) {
      _finish(current, canceled: true);
    }
    final visible = _visible;
    final _FavoritePages fetch;
    if (_sync == null &&
        visible != null &&
        visible.folder == folder &&
        visible._wantsSync) {
      visible._wantsSync = false;
      fetch = visible._fetch;
    } else {
      fetch = _FavoritePages(_cache, data, folder);
    }
    final run = _sync ?? _start(fetch, isCanceled: isCanceled);
    run.manualCancel ??= isCanceled;
    run.wake();
    yield* run.watch();
  }

  _FavoriteCollectionSync _start(
    _FavoritePages fetch, {
    bool Function()? isCanceled,
  }) {
    final run = _FavoriteCollectionSync(fetch)..manualCancel = isCanceled;
    _sync = run;
    unawaited(_fill(run));
    return run;
  }

  Future<void> _fill(_FavoriteCollectionSync run) async {
    final fetch = run.fetch;
    try {
      var nextPage = 1;
      var hasMore = true;
      final ids = <String>{};
      while (!run.finished) {
        while (!run.manual && !run.finished && fetch != _visible?._fetch) {
          await run.pause();
        }
        if (run.finished) return;
        if (run.isCanceled || !fetch.isCurrent) {
          return _finish(run, canceled: true);
        }
        // A final batch can return while the user is still choosing a source.
        if (!hasMore) {
          _publish(run, nextPage - 1, ids);
          return _finish(run, complete: true);
        }

        final lastPage = nextPage == 1 || fetch.usesCursor
            ? nextPage
            : math.min(
                nextPage + _numberedBatchSize - 1,
                fetch.first!.maxPage!,
              );
        final batch = await Future.wait([
          for (var page = nextPage; page <= lastPage; page++)
            fetch.load(page).then((result) {
              if (run.finished) return result;
              if (run.isCanceled || !fetch.isCurrent) {
                _finish(run, canceled: true);
              } else if (result.error) {
                _finish(run, error: result.errorMessage);
              }
              return result;
            }),
        ]);
        if (run.finished) return;

        for (final result in batch) {
          for (final comic in result.data.comics) {
            if (!ids.add(comic.id)) {
              return _finish(run, error: 'Duplicate comic in favorites');
            }
          }
        }
        final latestPage = batch.last.data;
        hasMore = fetch.usesCursor
            ? latestPage.next != null
            : lastPage < latestPage.maxPage!;
        nextPage = lastPage + 1;
        if (hasMore) {
          run.emit(
            FavoriteFullCacheProgress(
              pagesCached: lastPage,
              totalPages: latestPage.maxPage,
              comicsCached: ids.length,
            ),
          );
        }
      }
    } catch (error) {
      _finish(run, error: error.toString());
    }
  }

  void _finish(
    _FavoriteCollectionSync run, {
    bool complete = false,
    bool canceled = false,
    String? error,
  }) {
    if (run.finished) return;
    if (identical(_sync, run)) _sync = null;
    run.finish(
      FavoriteFullCacheProgress(
        pagesCached: run.fetch.pages.length,
        totalPages: complete && run.fetch.usesCursor
            ? (run.fetch.comicCount == 0 ? 0 : run.fetch.pages.length)
            : run.fetch.first?.maxPage,
        comicsCached: run.fetch.comicCount,
        isComplete: complete,
        isCanceled: canceled,
        errorMessage: error,
      ),
    );
    if (!complete) run.fetch.discardUnviewed();
    if (_visits[run.fetch.folder] case final visit?
        when error != null && (visit._fetch == run.fetch || run.manual)) {
      visit.cacheFailed = true;
      visit._cacheWarningPending = !run.manual && identical(_visible, visit);
      mutations.value++;
    }
    scheduleMicrotask(_tryAutomatic);
  }

  void _publish(_FavoriteCollectionSync run, int lastPage, Set<String> ids) {
    final fetch = run.fetch;
    final folder = fetch.folder;
    final pages = [
      for (var page = 1; page <= lastPage; page++) fetch.pages[page]!,
    ];
    final pageCount = pages.first.comics.isEmpty ? 0 : lastPage;
    final totals = pages.map((page) => page.total).whereType<int>().toSet();
    if (totals.any((count) => count != ids.length)) {
      throw StateError('Favorite total changed');
    }
    final pending = _pending(folder).where((row) => row['needs_sync'] == 1);
    for (final row in pending) {
      if (ids.contains(row['comic_id']) != (row['is_added'] == 1)) {
        throw StateError(
          'The source list has not reflected the recent favorite changes',
        );
      }
    }
    final wasComplete = _cache.getFullCacheStatus(folder).isComplete;
    final oldIds = _cache._db
        .select(
          '''SELECT comic_id FROM favorite_membership
      WHERE source_key = ? AND folder_id = ?''',
          [folder.sourceKey, folder.folderId],
        )
        .map((r) => r['comic_id'] as String)
        .toSet();
    final covers = <String, String>{};
    _cache._beginFullCacheCoverProvenance(folder);
    _cache._db.execute('BEGIN');
    try {
      _cache._db.execute(
        'DELETE FROM favorite_pages WHERE source_key = ? AND folder_id = ?',
        [folder.sourceKey, folder.folderId],
      );
      for (final (index, page) in pages.indexed) {
        final token = fetch.usesCursor
            ? 'next:${index == 0 ? '' : pages[index - 1].next!}'
            : 'page:${index + 1}';
        covers.addAll(
          _cache._writePageRows(
            folder,
            pageIndex: index + 1,
            requestToken: token,
            comics: page.comics,
            maxPage: pageCount,
            nextToken: page.next,
            clearFollowingCursorPages: false,
            preserveExistingCover: !run.manual,
            adoptRemoteCover: run.manual,
          ),
        );
      }
      _cache._rebuildMembership(folder);
      _cache._db.execute(
        '''UPDATE favorite_folders SET full_cache_at = ?,
        full_cache_pages = ?, full_cache_comics = ?, cache_scope = ? WHERE source_key = ? AND folder_id = ?''',
        [
          DateTime.now().millisecondsSinceEpoch,
          pageCount,
          ids.length,
          fetch.scope,
          folder.sourceKey,
          folder.folderId,
        ],
      );
      _cache._db.execute(
        '''DELETE FROM favorite_pending_changes WHERE source_key = ? AND folder_id = ?
        AND (is_added = 0 OR seen = 1 OR NOT EXISTS (
          SELECT 1 FROM favorite_membership AS member
          WHERE member.source_key = favorite_pending_changes.source_key
            AND member.folder_id = favorite_pending_changes.folder_id
            AND member.comic_id = favorite_pending_changes.comic_id
        ))''',
        [folder.sourceKey, folder.folderId],
      );
      _cache._db.execute(
        '''UPDATE favorite_pending_changes SET needs_sync = 0
        WHERE source_key = ? AND folder_id = ?''',
        [folder.sourceKey, folder.folderId],
      );
      _cache._db.execute('COMMIT');
    } catch (_) {
      _cache._db.execute('ROLLBACK');
      rethrow;
    } finally {
      _cache._endFullCacheCoverProvenance(folder);
    }
    _openAtHome.remove(folder);
    final visit = _visits[folder];
    if (visit != null) {
      visit._wantsSync = false;
      visit.cacheFailed = false;
      visit._cacheWarningPending = false;
    }
    if (visit != null &&
        visit._opened &&
        visit._usedPages.isNotEmpty &&
        visit._usedPages.entries.every(
          (entry) => listEquals(
            entry.value,
            fetch.pages[entry.key]?.comics.map((c) => c.id).toList(),
          ),
        )) {
      visit._published = _readPublished(folder);
      visit._local = true;
      visit._wantsSync = false;
    }
    _cache._notifyFavoriteCoverChanges(folder.sourceKey, covers);
    if (!wasComplete || !setEquals(oldIds, ids)) {
      if (!wasComplete) _cache._markFirstFullCache(folder.sourceKey);
      if (!_cache._checksCollectionOnAddition(folder.sourceKey)) {
        for (final id in ids.difference(oldIds)) {
          _cache._markRemoteAddition(folder.sourceKey, id);
        }
      }
      _cache._notifySourceChanged(folder.sourceKey);
    }
  }
}

class _FavoritePages {
  _FavoritePages(this.cache, this.data, this.folder)
    : epoch = cache.captureFavoriteSessionEpoch(folder.sourceKey),
      scope = data.cacheScope;

  final NetworkFavoriteCacheManager cache;
  final FavoriteData data;
  final NetworkFavoriteFolderRef folder;
  final int epoch;
  final String scope;
  final Map<int, FavoriteCachePage> pages = {};
  final Map<int, Future<Res<FavoriteCachePage>>> _requests = {};
  final Set<int> _foreground = {};
  bool _discardBackground = false;

  bool get isCurrent =>
      cache.isFavoriteSessionEpochCurrent(folder.sourceKey, epoch) &&
      data.cacheScope == scope;
  bool get usesCursor => data.loadCachePage == null;
  FavoriteCachePage? get first => pages[1];
  int get comicCount =>
      pages.values.fold(0, (sum, page) => sum + page.comics.length);

  void discardUnviewed() {
    _discardBackground = true;
    pages.removeWhere((page, _) => !_foreground.contains(page));
  }

  Future<Res<FavoriteCachePage>> load(int page, {bool foreground = false}) {
    if (!isCurrent) {
      return Future.value(const Res.error('Favorite session changed'));
    }
    if (foreground) _foreground.add(page);
    if (pages[page] case final cached?) return Future.value(Res(cached));
    return _requests.putIfAbsent(page, () async {
      try {
        String? cursor;
        if (usesCursor && page > 1) {
          if (page > 2000) {
            return const Res.error('Favorite page limit reached');
          }
          for (
            var index = pages.containsKey(page - 1) ? page - 1 : 1;
            index < page;
            index++
          ) {
            final previous = await load(index, foreground: foreground);
            if (previous.error) return previous;
            cursor = previous.data.next;
            if (cursor == null) return const Res.error('End of favorites');
          }
        }
        final result = await Future.sync(
          () => usesCursor
              ? data.loadCacheNext!(cursor, folder.folderId)
              : data.loadCachePage!(page, folder.folderId, first?.total),
        );
        if (!isCurrent) return const Res.error('Favorite session changed');
        if (result.error) return result;
        final value = result.data;
        final total = value.total;
        final maxPage = value.maxPage;
        final next = value.next;
        final initial = first;
        final invalidPagination = usesCursor
            ? (value.comics.isEmpty && (page != 1 || next != null)) ||
                  (next != null &&
                      (next.isEmpty ||
                          next.length > 4096 ||
                          pages.values.any(
                            (previous) => previous.next == next,
                          )))
            : maxPage == null ||
                  maxPage < 0 ||
                  (total != null &&
                      (maxPage > total || (total == 0) != (maxPage == 0))) ||
                  (maxPage == 0 && page != 1) ||
                  (maxPage > 0 && page <= maxPage && value.comics.isEmpty) ||
                  (page > maxPage && value.comics.isNotEmpty);
        if (invalidPagination ||
            (total != null && (total < 0 || value.comics.length > total)) ||
            value.comics.any(
              (item) => item.id.trim().isEmpty || item.sourceKey != data.key,
            ) ||
            {for (final item in value.comics) item.id}.length !=
                value.comics.length ||
            (initial != null &&
                (initial.maxPage != maxPage ||
                    (initial.total != null &&
                        total != null &&
                        initial.total != total)))) {
          return const Res.error('Invalid favorite cache page');
        }
        if (!_discardBackground || _foreground.contains(page)) {
          pages[page] = value;
        }
        return result;
      } catch (error) {
        return Res.error(error.toString());
      } finally {
        _requests.remove(page);
      }
    });
  }
}

class _FavoriteCollectionSync {
  _FavoriteCollectionSync(this.fetch);

  final _FavoritePages fetch;
  final done = Completer<void>();
  final _events = StreamController<FavoriteFullCacheProgress>.broadcast();
  FavoriteFullCacheProgress? _latest;
  Completer<void>? _resume;
  bool Function()? manualCancel;

  bool get manual => manualCancel != null;
  bool get isCanceled => manualCancel?.call() ?? false;
  bool get finished => done.isCompleted;

  Future<void> pause() => (_resume ??= Completer<void>()).future;
  void wake() {
    _resume?.complete();
    _resume = null;
  }

  Stream<FavoriteFullCacheProgress> watch() => Stream.multi((out) {
    if (_latest case final latest?) out.add(latest);
    if (finished) {
      out.close();
    } else {
      final sub = _events.stream.listen(out.add, onDone: out.close);
      out.onCancel = sub.cancel;
    }
  });

  void emit(FavoriteFullCacheProgress progress) {
    _latest = progress;
    _events.add(progress);
  }

  void finish(FavoriteFullCacheProgress progress) {
    emit(progress);
    done.complete();
    wake();
    unawaited(_events.close());
  }
}
