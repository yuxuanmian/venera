import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorite_updates_check.dart';
import 'package:venera/foundation/favorite_updates_query.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates_query.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

typedef _FavoriteUpdatesScope = (FavoriteData data, int epoch, String settings);

_FavoriteUpdatesScope? _currentScope(String sourceKey) {
  final data = getFavoriteDataOrNull(sourceKey);
  if (data == null || !favoriteUpdatesSupported(data)) return null;
  return (
    data,
    NetworkFavoriteCacheManager().captureFavoriteSessionEpoch(sourceKey),
    data.cacheScope,
  );
}

Listenable _favoriteUpdatesChanges() {
  final cache = NetworkFavoriteCacheManager();
  return Listenable.merge([
    appdata.settings,
    ComicSourceManager(),
    cache,
    cache.collections.mutations,
    cache.favoriteCoverChanges,
    judgmentService.unreadRevision,
  ]);
}

class FavoriteUpdatesButton extends StatefulWidget {
  const FavoriteUpdatesButton({
    required this.sourceKey,
    this.onRouteChanged,
    super.key,
  });

  final String sourceKey;
  final ValueChanged<bool>? onRouteChanged;

  @override
  State<FavoriteUpdatesButton> createState() => _FavoriteUpdatesButtonState();
}

class _FavoriteUpdatesButtonState extends State<FavoriteUpdatesButton> {
  final _changes = _favoriteUpdatesChanges();
  _FavoriteUpdatesScope? _scope;
  int _count = 0;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _changes.addListener(_refresh);
    _refresh();
  }

  @override
  void didUpdateWidget(covariant FavoriteUpdatesButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceKey != widget.sourceKey) _refresh();
  }

  @override
  void dispose() {
    _changes.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    final request = ++_request;
    final scope = _currentScope(widget.sourceKey);
    final ready = scope != null && favoriteUpdatesCacheReady(scope.$1);
    if (scope != _scope || (!ready && _count != 0)) {
      setState(() {
        _scope = scope;
        _count = 0;
      });
    }
    if (ready) unawaited(_readCount(scope, request));
  }

  Future<void> _readCount(_FavoriteUpdatesScope scope, int request) async {
    try {
      final count = await favoriteUpdatesQuery.count(scope.$1);
      if (mounted &&
          request == _request &&
          scope == _currentScope(widget.sourceKey)) {
        setState(() => _count = count ?? 0);
      }
    } catch (_) {
      // Keep the last available count for this scope. The page can retry reads.
    }
  }

  Future<void> _open() async {
    if (_currentScope(widget.sourceKey) == null) return;
    final sourceKey = widget.sourceKey;
    final onRouteChanged = widget.onRouteChanged;
    onRouteChanged?.call(true);
    try {
      await context.to<void>(() => FavoriteUpdatesPage(sourceKey: sourceKey));
    } finally {
      onRouteChanged?.call(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_scope == null) return const SizedBox.shrink();
    return MergeSemantics(
      child: Semantics(
        value: '@count unread comics'.tlParams({'count': _count}),
        child: IconButton(
          tooltip: 'Updated comics'.tl,
          onPressed: _open,
          icon: Badge(
            isLabelVisible: _count > 0,
            backgroundColor: Colors.red.shade700,
            textColor: Colors.white,
            label: ExcludeSemantics(child: Text('$_count')),
            child: const Icon(Icons.new_releases_outlined),
          ),
        ),
      ),
    );
  }
}

class FavoriteUpdatesPage extends StatefulWidget {
  const FavoriteUpdatesPage({required this.sourceKey, super.key});

  final String sourceKey;

  @override
  State<FavoriteUpdatesPage> createState() => _FavoriteUpdatesPageState();
}

class _FavoriteUpdatesPageState extends State<FavoriteUpdatesPage> {
  static const _pageSize = 30;

  final _changes = _favoriteUpdatesChanges();
  final _search = TextEditingController();
  final _scroll = ScrollController();
  _FavoriteUpdatesScope? _scope;
  FavoriteUpdatesCheck? _check;
  List<FavoriteItem> _comics = const [];
  FollowUpdatesCursor? _next;
  int _resultPageSize = _pageSize;
  Timer? _searchDebounce;
  int _request = 0;
  bool _refreshScheduled = false;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasResult = false;
  bool _queryFailed = false;
  bool _checkPending = false;

  @override
  void initState() {
    super.initState();
    _changes.addListener(_onChanged);
    _onChanged();
  }

  @override
  void dispose() {
    _changes.removeListener(_onChanged);
    _searchDebounce?.cancel();
    _disposeCheck();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _disposeCheck() {
    _check?.removeListener(_onCheckChanged);
    _check?.dispose();
    _check = null;
  }

  void _onChanged() {
    final scope = _currentScope(widget.sourceKey);
    if (scope != _scope) {
      _disposeCheck();
      _request++;
      setState(() {
        _scope = scope;
        _comics = const [];
        _next = null;
        _hasResult = false;
        _queryFailed = false;
        _loading = false;
        _loadingMore = false;
        _checkPending = scope != null;
      });
      if (scope != null) {
        final check = FavoriteUpdatesCheck(scope.$1);
        _check = check..addListener(_onCheckChanged);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && identical(check, _check)) {
            unawaited(_runCheck(check));
          }
        });
      }
    }
    if (scope == null || _refreshScheduled) return;
    _refreshScheduled = true;
    scheduleMicrotask(() {
      _refreshScheduled = false;
      if (mounted && _scope != null) unawaited(_reload());
    });
  }

  void _onCheckChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _runCheck(
    FavoriteUpdatesCheck check, {
    bool retry = false,
  }) async {
    setState(() => _checkPending = true);
    try {
      await check.start(retry: retry);
    } finally {
      if (mounted && identical(check, _check)) {
        setState(() => _checkPending = false);
        _onChanged();
      }
    }
  }

  bool _isCurrent(int request, _FavoriteUpdatesScope scope) =>
      mounted &&
      request == _request &&
      scope == _currentScope(widget.sourceKey);

  Future<void> _reload() async {
    final scope = _scope;
    if (scope == null) return;
    final request = ++_request;
    final keyword = _search.text.trim();
    final pageSize = math.max(_pageSize, _comics.length);
    setState(() {
      _loading = true;
      _loadingMore = false;
      _queryFailed = false;
    });
    try {
      final result = await favoriteUpdatesQuery.queryPage(
        scope.$1,
        keyword: keyword,
        pageSize: pageSize,
      );
      if (!_isCurrent(request, scope)) return;
      setState(() {
        _comics =
            result?.items.map((entry) => entry.comic).toList() ?? const [];
        _next = result?.nextCursor;
        _resultPageSize = pageSize;
        _hasResult = result != null;
        _loading = false;
      });
    } catch (_) {
      if (!_isCurrent(request, scope)) return;
      setState(() {
        _loading = false;
        _queryFailed = true;
      });
    }
  }

  Future<void> _loadMore() async {
    final scope = _scope;
    final after = _next;
    if (scope == null ||
        after == null ||
        _loading ||
        _loadingMore ||
        _queryFailed ||
        _searchDebounce?.isActive == true) {
      return;
    }
    final request = _request;
    setState(() => _loadingMore = true);
    try {
      final result = await favoriteUpdatesQuery.queryPage(
        scope.$1,
        keyword: _search.text.trim(),
        after: after,
        pageSize: _resultPageSize,
      );
      if (!_isCurrent(request, scope)) return;
      if (result == null) {
        await _reload();
        return;
      }
      setState(() {
        _comics = [..._comics, ...result.items.map((entry) => entry.comic)];
        _next = result.nextCursor;
        _loadingMore = false;
      });
    } on FollowUpdatesCursorExpiredException {
      if (_isCurrent(request, scope)) await _reload();
    } catch (_) {
      if (!_isCurrent(request, scope)) return;
      setState(() {
        _loadingMore = false;
        _queryFailed = true;
      });
    }
  }

  void _searchChanged() {
    _searchDebounce?.cancel();
    _request++;
    setState(() {
      _loading = true;
      _loadingMore = false;
    });
    _searchDebounce = Timer(const Duration(milliseconds: 200), _submitSearch);
  }

  void _submitSearch() {
    _searchDebounce?.cancel();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    unawaited(_reload());
  }

  void _retryCheck() {
    if (_check case final check?) unawaited(_runCheck(check, retry: true));
  }

  @override
  Widget build(BuildContext context) {
    final phase = _check?.phase ?? FavoriteUpdatesCheckPhase.idle;
    final progress = switch (phase) {
      FavoriteUpdatesCheckPhase.syncing => 'Syncing favorites...'.tl,
      FavoriteUpdatesCheckPhase.waiting => 'Waiting to check for updates...'.tl,
      FavoriteUpdatesCheckPhase.checking => 'Checking for updates...'.tl,
      _ => null,
    };
    final error = switch (phase) {
      FavoriteUpdatesCheckPhase.failedSync => 'Could not sync favorites.'.tl,
      FavoriteUpdatesCheckPhase.failedCheck =>
        'Could not check for updates.'.tl,
      _ => null,
    };
    return Scaffold(
      appBar: Appbar(title: Text('Updated comics'.tl)),
      body: _scope == null
          ? Center(child: Text('Favorite updates unavailable'.tl))
          : Column(
              children: [
                if (progress != null)
                  Semantics(
                    liveRegion: true,
                    child: Column(
                      children: [
                        const LinearProgressIndicator(),
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(progress),
                        ),
                      ],
                    ),
                  ),
                if (error != null) _retryRow(error, _retryCheck),
                if (_queryFailed)
                  _retryRow('Update state could not be read'.tl, _reload),
                Expanded(
                  child: SmoothCustomScrollView(
                    controller: _scroll,
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: TextField(
                            controller: _search,
                            textInputAction: TextInputAction.search,
                            decoration: InputDecoration(
                              hintText: 'Search title, author, or tag'.tl,
                              prefixIcon: const Icon(Icons.search),
                              suffixIcon: _search.text.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: 'Clear'.tl,
                                      onPressed: () {
                                        _search.clear();
                                        _submitSearch();
                                      },
                                      icon: const Icon(Icons.close),
                                    ),
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                            onChanged: (_) => _searchChanged(),
                            onSubmitted: (_) => _submitSearch(),
                          ),
                        ),
                      ),
                      if (_comics.isNotEmpty)
                        SliverGridComics(
                          comics: _comics,
                          updateBadgeBuilder: (_) => true,
                          onTap: (comic, heroID) => context.to(
                            () => ComicPage(
                              id: comic.id,
                              sourceKey: comic.sourceKey,
                              cover: comic.cover,
                              title: comic.title,
                              heroID: heroID,
                            ),
                          ),
                          onLastItemBuild: _next == null
                              ? null
                              : () => WidgetsBinding.instance
                                    .addPostFrameCallback((_) {
                                      if (mounted) unawaited(_loadMore());
                                    }),
                        )
                      else if ((_loading || _checkPending) && progress == null)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (_hasResult &&
                          progress == null &&
                          error == null &&
                          !_queryFailed)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Text(
                              _search.text.trim().isEmpty
                                  ? 'No unread updates'.tl
                                  : 'No matching updates found'.tl,
                            ),
                          ),
                        ),
                      if (_loadingMore)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _retryRow(String message, VoidCallback retry) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Row(
      children: [
        Expanded(child: Semantics(liveRegion: true, child: Text(message))),
        TextButton(onPressed: retry, child: Text('Retry'.tl)),
      ],
    ),
  );
}
