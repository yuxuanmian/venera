import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/follow_updates_query.dart';
import 'package:venera/foundation/follow_updates_service.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

class FollowUpdatesWidget extends StatelessWidget {
  const FollowUpdatesWidget({super.key, this.asSliver = true});

  final bool asSliver;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 0.6,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => context.to(() => const FollowUpdatesPage()),
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              Text('Recent updates'.tl, style: ts.s18),
              const Spacer(),
              const Icon(Icons.arrow_right),
            ],
          ).paddingHorizontal(16),
        ),
      ),
    );
    return asSliver ? SliverToBoxAdapter(child: card) : card;
  }
}

class FollowUpdatesPage extends StatefulWidget {
  const FollowUpdatesPage({super.key});

  @override
  State<FollowUpdatesPage> createState() => _FollowUpdatesPageState();
}

class _FollowUpdatesPageState extends State<FollowUpdatesPage> {
  static const _pageSize = 30;
  static const _searchDebounce = Duration(milliseconds: 250);
  static const _syncHelp =
      'Select the source in Favorites and sync its favorites.';

  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  final _cache = NetworkFavoriteCacheManager();
  late FollowUpdateGate _gate;
  List<FollowUpdatesEntry> _entries = [];
  FollowUpdatesCursor? _nextCursor;
  int _requestId = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _loadError = false;
  bool _moreError = false;
  bool _loadMoreScheduled = false;
  Timer? _searchTimer;
  Timer? _cacheRefreshTimer;
  Timer? _expiryTimer;

  @override
  void initState() {
    super.initState();
    _gate = followUpdateCoordinator.evaluateGate();
    _cache.addListener(_onCacheChanged);
    _cache.favoriteCoverChanges.addListener(_onFavoriteCoverChanged);
    appdata.settings.addListener(_onScopeChanged);
    ComicSourceManager().addListener(_onScopeChanged);
    followUpdateCoordinator.progress.addListener(_onProgress);
    followUpdateCoordinator.scheduleRevision.addListener(_reload);
    unawaited(_reload());
  }

  @override
  void dispose() {
    _cache.removeListener(_onCacheChanged);
    _cache.favoriteCoverChanges.removeListener(_onFavoriteCoverChanged);
    appdata.settings.removeListener(_onScopeChanged);
    ComicSourceManager().removeListener(_onScopeChanged);
    followUpdateCoordinator.progress.removeListener(_onProgress);
    followUpdateCoordinator.scheduleRevision.removeListener(_reload);
    _searchTimer?.cancel();
    _cacheRefreshTimer?.cancel();
    _expiryTimer?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool _updateGate() {
    final next = followUpdateCoordinator.evaluateGate();
    final allowed = next.satisfiedSourceKeys;
    final changed = !setEquals(allowed, _gate.satisfiedSourceKeys);
    _gate = next;
    if (changed) {
      _entries.removeWhere((entry) => !allowed.contains(entry.sourceKey));
    }
    return changed;
  }

  bool _onScopeChanged() {
    final previous = _gate;
    if (_updateGate()) {
      unawaited(_reload(resetScroll: true));
      return true;
    }
    if (!setEquals(previous.sourceKeys, _gate.sourceKeys)) {
      setState(() {});
    }
    return false;
  }

  void _onCacheChanged() {
    if (_onScopeChanged()) return;
    _cacheRefreshTimer?.cancel();
    _cacheRefreshTimer = Timer(const Duration(milliseconds: 100), _reload);
  }

  void _onFavoriteCoverChanged() {
    final change = _cache.favoriteCoverChanges.value;
    if (change == null || !change.refreshFollowUpdates) return;
    if (_entries.any(
      (entry) =>
          entry.sourceKey == change.sourceKey &&
          change.covers.containsKey(entry.comicId),
    )) {
      unawaited(_reload());
    }
  }

  void _onProgress() {
    if (followUpdateCoordinator.currentProgress.isRoundEnd) {
      unawaited(_reload());
    } else {
      setState(() {});
    }
  }

  void _scheduleExpiry() {
    _expiryTimer?.cancel();
    if (_entries.isEmpty) return;
    // Entries are ordered by auto-hot expiration, newest first.
    final deadline = _entries.last.autoHotUntil!;
    _expiryTimer = Timer(deadline.difference(DateTime.now()), _reload);
  }

  Future<void> _reload({bool resetScroll = false}) async {
    _searchTimer?.cancel();
    _cacheRefreshTimer?.cancel();
    final scopeChanged = _updateGate();
    final now = DateTime.now();
    final requestId = ++_requestId;
    final sources = _gate.satisfiedSourceKeys;
    final query = _searchController.text;
    setState(() {
      _entries.removeWhere((entry) => !entry.autoHotUntil!.isAfter(now));
      _nextCursor = null;
      _loading = sources.isNotEmpty;
      _loadingMore = false;
      _loadError = false;
      _moreError = false;
    });
    _scheduleExpiry();
    if (resetScroll || scopeChanged) {
      _jumpToTop();
    }
    if (sources.isEmpty) return;

    try {
      final result = await followUpdatesQueryService.queryPage(
        allowedSourceKeys: sources,
        now: now,
        tab: FollowUpdatesTab.recent,
        query: query,
        pageSize: _pageSize,
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _entries = result.items.toList();
        _nextCursor = result.nextCursor;
        _loading = false;
      });
      _scheduleExpiry();
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loading = false;
        _loadError = true;
      });
    }
  }

  Future<void> _loadNextPage() async {
    final cursor = _nextCursor;
    if (cursor == null || _loadingMore) return;
    final requestId = _requestId;
    setState(() {
      _loadingMore = true;
      _moreError = false;
    });
    try {
      final result = await followUpdatesQueryService.queryPage(
        allowedSourceKeys: _gate.satisfiedSourceKeys,
        now: DateTime.now(),
        tab: FollowUpdatesTab.recent,
        query: _searchController.text,
        pageSize: _pageSize,
        cursor: cursor,
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _entries.addAll(result.items);
        _nextCursor = result.nextCursor;
        _loadingMore = false;
      });
      _scheduleExpiry();
    } on FollowUpdatesCursorExpiredException {
      if (mounted && requestId == _requestId) {
        _entries.clear();
        await _reload(resetScroll: true);
      }
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loadingMore = false;
        _moreError = true;
      });
    }
  }

  void _scheduleLoadMore() {
    if (_nextCursor == null ||
        _loadingMore ||
        _moreError ||
        _loadMoreScheduled) {
      return;
    }
    _loadMoreScheduled = true;
    final requestId = _requestId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadMoreScheduled = false;
      if (mounted && requestId == _requestId) unawaited(_loadNextPage());
    });
  }

  void _jumpToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  void _onSearchChanged() {
    _requestId++;
    _searchTimer?.cancel();
    _expiryTimer?.cancel();
    setState(() {
      _entries.clear();
      _nextCursor = null;
      _loading = true;
      _loadingMore = false;
      _loadError = false;
      _moreError = false;
    });
    _jumpToTop();
    _searchTimer = Timer(_searchDebounce, () => _reload(resetScroll: true));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SmoothCustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverAppbar(title: Text('Recent updates'.tl)),
        _buildProgressArea(context),
        if (!_gate.isSatisfied)
          _buildGateNotice(context)
        else ...[
          SliverToBoxAdapter(
            child: TextField(
              key: const ValueKey('follow-up-search-recent'),
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search title, author, or tag'.tl,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear'.tl,
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _searchController.clear();
                          _onSearchChanged();
                        },
                      ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => _onSearchChanged(),
              onSubmitted: (_) => unawaited(_reload(resetScroll: true)),
            ).paddingHorizontal(12).paddingVertical(8),
          ),
          if (_gate.hasPendingSources)
            SliverToBoxAdapter(
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 14,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '@c sources still pending'.tlParams({
                            'c': _gate.pendingSourceKeys.length,
                          }),
                          style: ts.s12,
                        ),
                        Text(_syncHelp.tl, style: ts.s12),
                      ],
                    ),
                  ),
                ],
              ).paddingHorizontal(16).paddingVertical(4),
            ),
          ..._buildList(context),
        ],
      ],
    ),
  );

  List<Widget> _buildList(BuildContext context) {
    final sections = <DateTime, List<Comic>>{};
    for (final entry in _entries) {
      final detectedAt = entry.autoHotUntil!.subtract(kFollowUpdateHotWindow);
      final date = DateUtils.dateOnly(detectedAt.toLocal());
      (sections[date] ??= []).add(entry.comic);
    }

    return [
      if (_loadError)
        SliverToBoxAdapter(child: _buildUnreadableNotice(context)),
      if (sections.isEmpty && !_loadError)
        if (_loading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else
          SliverFillRemaining(
            hasScrollBody: false,
            child: _buildEmptyState(context),
          ),
      for (final MapEntry(key: date, value: comics) in sections.entries) ...[
        SliverToBoxAdapter(
          key: ValueKey(date),
          child: Semantics(
            header: true,
            child: Text(
              MaterialLocalizations.of(context).formatFullDate(date),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ).paddingHorizontal(16).paddingVertical(8),
        ),
        SliverGridComics(
          key: ValueKey(('recent-updates', date)),
          comics: comics,
          onTap: _openFromList,
        ),
      ],
      if (_nextCursor != null)
        SliverLayoutBuilder(
          builder: (context, constraints) {
            if (constraints.remainingCacheExtent > 0) _scheduleLoadMore();
            if (!_loadingMore && !_moreError) {
              return const SliverToBoxAdapter();
            }
            return SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: _moreError
                      ? TextButton.icon(
                          onPressed: _loadNextPage,
                          icon: const Icon(Icons.refresh),
                          label: Text('Retry'.tl),
                        )
                      : const CircularProgressIndicator(),
                ),
              ),
            );
          },
        ),
    ];
  }

  Widget _buildGateNotice(BuildContext context) {
    final currentGate = _gate;
    final noSources = !currentGate.hasSources;
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                noSources ? Icons.inbox_outlined : Icons.downloading,
                size: 48,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 16),
              Text(
                noSources
                    ? 'No source can be followed'.tl
                    : 'Favorites are not fully cached yet'.tl,
                style: ts.s18,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                noSources
                    ? 'Enable and sign in to at least one source that supports scanning.'
                          .tl
                    : _syncHelp.tl,
                style: ts.s14,
                textAlign: TextAlign.center,
              ),
              if (!noSources) ...[
                const SizedBox(height: 8),
                Text(
                  '@c sources still pending'.tlParams({
                    'c': currentGate.pendingSourceKeys.length,
                  }),
                  style: ts.s12,
                ),
                if (currentGate.pendingSourceKeys.contains(
                  NetworkFavoriteCacheManager.accountSwitchClearedSourceKey,
                )) ...[
                  const SizedBox(height: 8),
                  Text('Account switched'.tl, style: ts.s14),
                  Text(
                    'Follow-up needs a complete favorite cache again after '
                            'switching accounts.'
                        .tl,
                    style: ts.s12,
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProgressArea(BuildContext context) {
    final caching = followUpdateCoordinator.isCachingFavorites;
    final running = followUpdateCoordinator.isRunning;
    final progress = followUpdateCoordinator.currentProgress;
    final hasFailureCounts =
        progress.incompleteCollectionScans > 0 || progress.comicFailures > 0;
    if (!running && !caching && !hasFailureCounts) {
      return const SliverToBoxAdapter();
    }
    final completed = !running && !caching;
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              completed
                  ? 'Follow-up check summary'.tl
                  : caching
                  ? 'Caching favorites'.tl
                  : 'Checking updates'.tl,
            ),
            if (!completed) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress.fraction),
              const SizedBox(height: 4),
              Text(followUpdateProgressLabel(progress), style: ts.s12),
            ],
            if (caching) ...[
              const SizedBox(height: 4),
              Text('Caching is not finished yet'.tl, style: ts.s12),
            ],
            if (progress.incompleteCollectionScans > 0) ...[
              const SizedBox(height: 6),
              Text(
                'Incomplete favorite scans: @c'.tlParams({
                  'c': progress.incompleteCollectionScans,
                }),
                style: ts.s12,
              ),
            ],
            if (progress.comicFailures > 0) ...[
              const SizedBox(height: 4),
              Text(
                'Comic check failures: @c'.tlParams({
                  'c': progress.comicFailures,
                }),
                style: ts.s12,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildUnreadableNotice(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline),
        const SizedBox(width: 8),
        Expanded(child: Text('Update state could not be read'.tl)),
        TextButton(onPressed: _reload, child: Text('Retry'.tl)),
      ],
    ),
  );

  Widget _buildEmptyState(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.history,
          size: 40,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 8),
        Text(
          _searchController.text.trim().isEmpty
              ? 'No recent updates found'.tl
              : 'No matching updates found'.tl,
          style: ts.s16,
        ),
      ],
    ),
  );

  void _openFromList(Comic comic, int heroID) {
    context.to(
      () => ComicPage(
        id: comic.id,
        sourceKey: comic.sourceKey,
        cover: comic.cover,
        title: comic.title,
        heroID: heroID,
      ),
    );
  }
}

String followUpdateProgressLabel(FollowUpdateProgress progress) =>
    progress.discovered > 0 || progress.isComplete
    ? '@done/@total tasks'.tlParams({
        'done': progress.finished,
        'total': progress.discovered,
      })
    : 'Finding what to check'.tl;
