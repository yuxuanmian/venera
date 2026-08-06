import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/global_state.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/translations.dart';

class FollowUpdatesWidget extends StatefulWidget {
  const FollowUpdatesWidget({super.key});

  @override
  State<FollowUpdatesWidget> createState() => _FollowUpdatesWidgetState();
}

class _FollowUpdatesWidgetState
    extends AutomaticGlobalState<FollowUpdatesWidget> {
  int _count = 0;

  bool get _enabled => followUpdatesEnabled;

  void getCount() {
    if (!_enabled) {
      _count = 0;
      return;
    }
    _count = NetworkFavoriteCacheManager().countUpdatesInFolders(
      getFollowUpdateFolders(),
    );
  }

  void updateCount() => setState(getCount);

  @override
  void initState() {
    super.initState();
    getCount();
  }

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
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
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 2,
                  ),
                  margin: const EdgeInsets.only(bottom: 16, left: 16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  ),
                  child: Text('Follow updates disabled'.tl, style: ts.s16),
                ),
              if (_enabled && _count > 0) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 2,
                  ),
                  margin: const EdgeInsets.only(bottom: 16, left: 16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: Theme.of(context).colorScheme.primaryContainer,
                  ),
                  child: Row(
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
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Object? get key => 'FollowUpdatesWidget';
}

class FollowUpdatesPage extends StatefulWidget {
  const FollowUpdatesPage({super.key});

  @override
  State<FollowUpdatesPage> createState() => _FollowUpdatesPageState();
}

class _FollowUpdatesPageState extends AutomaticGlobalState<FollowUpdatesPage> {
  List<FavoriteItemWithUpdateInfo> updatedComics = [];
  List<FavoriteItemWithUpdateInfo> allComics = [];
  int _allComicsPage = 0;
  int _allComicsTotal = 0;
  int _allComicsRequestId = 0;
  bool _allComicsHasMore = false;
  bool _allComicsLoading = false;
  bool _allComicsExpanded = false;
  bool _allComicsLoadedOnce = false;
  List<FavoriteItemWithUpdateInfo> suspectComics = [];
  bool _suspectComicsExpanded = true;

  bool get _enabled => followUpdatesEnabled;

  bool get _baselineIncomplete {
    if (!_enabled) return false;
    return NetworkFavoriteCacheManager().countUncheckedComicsInFolders(
          getFollowUpdateFolders(),
        ) >
        0;
  }

  @override
  void initState() {
    super.initState();
    updateComics();
  }

  @override
  Widget build(BuildContext context) {
    final baselineIncomplete = _baselineIncomplete;
    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(
            title: Text('Follow Updates'.tl),
            actions: [
              if (_enabled && baselineIncomplete)
                IconButton(
                  tooltip: 'Baseline progress'.tl,
                  onPressed: showBaselineProgress,
                  icon: ValueListenableBuilder<BaselineStatus?>(
                    valueListenable: FollowUpdatesService.baselineStatus,
                    builder: (context, status, _) {
                      final running = status?.isRunning == true;
                      return running
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sync_problem);
                    },
                  ),
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
            if (baselineIncomplete) buildBaselineInProgress(context),
            const SliverPadding(padding: EdgeInsets.only(top: 8)),
            buildUpdatedComics(),
            buildSuspectComics(),
            buildAllComics(),
          ],
        ],
      ),
    );
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

  Widget buildBaselineInProgress(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: const Icon(Icons.sync),
              title: Text('Baseline in progress'.tl),
            ),
            ValueListenableBuilder<BaselineStatus?>(
              valueListenable: FollowUpdatesService.baselineStatus,
              builder: (context, status, _) {
                final cache = NetworkFavoriteCacheManager();
                final folders = getFollowUpdateFolders();
                // While a scan runs, show the queue's own numbers (final total
                // from the first frame, monotonic completion); when idle, fall
                // back to the database gap counts.
                final running = status?.isRunning == true;
                final total = running
                    ? (status?.total ?? 0)
                    : cache.countCachedComicsInFolders(folders);
                final completed = running
                    ? (status?.completed ?? 0)
                    : total - cache.countUncheckedComicsInFolders(folders);
                final incomplete = !running && total > completed;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: LinearProgressIndicator(
                        value: total == 0 ? null : completed / total,
                      ),
                    ),
                    Text(
                      '@completed / @total checked'.tlParams({
                        'completed': completed,
                        'total': total,
                      }),
                      style: ts.s14,
                    ).paddingHorizontal(16).paddingTop(8),
                    if (status != null && status.currentComic != null)
                      Text(
                        'Checking: @title'.tlParams({
                          'title': status.currentComic!,
                        }),
                        style: ts.s12,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ).paddingHorizontal(16).paddingTop(4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            running
                                ? 'Baseline runs in the background'.tl
                                : status != null && status.errors > 0
                                ? '@count failed, will retry later'.tlParams({
                                    'count': status.errors,
                                  })
                                : 'Baseline incomplete, waiting for next check'
                                      .tl,
                            style: ts.s12,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (incomplete)
                          FilledButton.tonal(
                            onPressed: FollowUpdatesService.startBaseline,
                            child: Text('Retry'.tl),
                          ),
                      ],
                    ).paddingHorizontal(16).paddingVertical(8),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget buildUpdatedComics() => SliverMainAxisGroup(
    slivers: [
      SliverToBoxAdapter(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
                width: 0.6,
              ),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.update),
              const SizedBox(width: 8),
              Text('Updates'.tl, style: ts.s18),
              const Spacer(),
              ValueListenableBuilder<bool>(
                valueListenable: FollowUpdatesService.taskRunning,
                builder: (context, running, _) {
                  return IconButton(
                    tooltip: 'Check Now'.tl,
                    onPressed: running ? null : startRefresh,
                    icon: running
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                  );
                },
              ),
              if (updatedComics.isNotEmpty)
                IconButton(
                  tooltip: 'Mark all as read'.tl,
                  icon: const Icon(Icons.clear_all),
                  onPressed: markAllAsRead,
                ),
            ],
          ),
        ),
      ),
      if (updatedComics.isNotEmpty)
        SliverToBoxAdapter(
          child: Text(
            'Updates are marked read when you start reading.'.tl,
          ).paddingHorizontal(16).paddingVertical(4),
        ),
      if (updatedComics.isNotEmpty)
        SliverGridComics(comics: updatedComics)
      else
        SliverToBoxAdapter(
          child: SizedBox(
            height: math.max(240, MediaQuery.sizeOf(context).height * 0.5),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.notifications_none,
                    size: 40,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(height: 8),
                  Text('No updates found'.tl, style: ts.s16),
                ],
              ),
            ),
          ),
        ),
    ],
  );

  void markAllAsRead() {
    showConfirmDialog(
      context: App.rootContext,
      title: 'Mark all as read'.tl,
      content: 'Do you want to mark all as read?'.tl,
      onConfirm: () {
        final cache = NetworkFavoriteCacheManager();
        for (final comic in updatedComics) {
          cache.markReadInAllFolders(comic.sourceKey, comic.id);
        }
        updateFollowUpdatesUI();
      },
    );
  }

  Widget buildSuspectComics() => SliverMainAxisGroup(
    slivers: [
      SliverToBoxAdapter(
        child: InkWell(
          onTap: () =>
              setState(() => _suspectComicsExpanded = !_suspectComicsExpanded),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline),
                const SizedBox(width: 8),
                Text('Suspected removed'.tl, style: ts.s18),
                if (suspectComics.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text('${suspectComics.length}', style: ts.s14),
                ],
                const Spacer(),
                AnimatedRotation(
                  turns: _suspectComicsExpanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.expand_more),
                ),
              ],
            ),
          ),
        ),
      ),
      if (_suspectComicsExpanded) ...[
        SliverGridComics(
          comics: suspectComics,
          badgeBuilder: (_) => 'Suspected removed'.tl,
          dimmedBuilder: (_) => true,
        ),
      ],
    ],
  );

  Widget buildAllComics() => SliverMainAxisGroup(
    slivers: [
      SliverToBoxAdapter(
        child: InkWell(
          onTap: _toggleAllComics,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.list),
                const SizedBox(width: 8),
                Text('All Comics'.tl, style: ts.s18),
                const Spacer(),
                AnimatedRotation(
                  turns: _allComicsExpanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.expand_more),
                ),
              ],
            ),
          ),
        ),
      ),
      if (_allComicsExpanded) ...[
        SliverGridComics(
          comics: allComics,
          badgeBuilder: (comic) =>
              comic is FavoriteItemWithUpdateInfo && comic.isSuspectGone
              ? 'Suspected removed'.tl
              : null,
          dimmedBuilder: (comic) =>
              comic is FavoriteItemWithUpdateInfo && comic.isSuspectGone,
          onLastItemBuild: _loadMoreAllComics,
        ),
        if (_allComicsHasMore)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: _allComicsLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        if (_allComicsLoadedOnce && allComics.isEmpty)
          SliverToBoxAdapter(
            child: Text(
              'No cached favorites found'.tl,
            ).paddingHorizontal(16).paddingVertical(8),
          ),
      ],
    ],
  );

  void _toggleAllComics() {
    setState(() => _allComicsExpanded = !_allComicsExpanded);
    if (_allComicsExpanded && !_allComicsLoadedOnce) {
      _loadAllComics();
    }
  }

  void enable() {
    appdata.settings['followUpdatesEnabled'] = true;
    appdata.saveData();
    updateFollowUpdatesUI();
    FollowUpdatesService.startBaseline();
  }

  void disable() {
    FollowUpdatesService.cancelChecking();
    FollowUpdatesService.baselineStatus.value = null;
    appdata.settings['followUpdatesEnabled'] = false;
    appdata.settings['followUpdatesFolder'] = null;
    appdata.saveData();
    updateFollowUpdatesUI();
  }

  void startRefresh() {
    if (!_enabled || FollowUpdatesService.taskRunning.value) return;
    context.showMessage(message: 'Refresh started'.tl);
    unawaited(
      FollowUpdatesService.runCheckNow().then((_) {
        if (mounted) updateFollowUpdatesUI();
      }),
    );
  }

  Future<void> showBaselineProgress() async {
    if (!_enabled) return;
    await showDialog(
      context: App.rootContext,
      builder: (context) => ContentDialog(
        title: 'Baseline progress'.tl,
        content: ValueListenableBuilder<BaselineStatus?>(
          valueListenable: FollowUpdatesService.baselineStatus,
          builder: (context, status, _) {
            final cache = NetworkFavoriteCacheManager();
            final folders = getFollowUpdateFolders();
            // While a scan runs, show the queue's own numbers (final total
            // from the first frame, monotonic completion); when idle, fall
            // back to the database gap counts.
            final running = status?.isRunning == true;
            final total = running
                ? (status?.total ?? 0)
                : cache.countCachedComicsInFolders(folders);
            final completed = running
                ? (status?.completed ?? 0)
                : total - cache.countUncheckedComicsInFolders(folders);
            final incomplete = !running && total > completed;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: total == 0 ? null : completed / total,
                  ),
                  Text(
                    '@completed / @total checked'.tlParams({
                      'completed': completed,
                      'total': total,
                    }),
                    style: ts.s16,
                  ).paddingTop(12),
                  if (status != null && status.currentComic != null)
                    Text(
                      'Checking: @title'.tlParams({
                        'title': status.currentComic!,
                      }),
                      style: ts.s14,
                    ).paddingTop(8),
                  if (status != null && status.errors > 0)
                    Text(
                      '@count failed'.tlParams({'count': status.errors}),
                      style: ts.s14,
                    ).paddingTop(8),
                  Text(
                    running
                        ? 'Baseline runs in the background'.tl
                        : incomplete
                        ? 'Baseline incomplete, waiting for next check'.tl
                        : 'Baseline complete'.tl,
                    style: ts.s14,
                  ).paddingTop(12),
                ],
              ),
            );
          },
        ),
        actions: [
          ValueListenableBuilder<BaselineStatus?>(
            valueListenable: FollowUpdatesService.baselineStatus,
            builder: (context, status, _) {
              final cache = NetworkFavoriteCacheManager();
              final folders = getFollowUpdateFolders();
              final total = cache.countCachedComicsInFolders(folders);
              final completed =
                  total - cache.countUncheckedComicsInFolders(folders);
              final running = status?.isRunning == true;
              final incomplete = !running && total > completed;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (incomplete)
                    FilledButton.tonal(
                      onPressed: FollowUpdatesService.startBaseline,
                      child: Text('Retry'.tl),
                    ),
                  if (incomplete) const SizedBox(width: 8),
                  FilledButton(onPressed: context.pop, child: Text('Close'.tl)),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  void updateComics() {
    setState(() {
      final cache = NetworkFavoriteCacheManager();
      if (!_enabled) {
        updatedComics = [];
        allComics = [];
        suspectComics = [];
        _allComicsPage = 0;
        _allComicsTotal = 0;
        _allComicsHasMore = false;
        _allComicsLoading = false;
        _allComicsExpanded = false;
        _allComicsLoadedOnce = false;
        _allComicsRequestId++;
        return;
      }
      updatedComics = cache.getUpdatedComicsInFolders(getFollowUpdateFolders());
      suspectComics = cache.getSuspectGoneComicsInFolders(
        getFollowUpdateFolders(),
      );
      allComics = [];
      _allComicsPage = 0;
      _allComicsTotal = 0;
      _allComicsHasMore = false;
      _allComicsLoading = false;
      _allComicsLoadedOnce = false;
      _allComicsRequestId++;
    });
    if (_enabled && _allComicsExpanded) {
      _loadAllComics();
    }
  }

  Future<void> _loadAllComics() async {
    if (!_enabled || !_allComicsExpanded || _allComicsLoading) return;
    if (!_allComicsLoadedOnce) {
      setState(() {
        _allComicsTotal = NetworkFavoriteCacheManager()
            .countComicsWithUpdatesInfoInFolders(getFollowUpdateFolders());
        _allComicsHasMore = _allComicsTotal > 0;
        _allComicsLoadedOnce = true;
      });
      if (!_allComicsHasMore) return;
    } else if (!_allComicsHasMore) {
      return;
    }
    final requestId = _allComicsRequestId;
    setState(() => _allComicsLoading = true);
    final page = NetworkFavoriteCacheManager()
        .getComicsWithUpdatesInfoPageInFolders(
          getFollowUpdateFolders(),
          limit: 50,
          offset: _allComicsPage * 50,
        );
    if (!mounted || requestId != _allComicsRequestId) return;
    setState(() {
      allComics.addAll(page);
      _allComicsPage++;
      _allComicsLoading = false;
      _allComicsHasMore = allComics.length < _allComicsTotal;
    });
  }

  void _loadMoreAllComics() {
    if (!_allComicsLoading && _allComicsHasMore) {
      _loadAllComics();
    }
  }

  @override
  Object? get key => 'FollowUpdatesPage';
}

/// Background service for checking cached remote favorites.
abstract class FollowUpdatesService {
  static bool _isInitialized = false;
  static bool _taskRunning = false;
  static Future<void>? _activeTask;
  static void Function()? _cancelCurrent;
  static Timer? _autoScanTimer;

  /// Latest progress of the background baseline run, or null when no baseline
  /// task is active.
  static final ValueNotifier<BaselineStatus?> baselineStatus =
      ValueNotifier<BaselineStatus?>(null);

  static final ValueNotifier<bool> taskRunning = ValueNotifier<bool>(false);

  static void cancelChecking() => _cancelCurrent?.call();

  static Future<void> _startTask(
    Future<void> Function(bool Function() isCanceled) task, {
    required bool cancelExisting,
  }) async {
    if (_taskRunning) {
      if (!cancelExisting) return;
      _cancelCurrent?.call();
      await _activeTask;
    }
    var cancelRequested = false;
    _taskRunning = true;
    taskRunning.value = true;
    final current = task(() => cancelRequested);
    _activeTask = current;
    _cancelCurrent = () => cancelRequested = true;
    try {
      await current;
    } catch (e, s) {
      Log.error('Follow updates task', e, s);
    } finally {
      if (identical(_activeTask, current)) {
        _activeTask = null;
        _taskRunning = false;
        taskRunning.value = false;
        _cancelCurrent = null;
      }
      // The cache may have changed while this task was running (for example a
      // sync batch or folder refresh), so re-check for remaining gaps once the
      // task has fully finished instead of waiting for a manual Retry.
      _scheduleAutoScan();
    }
  }

  /// Debounces a background missing-only scan after cache changes.
  ///
  /// The scan only fills check gaps and never overrides the regular periodic
  /// check or manual checks. It is skipped while another task is running or a
  /// full-cache operation is in progress; in the latter case it retries after
  /// a short delay so freshly cached folders get scanned right after.
  static void _scheduleAutoScan() {
    _autoScanTimer?.cancel();
    _autoScanTimer = Timer(const Duration(seconds: 2), _tryStartAutoScan);
  }

  static void _tryStartAutoScan() {
    if (!followUpdatesEnabled) return;
    if (_taskRunning) {
      // A scan is still consuming. Re-check shortly after it ends so cache
      // changes that arrived mid-run are picked up even if the task itself
      // did not schedule the follow-up.
      _autoScanTimer = Timer(const Duration(seconds: 5), _tryStartAutoScan);
      return;
    }
    final cache = NetworkFavoriteCacheManager();
    final folders = getFollowUpdateFolders();
    if (folders.any(cache.isFullCacheRunning)) {
      _autoScanTimer = Timer(const Duration(seconds: 5), _tryStartAutoScan);
      return;
    }
    if (cache.countPendingUncheckedComicsInFolders(folders) == 0) return;
    unawaited(_startTask(_runMissingOnly, cancelExisting: false));
  }

  static void startBaseline() {
    unawaited(
      _startTask(
        (isCanceled) => _runBaseline(isCanceled),
        cancelExisting: true,
      ),
    );
  }

  static Future<void> runCheckNow() {
    return _startTask((isCanceled) async {
      // Consume the stream to its end even when cancelled so the underlying
      // scan fully shuts down before this task is considered finished.
      await for (final _ in scanFollowUpdates(
        getFollowUpdateFolders(),
        FollowUpdateMode.regular,
        isCanceled: isCanceled,
        ignoreRetryAfter: true,
      )) {
        // Cancellation is handled inside the scan; keep draining.
      }
    }, cancelExisting: true);
  }

  /// Debug-only: force every cached comic into the queue, ignoring cooldowns,
  /// the 24h window and the suspected-removed skip.
  static Future<void> forceScanAll() {
    return _startTask((isCanceled) async {
      await for (final _ in scanFollowUpdates(
        getFollowUpdateFolders(),
        FollowUpdateMode.force,
        isCanceled: isCanceled,
        ignoreRetryAfter: true,
        includeSuspect: true,
      )) {
        // Cancellation is handled inside the scan; keep draining.
      }
    }, cancelExisting: true);
  }

  static Future<void> _runBaseline(bool Function() isCanceled) async {
    final folders = getFollowUpdateFolders();
    final cache = NetworkFavoriteCacheManager();
    var total = cache.countCachedComicsInFolders(folders);
    var completed = total - cache.countUncheckedComicsInFolders(folders);
    var errors = 0;
    var updated = 0;
    Log.info(
      'Follow updates',
      'Start baseline: ${folders.length} folders, '
          '${total - completed} unchecked',
    );
    baselineStatus.value = BaselineStatus(
      isRunning: true,
      total: total,
      completed: completed,
      errors: 0,
      updated: 0,
    );
    try {
      // Consume the stream to its end even when cancelled; the scan's internal
      // checks stop it from picking up new work, so this drains quickly and no
      // background scan outlives this task.
      await for (final progress in scanFollowUpdates(
        folders,
        FollowUpdateMode.missing,
        isCanceled: isCanceled,
        ignoreRetryAfter: true,
      )) {
        errors = progress.errors;
        updated = progress.updated;
        if (!isCanceled()) {
          baselineStatus.value = BaselineStatus(
            isRunning: true,
            total: progress.total,
            completed: progress.current,
            errors: errors,
            updated: updated,
            currentComic: progress.comic?.title,
          );
        }
      }
      if (isCanceled()) {
        Log.info('Follow updates', 'Baseline canceled');
        baselineStatus.value = null;
        return;
      }
      final remaining = cache.countUncheckedComicsInFolders(
        getFollowUpdateFolders(),
      );
      if (remaining > 0) {
        final last = baselineStatus.value;
        baselineStatus.value = BaselineStatus(
          isRunning: false,
          total: last?.total ?? total,
          completed: last?.completed ?? completed,
          errors: last?.errors ?? errors,
          updated: last?.updated ?? updated,
        );
        Log.warning(
          'Follow updates',
          'Baseline incomplete: $remaining unchecked, '
              '${baselineStatus.value?.errors} errors',
        );
      } else {
        baselineStatus.value = null;
        Log.info('Follow updates', 'Baseline complete');
      }
    } catch (e, s) {
      Log.error('Follow updates baseline', e, s);
      final last = baselineStatus.value;
      baselineStatus.value = BaselineStatus(
        isRunning: false,
        total: last?.total ?? total,
        completed: last?.completed ?? completed,
        errors: last?.errors ?? errors,
        updated: last?.updated ?? updated,
      );
    } finally {
      updateFollowUpdatesUI();
    }
  }

  /// Fills only the check gaps that are neither checked nor in cooldown.
  ///
  /// Runs after cache changes (new sync batches, folder refresh, full-cache
  /// completion). Cooldowns are respected; manual Retry / Check Now keep their
  /// force-check semantics.
  static Future<void> _runMissingOnly(bool Function() isCanceled) async {
    final folders = getFollowUpdateFolders();
    final cache = NetworkFavoriteCacheManager();
    var errors = 0;
    var updated = 0;
    try {
      if (isCanceled() ||
          cache.countPendingUncheckedComicsInFolders(folders) == 0) {
        return;
      }
      baselineStatus.value = BaselineStatus(
        isRunning: true,
        total: cache.countCachedComicsInFolders(folders),
        completed:
            cache.countCachedComicsInFolders(folders) -
            cache.countUncheckedComicsInFolders(folders),
        errors: errors,
        updated: updated,
      );
      // Consume the stream to its end even when cancelled so the underlying
      // scan fully shuts down before this task is considered finished.
      await for (final progress in scanFollowUpdates(
        folders,
        FollowUpdateMode.missing,
        isCanceled: isCanceled,
        ignoreRetryAfter: false,
      )) {
        errors = progress.errors;
        updated = progress.updated;
        if (!isCanceled() && progress.total > 0) {
          baselineStatus.value = BaselineStatus(
            isRunning: true,
            total: progress.total,
            completed: progress.current,
            errors: errors,
            updated: updated,
            currentComic: progress.comic?.title,
          );
        }
      }
      if (isCanceled()) {
        baselineStatus.value = null;
        return;
      }
      if (cache.countPendingUncheckedComicsInFolders(folders) == 0) {
        baselineStatus.value = null;
      }
    } catch (e, s) {
      Log.error('Follow updates auto scan', e, s);
      final last = baselineStatus.value;
      baselineStatus.value = BaselineStatus(
        isRunning: false,
        total: last?.total ?? 0,
        completed: last?.completed ?? 0,
        errors: last?.errors ?? errors,
        updated: last?.updated ?? updated,
      );
    } finally {
      updateFollowUpdatesUI();
    }
  }

  static Future<void> _check(bool Function() isCanceled) async {
    if (!followUpdatesEnabled) return;
    var updated = 0;
    try {
      final enabled = appdata.settings['favorites'];
      if (enabled is List) {
        for (final key in enabled.whereType<String>()) {
          if (isCanceled()) return;
          final source = ComicSource.find(key);
          final data = source?.favoriteData;
          if (data == null || !source!.isLogged) continue;
          try {
            await NetworkFavoriteCacheManager()
                .refreshCachedSummaries(data)
                .timeout(const Duration(seconds: 30));
          } catch (e, s) {
            Log.error('Refresh favorite cache', e, s);
          }
        }
      }

      // Consume the stream to its end even when cancelled so the scan fully
      // shuts down before this task is considered finished. Regular mode is a
      // superset of missing: never-checked comics are always included, and
      // recently checked ones are skipped by the 24h filter.
      await for (final progress in scanFollowUpdates(
        getFollowUpdateFolders(),
        FollowUpdateMode.regular,
        isCanceled: isCanceled,
      )) {
        updated += progress.updated;
      }
    } finally {
      if (updated > 0) updateFollowUpdatesUI();
    }
  }

  static void initChecker() {
    if (_isInitialized) return;
    _isInitialized = true;
    if (appdata.settings['followUpdatesFolder'] != null &&
        appdata.settings['followUpdatesEnabled'] != true) {
      appdata.settings['followUpdatesEnabled'] = true;
      appdata.settings['followUpdatesFolder'] = null;
      appdata.saveData();
    }
    unawaited(_startTask(_check, cancelExisting: false));
    NetworkFavoriteCacheManager().addListener(_onCacheChanged);
    Timer.periodic(
      const Duration(minutes: 10),
      (_) => unawaited(_startTask(_check, cancelExisting: false)),
    );
  }

  static void _onCacheChanged() {
    updateFollowUpdatesUI();
    _scheduleAutoScan();
  }
}

void updateFollowUpdatesUI() {
  GlobalState.findOrNull<_FollowUpdatesWidgetState>()?.updateCount();
  GlobalState.findOrNull<_FollowUpdatesPageState>()?.updateComics();
}
