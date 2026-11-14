import 'dart:async';
import 'dart:math' as math;

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
import 'package:venera/foundation/global_state.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

/// Debug builds may bypass the pre-condition gate (Contract F2.6).
bool _debugGateBypass = false;

Set<String> _allowedSources(FollowUpdateGate gate) =>
    kDebugMode && _debugGateBypass ? gate.sourceKeys : gate.satisfiedSourceKeys;

class FollowUpdatesWidget extends StatefulWidget {
  const FollowUpdatesWidget({super.key});

  @override
  State<FollowUpdatesWidget> createState() => _FollowUpdatesWidgetState();
}

class _FollowUpdatesWidgetState
    extends AutomaticGlobalState<FollowUpdatesWidget> {
  int _count = 0;
  int _requestId = 0;
  Timer? _cacheRefreshDebounce;
  StreamSubscription<void>? _judgmentBatches;
  late final NetworkFavoriteCacheManager _cache;
  Set<String> _lastAllowedSourceKeys = <String>{};

  bool get _enabled => followUpdatesEnabled;

  FollowUpdateGate get gate => followUpdateCoordinator.evaluateGate();

  Future<void> getCount() async {
    final requestId = ++_requestId;
    if (!_enabled) {
      if (mounted) setState(() => _count = 0);
      return;
    }
    final sources = _allowedSources(gate);
    if (sources.isEmpty) {
      if (mounted) setState(() => _count = 0);
      return;
    }
    final scopeAtStart = Set<String>.of(sources);
    try {
      final identities = await followUpdatesQueryService
          .readVisibleUnreadIdentities(allowedSourceKeys: sources);
      if (!mounted ||
          requestId != _requestId ||
          !setEquals(scopeAtStart, _allowedSources(gate))) {
        return;
      }
      setState(() => _count = identities.length);
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() => _count = 0);
    }
  }

  void updateCount() => unawaited(getCount());

  @override
  void initState() {
    super.initState();
    _cache = NetworkFavoriteCacheManager();
    _cache.addListener(_onCacheChanged);
    _lastAllowedSourceKeys = _allowedSources(gate);
    updateCount();
    followUpdateCoordinator.progress.addListener(_onProgress);
    _judgmentBatches = judgmentService.events.listen((_) => updateCount());
  }

  @override
  void dispose() {
    _cacheRefreshDebounce?.cancel();
    _cache.removeListener(_onCacheChanged);
    followUpdateCoordinator.progress.removeListener(_onProgress);
    unawaited(_judgmentBatches?.cancel());
    super.dispose();
  }

  void _onProgress() {
    if (!mounted) return;
    if (followUpdateCoordinator.currentProgress.isRoundEnd) updateCount();
  }

  void _onCacheChanged() {
    if (!mounted) return;
    final allowed = _allowedSources(gate);
    if (!setEquals(allowed, _lastAllowedSourceKeys)) {
      _lastAllowedSourceKeys = Set<String>.of(allowed);
      _requestId++;
      setState(() => _count = 0);
    }
    _cacheRefreshDebounce?.cancel();
    _cacheRefreshDebounce = Timer(
      const Duration(milliseconds: 100),
      updateCount,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 56,
                child: Row(
                  children: [
                    Center(child: Text('Follow Updates'.tl, style: ts.s18)),
                    const Spacer(),
                    const Icon(Icons.arrow_right),
                  ],
                ),
              ).paddingHorizontal(16),
              if (!_enabled)
                _chip(
                  context,
                  Text('Follow updates disabled'.tl, style: ts.s16),
                ),
              if (_enabled && _count > 0)
                _chip(
                  context,
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.new_releases,
                        size: 16,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '@c updates'.tlParams({'c': _count}),
                        style: ts.s16.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  highlight: true,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, Widget child, {bool highlight = false}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        margin: const EdgeInsets.only(bottom: 16, left: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: highlight
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHigh,
        ),
        child: child,
      );

  @override
  Object? get key => 'FollowUpdatesWidget';
}

class FollowUpdatesPage extends StatefulWidget {
  const FollowUpdatesPage({super.key});

  @override
  State<FollowUpdatesPage> createState() => FollowUpdatesPageState();
}

class FollowUpdatesPageState extends AutomaticGlobalState<FollowUpdatesPage>
    with SingleTickerProviderStateMixin {
  static const _pageSize = 30;
  static const _searchDebounce = Duration(milliseconds: 250);

  late final TabController _tabController;
  late final NetworkFavoriteCacheManager _cache;
  late final Map<FollowUpdatesTab, _FollowUpdatesTabView> _views;
  FollowUpdatesTab _activeTab = FollowUpdatesTab.unread;
  Set<String> _lastAllowedSourceKeys = <String>{};
  int _scopeGeneration = 0;
  bool _markingAllAsRead = false;
  Timer? _cacheRefreshDebounce;
  StreamSubscription<void>? _judgmentBatches;

  bool get _enabled => followUpdatesEnabled;

  FollowUpdateGate get gate => followUpdateCoordinator.evaluateGate();

  String? get _accountSwitchSourceKey =>
      NetworkFavoriteCacheManager.accountSwitchClearedSourceKey;

  bool get _showList => !_enabled || _allowedSources(gate).isNotEmpty;

  _FollowUpdatesTabView get _activeView => _views[_activeTab]!;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this)
      ..addListener(_onTabChanged);
    _views = {
      FollowUpdatesTab.unread: _FollowUpdatesTabView(
        tab: FollowUpdatesTab.unread,
      ),
      FollowUpdatesTab.recent: _FollowUpdatesTabView(
        tab: FollowUpdatesTab.recent,
      ),
    };
    for (final entry in _views.entries) {
      entry.value.scrollController.addListener(() {
        if (_activeTab != entry.key) return;
        final controller = entry.value.scrollController;
        if (controller.hasClients) {
          entry.value.scrollOffset = controller.offset;
        }
      });
    }
    _cache = NetworkFavoriteCacheManager();
    _cache.addListener(_onCacheChanged);
    _cache.favoriteCoverChanges.addListener(_onFavoriteCoverChanged);
    _lastAllowedSourceKeys = _currentAllowedSourceKeys();
    followUpdateCoordinator.progress.addListener(_onProgress);
    followUpdateCoordinator.scheduleRevision.addListener(_onScheduleChanged);
    _judgmentBatches = judgmentService.events.listen(
      (_) => _markTabNeedsRefresh(FollowUpdatesTab.unread),
    );
    unawaited(_reloadTab(FollowUpdatesTab.unread));
  }

  @override
  void dispose() {
    for (final view in _views.values) {
      view.searchDebounce?.cancel();
      view.searchController.dispose();
      view.scrollController.dispose();
    }
    _cacheRefreshDebounce?.cancel();
    _cache.removeListener(_onCacheChanged);
    _cache.favoriteCoverChanges.removeListener(_onFavoriteCoverChanged);
    followUpdateCoordinator.progress.removeListener(_onProgress);
    followUpdateCoordinator.scheduleRevision.removeListener(_onScheduleChanged);
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    unawaited(_judgmentBatches?.cancel());
    super.dispose();
  }

  Set<String> _currentAllowedSourceKeys() => _allowedSources(gate);

  _FollowUpdatesTabView _view(FollowUpdatesTab tab) => _views[tab]!;

  void _onTabChanged() {
    final next = FollowUpdatesTab.values[_tabController.index];
    if (next == _activeTab) return;
    final current = _activeView;
    if (current.scrollController.hasClients) {
      current.scrollOffset = current.scrollController.offset;
    }
    setState(() => _activeTab = next);
    final view = _view(next);
    final expired = _hasExpiredRecentWindow(view);
    if (!view.hasLoaded || view.needsRefresh || expired) {
      unawaited(_reloadTab(next, clearContent: expired, resetScroll: false));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = _view(next).scrollController;
      if (!mounted || !controller.hasClients) return;
      final target = _view(next).scrollOffset.clamp(
        controller.position.minScrollExtent,
        controller.position.maxScrollExtent,
      );
      controller.jumpTo(target);
    });
  }

  bool _hasExpiredRecentWindow(_FollowUpdatesTabView view) {
    final deadline = view.earliestAutoHotUntil;
    return view.tab == FollowUpdatesTab.recent &&
        view.hasLoaded &&
        deadline != null &&
        !deadline.isAfter(DateTime.now());
  }

  DateTime? _earliestHotDeadline(Iterable<FollowUpdatesEntry> entries) {
    DateTime? earliest;
    for (final entry in entries) {
      earliest = _earlierHotDeadline(earliest, entry.autoHotUntil);
    }
    return earliest;
  }

  DateTime? _earlierHotDeadline(DateTime? left, DateTime? right) {
    if (left == null) return right;
    if (right == null) return left;
    return right.isBefore(left) ? right : left;
  }

  void _onProgress() {
    if (!mounted) return;
    if (!followUpdateCoordinator.currentProgress.isRoundEnd) {
      setState(() {});
      return;
    }
    _refreshCommittedStores();
  }

  void _onScheduleChanged() {
    _markTabNeedsRefresh(FollowUpdatesTab.recent);
  }

  void _onCacheChanged() {
    if (!mounted) return;
    final scopeChanged = _syncSourceScope();
    if (scopeChanged) {
      for (final view in _views.values) {
        view.needsRefresh = true;
      }
      setState(() {});
    }
    _cacheRefreshDebounce?.cancel();
    _cacheRefreshDebounce = Timer(
      const Duration(milliseconds: 100),
      _refreshAfterCacheChange,
    );
  }

  void _onFavoriteCoverChanged() {
    final change = _cache.favoriteCoverChanges.value;
    if (!mounted || change == null || !change.refreshFollowUpdates) return;
    var activeChanged = false;
    for (final view in _views.values) {
      final changed = view.comics.any(
        (comic) =>
            comic.sourceKey == change.sourceKey &&
            change.covers.containsKey(comic.id),
      );
      if (changed) {
        view.needsRefresh = true;
        activeChanged |= view.tab == _activeTab;
      }
    }
    if (!activeChanged) return;
    setState(() {});
    if (_showList) {
      unawaited(_reloadTab(_activeTab));
    }
  }

  void _refreshAfterCacheChange() {
    if (!mounted) return;
    final scopeChanged = _syncSourceScope();
    for (final view in _views.values) {
      view.needsRefresh = true;
    }
    setState(() {});
    if (_showList) {
      unawaited(
        _reloadTab(
          _activeTab,
          clearContent: scopeChanged,
          resetScroll: scopeChanged,
        ),
      );
    }
  }

  void _refreshCommittedStores() {
    final scopeChanged = _syncSourceScope();
    for (final view in _views.values) {
      view.needsRefresh = true;
    }
    setState(() {});
    if (_showList) {
      unawaited(
        _reloadTab(
          _activeTab,
          clearContent: scopeChanged,
          resetScroll: scopeChanged,
        ),
      );
    }
  }

  void _markTabNeedsRefresh(FollowUpdatesTab tab) {
    if (!mounted) return;
    final view = _view(tab);
    view.needsRefresh = true;
    if (_activeTab == tab && _showList) {
      unawaited(_reloadTab(tab));
    }
  }

  bool _syncSourceScope() {
    final allowed = _currentAllowedSourceKeys();
    final changed = !setEquals(allowed, _lastAllowedSourceKeys);
    _lastAllowedSourceKeys = Set<String>.of(allowed);
    if (changed) {
      _scopeGeneration++;
      for (final view in _views.values) {
        view
          ..requestId = view.requestId + 1
          ..comics.clear()
          ..nextCursor = null
          ..loading = false
          ..loadingMore = false
          ..loadError = false
          ..moreError = false
          ..hasLoaded = false
          ..needsRefresh = true
          ..scrollOffset = 0
          ..earliestAutoHotUntil = null;
      }
      _jumpToTop(_activeTab);
    }
    return changed;
  }

  Future<void> updateComics() async {
    if (!mounted) return;
    final scopeChanged = _syncSourceScope();
    if (!_showList) {
      setState(() {
        for (final view in _views.values) {
          view
            ..requestId = view.requestId + 1
            ..comics.clear()
            ..loading = false
            ..loadError = false
            ..hasLoaded = false
            ..earliestAutoHotUntil = null;
        }
      });
      return;
    }
    await _reloadTab(
      _activeTab,
      clearContent: scopeChanged,
      resetScroll: scopeChanged,
    );
  }

  Future<void> _reloadTab(
    FollowUpdatesTab tab, {
    bool clearContent = false,
    bool resetScroll = false,
  }) async {
    if (!mounted) return;
    final view = _view(tab);
    final requestId = ++view.requestId;
    final scopeGeneration = _scopeGeneration;
    final query = view.searchController.text;
    final allowedAtStart = _currentAllowedSourceKeys();
    view
      ..needsRefresh = false
      ..nextCursor = null
      ..loadingMore = false
      ..moreError = false
      ..loadError = false
      ..loading = clearContent || view.comics.isEmpty;
    if (clearContent) {
      view
        ..comics.clear()
        ..earliestAutoHotUntil = null;
    }
    if (resetScroll) {
      view.scrollOffset = 0;
      _jumpToTop(tab);
    }
    setState(() {});

    try {
      final result = await followUpdatesQueryService.queryPage(
        allowedSourceKeys: allowedAtStart,
        now: DateTime.now(),
        tab: tab,
        query: query,
        pageSize: _pageSize,
      );
      if (!mounted ||
          requestId != view.requestId ||
          scopeGeneration != _scopeGeneration ||
          !setEquals(allowedAtStart, _currentAllowedSourceKeys()) ||
          query != view.searchController.text) {
        return;
      }
      setState(() {
        view
          ..comics = result.items.map((entry) => entry.comic).toList()
          ..nextCursor = result.nextCursor
          ..loading = false
          ..hasLoaded = true
          ..loadError = false
          ..earliestAutoHotUntil = tab == FollowUpdatesTab.recent
              ? _earliestHotDeadline(result.items)
              : null;
      });
    } on FollowUpdatesCursorExpiredException {
      if (mounted && requestId == view.requestId) {
        await _reloadTab(tab, clearContent: true, resetScroll: true);
      }
    } catch (_) {
      if (!mounted || requestId != view.requestId) return;
      setState(() {
        view
          ..loading = false
          ..hasLoaded = true
          ..loadError = true;
      });
    }
  }

  Future<void> _loadNextPage(FollowUpdatesTab tab) async {
    final view = _view(tab);
    final cursor = view.nextCursor;
    if (cursor == null || view.loading || view.loadingMore) return;
    final requestId = view.requestId;
    final scopeGeneration = _scopeGeneration;
    final query = view.searchController.text;
    final allowedAtStart = _currentAllowedSourceKeys();
    setState(() {
      view
        ..loadingMore = true
        ..moreError = false;
    });
    try {
      final result = await followUpdatesQueryService.queryPage(
        allowedSourceKeys: allowedAtStart,
        now: DateTime.now(),
        tab: tab,
        query: query,
        pageSize: _pageSize,
        cursor: cursor,
      );
      if (!mounted ||
          requestId != view.requestId ||
          scopeGeneration != _scopeGeneration ||
          !setEquals(allowedAtStart, _currentAllowedSourceKeys()) ||
          query != view.searchController.text) {
        return;
      }
      final known = {
        for (final comic in view.comics) '${comic.sourceKey}\u0000${comic.id}',
      };
      final nextDeadline = tab == FollowUpdatesTab.recent
          ? _earlierHotDeadline(
              view.earliestAutoHotUntil,
              _earliestHotDeadline(result.items),
            )
          : null;
      setState(() {
        for (final entry in result.items) {
          final identity = '${entry.comic.sourceKey}\u0000${entry.comic.id}';
          if (known.add(identity)) view.comics.add(entry.comic);
        }
        view
          ..nextCursor = result.nextCursor
          ..loadingMore = false
          ..moreError = false
          ..earliestAutoHotUntil = nextDeadline;
      });
    } on FollowUpdatesCursorExpiredException {
      if (mounted && requestId == view.requestId) {
        await _reloadTab(tab, clearContent: true, resetScroll: true);
      }
    } catch (_) {
      if (!mounted || requestId != view.requestId) return;
      setState(() {
        view
          ..loadingMore = false
          ..moreError = true;
      });
    }
  }

  void _scheduleLoadMore(FollowUpdatesTab tab) {
    final view = _view(tab);
    if (view.loadMoreScheduled ||
        view.nextCursor == null ||
        view.loading ||
        view.loadingMore ||
        view.moreError) {
      return;
    }
    view.loadMoreScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      view.loadMoreScheduled = false;
      if (mounted && _activeTab == tab) unawaited(_loadNextPage(tab));
    });
  }

  void _jumpToTop(FollowUpdatesTab tab) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = _view(tab).scrollController;
      if (mounted && _activeTab == tab && controller.hasClients) {
        controller.jumpTo(controller.position.minScrollExtent);
      }
    });
  }

  void _onSearchChanged(FollowUpdatesTab tab) {
    final view = _view(tab);
    view
      ..requestId = view.requestId + 1
      ..searchDebounce?.cancel()
      ..comics.clear()
      ..nextCursor = null
      ..loading = _showList
      ..loadingMore = false
      ..loadError = false
      ..moreError = false
      ..hasLoaded = false
      ..needsRefresh = false
      ..scrollOffset = 0
      ..earliestAutoHotUntil = null;
    setState(() {});
    if (!_showList) return;
    view.searchDebounce = Timer(
      _searchDebounce,
      () => _reloadTab(tab, clearContent: true, resetScroll: true),
    );
  }

  void _submitSearch(FollowUpdatesTab tab) {
    final view = _view(tab);
    view.searchDebounce?.cancel();
    unawaited(_reloadTab(tab, clearContent: true, resetScroll: true));
  }

  @override
  Widget build(BuildContext context) {
    final view = _activeView;
    return Scaffold(
      body: SmoothCustomScrollView(
        key: ValueKey(_activeTab),
        controller: view.scrollController,
        slivers: [
          SliverAppbar(
            title: Text('Follow Updates'.tl),
            actions: [
              if (_enabled)
                IconButton(
                  tooltip: 'Update check progress'.tl,
                  onPressed: showBaselineProgress,
                  icon: const Icon(Icons.pause_circle_outline),
                ),
              if (_enabled)
                PopupMenuButton<String>(
                  tooltip: 'more'.tl,
                  icon: const Icon(Icons.more_vert),
                  onSelected: (value) {
                    if (value == 'disable') disable();
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'disable',
                      child: Text(
                        'Disable'.tl,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          if (!_enabled)
            buildDisabled(context)
          else ...[
            buildProgressArea(context),
            if (!_showList)
              buildGateNotice(context)
            else
              ..._buildTabSlivers(context),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildTabSlivers(BuildContext context) {
    final view = _activeView;
    return [
      SliverPersistentHeader(
        pinned: true,
        delegate: _PinnedTabBarDelegate(
          controller: _tabController,
          tabs: [
            Tab(text: 'Unread updates'.tl),
            Tab(text: 'Recent updates'.tl),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: Row(
          children: [
            if (followUpdateCoordinator.isRunning)
              Expanded(
                child: Text('Follow-up scan in progress'.tl, style: ts.s12),
              )
            else
              const Spacer(),
            IconButton(
              tooltip: 'Check Now'.tl,
              onPressed: startRefresh,
              icon: const Icon(Icons.refresh),
            ),
            if (_activeTab == FollowUpdatesTab.unread &&
                view.searchController.text.isEmpty &&
                view.comics.isNotEmpty)
              IconButton(
                tooltip: 'Mark all as read'.tl,
                icon: _markingAllAsRead
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.clear_all),
                onPressed: _markingAllAsRead ? null : markAllAsRead,
              ),
          ],
        ).paddingHorizontal(12),
      ),
      SliverToBoxAdapter(
        child: TextField(
          key: ValueKey('follow-up-search-${_activeTab.name}'),
          controller: view.searchController,
          decoration: InputDecoration(
            hintText: 'Search title, author, or tag'.tl,
            prefixIcon: const Icon(Icons.search),
            suffixIcon: view.searchController.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear'.tl,
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      view.searchController.clear();
                      _onSearchChanged(_activeTab);
                    },
                  ),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (_) => _onSearchChanged(_activeTab),
          onSubmitted: (_) => _submitSearch(_activeTab),
        ).paddingHorizontal(12).paddingVertical(8),
      ),
      if (gate.hasPendingSources)
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
                child: Text(
                  '@c sources are not fully cached yet, so they are not followed'
                      .tlParams({'c': gate.pendingSourceKeys.length}),
                  style: ts.s12,
                ),
              ),
            ],
          ).paddingHorizontal(16).paddingVertical(4),
        ),
      if (_activeTab == FollowUpdatesTab.unread && view.comics.isNotEmpty)
        SliverToBoxAdapter(
          child: Text(
            'Updates are marked read when you start reading.'.tl,
          ).paddingHorizontal(16).paddingVertical(4),
        ),
      ..._buildTabContent(context, view),
    ];
  }

  List<Widget> _buildTabContent(
    BuildContext context,
    _FollowUpdatesTabView view,
  ) {
    if (view.loading && view.comics.isEmpty) {
      return const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ];
    }
    if (view.loadError && view.comics.isEmpty) {
      return [SliverToBoxAdapter(child: _buildUnreadableNotice(context, view))];
    }
    if (view.comics.isEmpty) {
      return [SliverToBoxAdapter(child: _buildEmptyState(context, view))];
    }
    return [
      if (view.loadError)
        SliverToBoxAdapter(child: _buildUnreadableNotice(context, view)),
      SliverGridComics(
        comics: view.comics,
        onLastItemBuild: () => _scheduleLoadMore(view.tab),
        onTap: (comic, heroID) => _openFromList(comic, heroID),
      ),
      if (view.loadingMore)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
        )
      else if (view.moreError)
        SliverToBoxAdapter(
          child: Center(
            child: TextButton.icon(
              onPressed: () => unawaited(_loadNextPage(view.tab)),
              icon: const Icon(Icons.refresh),
              label: Text('Retry'.tl),
            ),
          ),
        ),
    ];
  }

  Widget buildDisabled(BuildContext context) => SliverFillRemaining(
    hasScrollBody: false,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.power_settings_new,
            size: 48,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text('Follow updates disabled'.tl, style: ts.s18),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: enable,
            icon: const Icon(Icons.play_arrow),
            label: Text('Enable Follow Updates'.tl),
          ),
        ],
      ),
    ),
  );

  Widget buildGateNotice(BuildContext context) {
    final currentGate = gate;
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
                    : 'Follow-up results need a complete favorite cache for every tracked source.'
                          .tl,
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
                if (_accountSwitchSourceKey != null) ...[
                  const SizedBox(height: 8),
                  Text('Account switched'.tl, style: ts.s14),
                  Text(
                    'Follow-up needs a complete favorite cache again after '
                            'switching accounts.'
                        .tl,
                    style: ts.s12,
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: startFullCache,
                  icon: const Icon(Icons.cloud_download),
                  label: Text('Cache favorites completely'.tl),
                ),
              ],
              if (kDebugMode) ...[
                const SizedBox(height: 24),
                SwitchListTile(
                  value: _debugGateBypass,
                  onChanged: (value) {
                    setState(() => _debugGateBypass = value);
                    _refreshAfterCacheChange();
                  },
                  title: Text('Bypass the follow-up gate (debug)'.tl),
                  subtitle: Text(
                    'Shows the list even when the cache is incomplete.'.tl,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget buildProgressArea(BuildContext context) {
    final caching = followUpdateCoordinator.isCachingFavorites;
    final running = followUpdateCoordinator.isRunning;
    final progress = followUpdateCoordinator.currentProgress;
    final hasFailureCounts =
        progress.incompleteCollectionScans > 0 || progress.comicFailures > 0;
    if (!running && !caching && !hasFailureCounts) {
      return buildPostCacheTransition(context);
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
            if (!completed) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: caching
                    ? followUpdateCoordinator.cancelFullCache
                    : followUpdateCoordinator.cancel,
                icon: const Icon(Icons.stop),
                label: Text('Cancel'.tl),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget buildPostCacheTransition(BuildContext context) {
    if (!followUpdateCoordinator.favoritesJustCached) {
      return const SliverToBoxAdapter();
    }
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(Icons.check_circle_outline),
            const SizedBox(width: 8),
            Expanded(child: Text('Favorites are fully cached now'.tl)),
            TextButton(
              onPressed: () {
                followUpdateCoordinator.acknowledgeFavoritesCached();
                _refreshCommittedStores();
              },
              child: Text('Show updates'.tl),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUnreadableNotice(
    BuildContext context,
    _FollowUpdatesTabView view,
  ) => Container(
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
        TextButton(
          onPressed: () => unawaited(
            _reloadTab(view.tab, clearContent: view.comics.isEmpty),
          ),
          child: Text('Retry'.tl),
        ),
      ],
    ),
  );

  Widget _buildEmptyState(BuildContext context, _FollowUpdatesTabView view) =>
      SizedBox(
        height: math.max(240, MediaQuery.sizeOf(context).height * 0.5),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                view.tab == FollowUpdatesTab.recent
                    ? Icons.history
                    : Icons.notifications_none,
                size: 40,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 8),
              Text(
                view.searchController.text.isNotEmpty
                    ? 'No matching updates found'.tl
                    : view.tab == FollowUpdatesTab.recent
                    ? 'No recent updates found'.tl
                    : 'No updates found'.tl,
                style: ts.s16,
              ),
            ],
          ),
        ),
      );

  Future<void> _openFromList(Comic comic, int? heroID) async {
    try {
      await judgmentService.clearVisibleFlag(comic.sourceKey, comic.id);
    } catch (_) {}
    if (!mounted) return;
    _view(FollowUpdatesTab.unread).needsRefresh = true;
    if (_activeTab == FollowUpdatesTab.unread) {
      await _reloadTab(FollowUpdatesTab.unread);
    }
    updateFollowUpdatesUI(refreshPage: false);
    if (!mounted) return;
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

  void markAllAsRead() {
    if (_activeTab != FollowUpdatesTab.unread ||
        _activeView.searchController.text.isNotEmpty ||
        _markingAllAsRead) {
      return;
    }
    showConfirmDialog(
      context: App.rootContext,
      title: 'Mark all as read'.tl,
      content: 'Do you want to mark all as read?'.tl,
      onConfirm: () {
        unawaited(_markAllAsReadNow());
      },
    );
  }

  Future<void> _markAllAsReadNow() async {
    if (_markingAllAsRead) return;
    setState(() => _markingAllAsRead = true);
    final scopeGeneration = _scopeGeneration;
    final scopeAtStart = _currentAllowedSourceKeys();
    try {
      final identities = await followUpdatesQueryService
          .readVisibleUnreadIdentities(allowedSourceKeys: scopeAtStart);
      if (!mounted ||
          scopeGeneration != _scopeGeneration ||
          !setEquals(scopeAtStart, _currentAllowedSourceKeys())) {
        return;
      }
      for (final identity in identities) {
        if (!mounted ||
            scopeGeneration != _scopeGeneration ||
            !setEquals(scopeAtStart, _currentAllowedSourceKeys())) {
          return;
        }
        await judgmentService.clearVisibleFlag(
          identity.sourceKey,
          identity.comicId,
        );
      }
      if (!mounted ||
          scopeGeneration != _scopeGeneration ||
          !setEquals(scopeAtStart, _currentAllowedSourceKeys())) {
        return;
      }
      await _reloadTab(FollowUpdatesTab.unread);
      updateFollowUpdatesUI(refreshPage: false);
    } catch (_) {
      if (mounted) context.showMessage(message: 'Failed'.tl);
    } finally {
      if (mounted) setState(() => _markingAllAsRead = false);
    }
  }

  void enable() {
    appdata.settings['followUpdatesEnabled'] = true;
    appdata.saveData();
    setState(() {});
    updateFollowUpdatesUI(refreshPage: false);
    unawaited(followUpdateCoordinator.onProcessStart());
  }

  void disable() {
    followUpdateCoordinator.cancel();
    appdata.settings['followUpdatesEnabled'] = false;
    appdata.settings['followUpdatesFolder'] = null;
    appdata.saveData();
    setState(() {
      for (final view in _views.values) {
        view
          ..requestId = view.requestId + 1
          ..comics.clear()
          ..loading = false
          ..loadError = false
          ..hasLoaded = false
          ..earliestAutoHotUntil = null;
      }
    });
    updateFollowUpdatesUI(refreshPage: false);
  }

  void startRefresh() {
    if (!_enabled) return;
    unawaited(followUpdateCoordinator.runRound(FollowUpdateTrigger.manual));
  }

  void startFullCache() {
    final coordinator = followUpdateCoordinator;
    if (coordinator.startFullFavoriteCache()) {
      context.showMessage(message: 'Caching favorites'.tl);
    } else {
      context.showMessage(message: 'A check is already in progress'.tl);
    }
  }

  void showBaselineProgress() {
    if (!_enabled) return;
    final progress = followUpdateCoordinator.currentProgress;
    if (!followUpdateCoordinator.isRunning) {
      context.showMessage(message: 'No check is running'.tl);
      return;
    }
    context.showMessage(message: followUpdateProgressLabel(progress));
  }

  @override
  Object? get key => 'FollowUpdatesPage';
}

class _PinnedTabBarDelegate extends SliverPersistentHeaderDelegate {
  const _PinnedTabBarDelegate({required this.controller, required this.tabs});

  final TabController controller;
  final List<Tab> tabs;

  static const double _height = 48;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: TabBar(controller: controller, tabs: tabs),
  );

  @override
  bool shouldRebuild(covariant _PinnedTabBarDelegate oldDelegate) => true;
}

class _FollowUpdatesTabView {
  _FollowUpdatesTabView({required this.tab});

  final FollowUpdatesTab tab;
  final TextEditingController searchController = TextEditingController();
  final ScrollController scrollController = ScrollController();
  List<FavoriteItem> comics = [];
  FollowUpdatesCursor? nextCursor;
  Timer? searchDebounce;
  int requestId = 0;
  double scrollOffset = 0;
  DateTime? earliestAutoHotUntil;
  bool loading = true;
  bool loadingMore = false;
  bool loadError = false;
  bool moreError = false;
  bool hasLoaded = false;
  bool needsRefresh = false;
  bool loadMoreScheduled = false;
}

String followUpdateProgressLabel(FollowUpdateProgress progress) =>
    progress.discovered > 0 || progress.isComplete
    ? '@done/@total tasks'.tlParams({
        'done': progress.finished,
        'total': progress.discovered,
      })
    : 'Finding what to check'.tl;

void updateFollowUpdatesUI({bool refreshPage = true}) {
  GlobalState.findOrNull<_FollowUpdatesWidgetState>()?.updateCount();
  final page = GlobalState.findOrNull<FollowUpdatesPageState>();
  if (refreshPage && page != null) unawaited(page.updateComics());
}
