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
import 'package:venera/foundation/tracking/runtime_generation.dart';
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
    return hasPendingFollowUpdateWork(
      mode: FollowUpdateMode.missing,
      folders: getFollowUpdateFolders(),
    );
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
              ValueListenableBuilder<bool>(
                valueListenable: FollowUpdatesService.taskRunning,
                builder: (context, running, _) {
                  final show = _enabled && (running || baselineIncomplete);
                  return show
                      ? IconButton(
                          tooltip: 'Update check progress'.tl,
                          onPressed: showBaselineProgress,
                          icon: ValueListenableBuilder<BaselineStatus?>(
                            valueListenable:
                                FollowUpdatesService.baselineStatus,
                            builder: (context, status, _) {
                              final runningNow =
                                  status?.isRunning == true ||
                                  (status == null &&
                                      FollowUpdatesService.taskRunning.value);
                              return runningNow
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.sync_problem);
                            },
                          ),
                        )
                      : const SizedBox.shrink();
                },
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
            ValueListenableBuilder<bool>(
              valueListenable: FollowUpdatesService.taskRunning,
              builder: (context, running, _) => running || baselineIncomplete
                  ? buildBaselineInProgress(context)
                  : const SliverToBoxAdapter(child: SizedBox.shrink()),
            ),
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
              title: Text('Checking updates'.tl),
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
                // A task is active but has not published its queue yet (folder
                // summaries still refreshing, queue being built). Database gap
                // counts are meaningless in that window: a fully checked cache
                // would render a false 100% and then jump backwards when the
                // scan's real queue numbers arrive. Show an indeterminate
                // state instead.
                final starting =
                    status == null && FollowUpdatesService.taskRunning.value;
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
                        value: starting || total == 0
                            ? null
                            : completed / total,
                      ),
                    ),
                    if (!starting)
                      Text(
                        (status?.containsBatchWork == true
                                ? '@completed / @total scan tasks'
                                : '@completed / @total checked')
                            .tlParams({'completed': completed, 'total': total}),
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
                    if (status != null && status.isBatchWork)
                      Text(
                        'Scanning list: @title'.tlParams({
                          'title': status.currentLabel ?? '-',
                        }),
                        style: ts.s12,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ).paddingHorizontal(16).paddingTop(4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            starting || running
                                ? 'Follow-up scan in progress'.tl
                                : status != null && status.errors > 0
                                ? '@count failed, will retry later'.tlParams({
                                    'count': status.errors,
                                  })
                                : 'Some comics not checked, waiting for next scan'
                                      .tl,
                            style: ts.s12,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (incomplete && !starting)
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
        title: 'Update check progress'.tl,
        content: ValueListenableBuilder<BaselineStatus?>(
          valueListenable: FollowUpdatesService.baselineStatus,
          builder: (context, status, _) {
            final cache = NetworkFavoriteCacheManager();
            final folders = getFollowUpdateFolders();
            // While a scan runs, show the queue's own numbers (final total
            // from the first frame, monotonic completion); when idle, fall
            // back to the database gap counts.
            final running = status?.isRunning == true;
            // A task is active but has not published its queue yet (folder
            // summaries still refreshing, queue being built). Database gap
            // counts are meaningless in that window: a fully checked cache
            // would render a false 100% and then jump backwards when the
            // scan's real queue numbers arrive. Show an indeterminate
            // state instead.
            final starting =
                status == null && FollowUpdatesService.taskRunning.value;
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
                    value: starting || total == 0 ? null : completed / total,
                  ),
                  if (!starting)
                    Text(
                      (status?.containsBatchWork == true
                              ? '@completed / @total scan tasks'
                              : '@completed / @total checked')
                          .tlParams({'completed': completed, 'total': total}),
                      style: ts.s16,
                    ).paddingTop(12),
                  if (status != null && status.currentComic != null)
                    Text(
                      'Checking: @title'.tlParams({
                        'title': status.currentComic!,
                      }),
                      style: ts.s14,
                    ).paddingTop(8),
                  if (status != null && status.isBatchWork)
                    Text(
                      'Scanning list: @title'.tlParams({
                        'title': status.currentLabel ?? '-',
                      }),
                      style: ts.s14,
                    ).paddingTop(8),
                  if (status != null && status.errors > 0)
                    Text(
                      '@count failed'.tlParams({'count': status.errors}),
                      style: ts.s14,
                    ).paddingTop(8),
                  Text(
                    starting || running
                        ? 'Follow-up scan in progress'.tl
                        : incomplete
                        ? 'Some comics not checked, waiting for next scan'.tl
                        : 'All checks complete'.tl,
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
              final starting =
                  status == null && FollowUpdatesService.taskRunning.value;
              final incomplete = !starting && !running && total > completed;
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

class _FollowUpdatesTaskToken implements ScanCancellationToken {
  _FollowUpdatesTaskToken(this.generation, this._isCurrent);

  final int generation;
  final bool Function() _isCurrent;
  bool _canceled = false;

  void cancel() => _canceled = true;

  @override
  bool get isCanceled => _canceled;

  @override
  bool get isCurrent => _isCurrent();

  @override
  bool get canCommit => !isCanceled && isCurrent;
}

/// Background service for checking cached remote favorites.
abstract class FollowUpdatesService {
  static bool _isInitialized = false;
  static bool _taskRunning = false;
  static Future<void>? _activeTask;
  static _FollowUpdatesTaskToken? _activeToken;
  static int _generation = 0;
  static void Function()? _cancelCurrent;
  static Timer? _autoScanTimer;
  static Timer? _checkTimer;
  static Timer? _summaryTimer;
  static Timer? _resumeTimer;
  static bool _cacheListenerAttached = false;
  static DateTime? _lastScanCompletedAt;
  static bool _resumeCheckPending = false;
  static bool _resumeCheckAfterTask = false;
  static const _resumeDebounce = Duration(seconds: 2);
  static const _resumeStaleAfter = Duration(minutes: 10);

  static List<NetworkFavoriteFolderRef> _effectiveLocalFolders(
    List<NetworkFavoriteFolderRef> folders,
  ) {
    if (!App.isInitialized) return folders;
    return App.cloudTracking.localFolders(folders);
  }

  static RuntimeGenerationController? get _generationController =>
      App.isInitialized ? App.cloudTracking.generations : null;

  static ScanCancellationToken _sourceToken(
    ScanCancellationToken base,
    String sourceKey,
  ) {
    final controller = _generationController;
    if (controller == null) return base;
    return generationScanTokenForSource(sourceKey, controller, base: base);
  }

  /// Latest progress of the background baseline run, or null when no baseline
  /// task is active.
  static final ValueNotifier<BaselineStatus?> baselineStatus =
      ValueNotifier<BaselineStatus?>(null);

  static final ValueNotifier<bool> taskRunning = ValueNotifier<bool>(false);

  static void cancelChecking() => _cancelCurrent?.call();

  /// Debug-only: pick 5-10 random cached comics (any state) and refresh their
  /// check state with a live detail request, ignoring windows and cooldowns.
  /// Runs inside the task queue so the progress card and the appbar indicator
  /// light up like any other scan.
  static Future<void> refreshRandomComics() {
    return _startTask(
      (token) async {
        final cache = NetworkFavoriteCacheManager();
        final folders = _effectiveLocalFolders(getFollowUpdateFolders());
        final listFolders = <NetworkFavoriteFolderRef>[];
        final listSources = <String>{};
        final comics =
            <({String sourceKey, String comicId, String folderId})>[];
        final seen = <String>{};
        for (final folder in folders) {
          final source = ComicSource.find(folder.sourceKey);
          final updateCheck = source?.favoriteData?.updateCheck;
          if (updateCheck != null) {
            if (listSources.add(folder.sourceKey)) listFolders.add(folder);
            continue;
          }
          for (final comic in cache.getComicsWithUpdatesInfo(folder)) {
            final key = '${comic.sourceKey}\u0000${comic.id}';
            if (seen.add(key)) {
              comics.add((
                sourceKey: comic.sourceKey,
                comicId: comic.id,
                folderId: folder.folderId,
              ));
            }
          }
        }
        if (comics.isEmpty && listFolders.isEmpty) return;
        final random = math.Random();
        final count = math.min(5 + random.nextInt(6), comics.length);
        comics.shuffle(random);
        var updated = 0;
        var errors = 0;
        var completed = 0;
        final total = count + listFolders.length;
        if (!token.canCommit) return;
        baselineStatus.value = BaselineStatus(
          isRunning: true,
          total: total,
          completed: 0,
          errors: 0,
          updated: 0,
          containsBatchWork: listFolders.isNotEmpty,
        );
        final expectedEpochs = <String, int>{
          for (final folder in listFolders)
            folder.sourceKey: cache.captureFavoriteSessionEpoch(
              folder.sourceKey,
            ),
        };
        for (final folder in listFolders) {
          final folderToken = _sourceToken(token, folder.sourceKey);
          if (!folderToken.canCommit) return;
          if (!cache.tryAcquireFullCacheLock(folder)) {
            completed++;
            if (folderToken.canCommit) {
              baselineStatus.value = BaselineStatus(
                isRunning: true,
                total: total,
                completed: completed,
                errors: errors,
                updated: updated,
                isBatchWork: true,
                currentLabel: '${folder.sourceKey}/${folder.folderId}',
                containsBatchWork: true,
              );
            }
            continue;
          }
          final source = ComicSource.find(folder.sourceKey);
          final data = source?.favoriteData;
          final updateCheck = data?.updateCheck;
          final expectedEpoch = expectedEpochs[folder.sourceKey]!;
          try {
            if (data == null || updateCheck == null) {
              errors++;
            } else {
              cache.recordFavoriteUpdateScanAttempt(folder);
              final result = await updateCheck.load(folder.folderId);
              if (!folderToken.canCommit) return;
              if (cache.isFavoriteSessionEpochCurrent(
                folder.sourceKey,
                expectedEpoch,
              )) {
                if (result.error) {
                  cache.recordFavoriteUpdateScanFailure(folder);
                  errors++;
                } else if (cache.isFavoriteSessionEpochCurrent(
                      folder.sourceKey,
                      expectedEpoch,
                    ) &&
                    folderToken.canCommit) {
                  final applied = cache.applyCompleteFavoriteUpdateSnapshot(
                    data,
                    folder,
                    result.data,
                    completedAt: DateTime.now(),
                  );
                  updated += applied.updatedComicCount;
                } else {
                  // The account changed between the response and commit.
                }
              }
            }
          } catch (e, s) {
            if (!folderToken.canCommit) return;
            if (cache.isFavoriteSessionEpochCurrent(
              folder.sourceKey,
              expectedEpoch,
            )) {
              Log.error('Follow updates random list refresh', e, s);
              cache.recordFavoriteUpdateScanFailure(folder);
              errors++;
            } else {
              // Session invalidation is a neutral skip; do not back off.
            }
          } finally {
            cache.releaseFullCacheLock(folder);
          }
          completed++;
          if (folderToken.canCommit) {
            baselineStatus.value = BaselineStatus(
              isRunning: true,
              total: total,
              completed: completed,
              errors: errors,
              updated: updated,
              isBatchWork: true,
              currentLabel: '${folder.sourceKey}/${folder.folderId}',
              containsBatchWork: true,
            );
          }
        }
        for (final item in comics.take(count)) {
          final itemToken = _sourceToken(token, item.sourceKey);
          if (!itemToken.canCommit) return;
          final fresh = cache.getComicUpdateInfo(
            item.sourceKey,
            item.comicId,
            item.folderId,
          );
          if (fresh != null) {
            final result = await updateComic(
              fresh,
              NetworkFavoriteFolderRef(
                sourceKey: item.sourceKey,
                folderId: item.folderId,
              ),
              cache: cache,
              cancellationToken: itemToken,
            );
            if (!itemToken.canCommit) return;
            if (result.errorMessage != null) {
              errors++;
            } else {
              updated++;
            }
          }
          completed++;
          if (itemToken.canCommit) {
            baselineStatus.value = BaselineStatus(
              isRunning: true,
              total: total,
              completed: completed,
              errors: errors,
              updated: updated,
              currentComic: fresh?.title,
              containsBatchWork: listFolders.isNotEmpty,
            );
          }
        }
        if (!token.canCommit) return;
        baselineStatus.value = null;
        Log.info(
          'Follow updates',
          'Random refresh: $updated ok, $errors failed',
        );
      },
      cancelExisting: true,
      waitForCancelled: false,
    );
  }

  static Future<void> _startTask(
    Future<void> Function(ScanCancellationToken token) task, {
    required bool cancelExisting,
    bool waitForCancelled = true,
  }) async {
    if (_taskRunning) {
      if (!cancelExisting) return;
      _cancelCurrent?.call();
      // The cancelled task may be stuck inside a detail request that only
      // finishes later; only wait when the caller needs strict serialization.
      if (waitForCancelled) await _activeTask;
    }
    late final _FollowUpdatesTaskToken token;
    token = _FollowUpdatesTaskToken(
      ++_generation,
      () => identical(_activeToken, token),
    );
    _activeToken = token;
    _taskRunning = true;
    taskRunning.value = true;
    final current = task(token);
    _activeTask = current;
    // Clearing the status here (instead of inside the cancelled task) keeps a
    // replacement task's fresh status from being wiped by a late frame of the
    // cancelled one.
    _cancelCurrent = () {
      token.cancel();
      baselineStatus.value = null;
    };
    var completedSuccessfully = false;
    try {
      await current;
      completedSuccessfully = true;
    } catch (e, s) {
      Log.error('Follow updates task', e, s);
    } finally {
      if (identical(_activeTask, current)) {
        final canRecordCompletion = completedSuccessfully && token.canCommit;
        _activeTask = null;
        _activeToken = null;
        _taskRunning = false;
        taskRunning.value = false;
        _cancelCurrent = null;
        if (canRecordCompletion) _lastScanCompletedAt = DateTime.now();
        // The cache may have changed while this task was running (for example a
        // sync batch or folder refresh), so re-check for remaining gaps once the
        // task has fully finished instead of waiting for a manual Retry.
        if (!_resumeCheckPending) _scheduleAutoScan();
        // With the queue idle again, keep cached list metadata fresh (once per
        // staleness window) without ever delaying the scan itself.
        _maybeRefreshSummaries();
        // Rebuild the page so the baseline card and lists reflect the settled
        // scan state (incomplete gap or fully checked).
        updateFollowUpdatesUI();
        if (_resumeCheckPending) _scheduleResumeCheck();
      }
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
    if (!_isInitialized) return;
    if (!followUpdatesEnabled) return;
    if (_taskRunning) {
      // A scan is still consuming. Re-check shortly after it ends so cache
      // changes that arrived mid-run are picked up even if the task itself
      // did not schedule the follow-up.
      _autoScanTimer = Timer(const Duration(seconds: 5), _tryStartAutoScan);
      return;
    }
    final cache = NetworkFavoriteCacheManager();
    final folders = _effectiveLocalFolders(getFollowUpdateFolders());
    if (folders.any(cache.isFullCacheRunning)) {
      _autoScanTimer = Timer(const Duration(seconds: 5), _tryStartAutoScan);
      return;
    }
    if (!hasPendingFollowUpdateWork(
      mode: FollowUpdateMode.missing,
      folders: folders,
    )) {
      return;
    }
    unawaited(_startTask(_runMissingOnly, cancelExisting: false));
  }

  static void startBaseline() {
    unawaited(
      _startTask(
        (token) => _runScanWithStatus(
          token,
          mode: FollowUpdateMode.missing,
          ignoreRetryAfter: true,
        ),
        cancelExisting: true,
      ),
    );
  }

  static Future<void> runCheckNow() {
    return _startTask(
      (token) => _runScanWithStatus(
        token,
        mode: FollowUpdateMode.regular,
        ignoreRetryAfter: true,
        forceListSnapshots: true,
      ),
      cancelExisting: true,
    );
  }

  /// Debug-only: force every cached comic into the queue, ignoring cooldowns,
  /// the 24h window and the suspected-removed skip.
  static Future<void> forceScanAll() {
    return _startTask(
      (token) => _runScanWithStatus(
        token,
        mode: FollowUpdateMode.force,
        ignoreRetryAfter: true,
        includeSuspect: true,
      ),
      cancelExisting: true,
    );
  }

  /// Runs [scanFollowUpdates] and publishes its progress to [baselineStatus].
  /// The UI stays untouched when the queue is empty (first frame total == 0).
  /// After the run the status settles to null when every comic was attempted,
  /// or to a finished-but-incomplete state when unchecked comics remain.
  static Future<void> _runScanWithStatus(
    ScanCancellationToken token, {
    required FollowUpdateMode mode,
    bool ignoreRetryAfter = false,
    bool includeSuspect = false,
    bool forceListSnapshots = false,
    List<NetworkFavoriteFolderRef>? folders,
  }) async {
    final effectiveFolders = _effectiveLocalFolders(
      folders ?? getFollowUpdateFolders(),
    );
    var errors = 0;
    var updated = 0;
    var plannedTotal = 0;
    var completed = 0;
    try {
      await for (final progress in scanFollowUpdates(
        effectiveFolders,
        mode,
        cancellationToken: token,
        ignoreRetryAfter: ignoreRetryAfter,
        includeSuspect: includeSuspect,
        forceListSnapshots: forceListSnapshots,
        generationController: _generationController,
      )) {
        // Empty queue: no plan, keep any previous UI state untouched.
        if (progress.total == 0) continue;
        plannedTotal = progress.total;
        completed = progress.current;
        errors = progress.errors;
        updated = progress.updated;
        // Cancellation stops publishing; the status is released by
        // [_startTask]'s cancel callback, never by a late frame here (it may
        // belong to a replacement task already).
        if (!token.canCommit) return;
        baselineStatus.value = BaselineStatus(
          isRunning: true,
          total: progress.total,
          completed: progress.current,
          errors: errors,
          updated: updated,
          currentComic: progress.comic?.title,
          isBatchWork: progress.isBatchWork,
          currentLabel: progress.currentLabel,
          containsBatchWork: progress.containsBatchWork,
        );
      }
      if (!token.canCommit) return;
      final remaining = mode == FollowUpdateMode.force
          ? plannedTotal > 0 && completed < plannedTotal
          : hasPendingFollowUpdateWork(mode: mode, folders: effectiveFolders);
      if (remaining) {
        final last = baselineStatus.value;
        baselineStatus.value = BaselineStatus(
          isRunning: false,
          total: last?.total ?? 0,
          completed: last?.completed ?? 0,
          errors: last?.errors ?? errors,
          updated: last?.updated ?? updated,
        );
        Log.warning(
          'Follow updates',
          'Scan incomplete: $remaining unchecked, $errors errors',
        );
      } else {
        baselineStatus.value = null;
      }
    } catch (e, s) {
      Log.error('Follow updates scan', e, s);
      if (!token.isCurrent || token.isCanceled) return;
      final last = baselineStatus.value;
      baselineStatus.value = BaselineStatus(
        isRunning: false,
        total: last?.total ?? 0,
        completed: last?.completed ?? 0,
        errors: last?.errors ?? errors,
        updated: last?.updated ?? updated,
      );
    }
  }

  /// Fills only the check gaps that are neither checked nor in cooldown.
  ///
  /// Runs after cache changes (new sync batches, folder refresh, full-cache
  /// completion). Cooldowns are respected; manual Retry / Check Now keep their
  /// force-check semantics.
  static Future<void> _runMissingOnly(ScanCancellationToken token) async {
    final folders = _effectiveLocalFolders(getFollowUpdateFolders());
    if (!token.canCommit ||
        !hasPendingFollowUpdateWork(
          mode: FollowUpdateMode.missing,
          folders: folders,
        )) {
      return;
    }
    await _runScanWithStatus(token, mode: FollowUpdateMode.missing);
  }

  static Future<void> _check(ScanCancellationToken token) async {
    if (!followUpdatesEnabled) return;
    // While "cache all pages" is running for a folder, its pages churn
    // constantly; the periodic scan must not fight the full-cache worker
    // over the same comics.
    final cache = NetworkFavoriteCacheManager();
    final folders = _effectiveLocalFolders(
      getFollowUpdateFolders(),
    ).where((f) => !cache.isFullCacheRunning(f)).toList();
    await _runScanWithStatus(
      token,
      mode: FollowUpdateMode.regular,
      folders: folders,
    );
  }

  /// Last time a summary-refresh round started, so the refresh can never run
  /// more often than [NetworkFavoriteCacheManager.backgroundSummaryRefreshAfter]
  /// even when scan tasks finish in quick succession.
  static DateTime? _lastSummaryRefreshAt;

  /// Per-source time budget for one summary-refresh round. Generous enough
  /// to make progress on large folders, short enough to never hog the
  /// network for long; the sweep stops at a page boundary and the next round
  /// continues with the stale remainder.
  static const _summaryRefreshBudget = Duration(seconds: 30);

  /// Refreshes cached favorite-list summaries (titles, authors, tags)
  /// outside the scan task queue: a slow source must never delay the update
  /// check or keep the task indicator spinning. Sources run concurrently,
  /// each capped by its own budget. Skipped while a scan task is active so
  /// the refresh never stacks list requests on top of a running scan.
  static Future<void> _refreshSummaries() async {
    if (!followUpdatesEnabled) return;
    final enabled = appdata.settings['favorites'];
    if (enabled is! List) return;
    final cache = NetworkFavoriteCacheManager();
    final sources = <String>[];
    for (final key in enabled.whereType<String>()) {
      if (_taskRunning) return;
      final source = ComicSource.find(key);
      if (source?.favoriteData == null ||
          source!.favoriteData!.updateCheck != null ||
          !source.isLogged) {
        continue;
      }
      sources.add(key);
    }
    await Future.wait([
      for (final key in sources)
        () async {
          if (_taskRunning) return;
          final source = ComicSource.find(key);
          final data = source?.favoriteData;
          if (data == null) return;
          try {
            await cache.refreshCachedSummaries(
              data,
              timeBudget: _summaryRefreshBudget,
            );
          } catch (e, s) {
            Log.error('Refresh favorite cache', e, s);
          }
        }(),
    ]);
  }

  /// Starts one summary-refresh round unless one already started within the
  /// staleness window; the timestamp is claimed up front so a second trigger
  /// while the round is running is a no-op.
  static void _maybeRefreshSummaries() {
    final now = DateTime.now();
    final last = _lastSummaryRefreshAt;
    if (last != null &&
        now.difference(last) <
            NetworkFavoriteCacheManager.backgroundSummaryRefreshAfter) {
      return;
    }
    _lastSummaryRefreshAt = now;
    unawaited(_refreshSummaries());
  }

  static void _scheduleResumeCheck() {
    _resumeTimer?.cancel();
    _resumeTimer = Timer(_resumeDebounce, _tryStartResumeCheck);
  }

  static void _tryStartResumeCheck() {
    _resumeTimer = null;
    if (!_resumeCheckPending) return;
    if (!_isInitialized || !followUpdatesEnabled) {
      _resumeCheckPending = false;
      _resumeCheckAfterTask = false;
      return;
    }
    if (_taskRunning) {
      // Keep the request pending. The current task's finalizer schedules this
      // callback again, so resume never silently loses its regular scan.
      _resumeCheckAfterTask = true;
      return;
    }
    final forceRegularCheck = _resumeCheckAfterTask;
    _resumeCheckPending = false;
    _resumeCheckAfterTask = false;
    final last = _lastScanCompletedAt;
    if (!forceRegularCheck &&
        last != null &&
        DateTime.now().difference(last) < _resumeStaleAfter) {
      return;
    }
    unawaited(_startTask(_check, cancelExisting: false));
  }

  /// Schedules one debounced regular check after the app returns to the
  /// foreground. A recent completed scan is already fresh enough, while a
  /// resume observed during another task is retained until that task settles.
  static void onAppResumed() {
    if (!_isInitialized || !followUpdatesEnabled) return;
    _resumeCheckPending = true;
    _resumeCheckAfterTask = _resumeCheckAfterTask || _taskRunning;
    _scheduleResumeCheck();
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
    _cacheListenerAttached = true;
    _checkTimer = Timer.periodic(
      const Duration(minutes: 10),
      (_) => unawaited(_startTask(_check, cancelExisting: false)),
    );
    // Metadata stays fresh independently of the scan schedule; the first
    // round runs after the startup scan task settles (see _startTask).
    _summaryTimer = Timer.periodic(
      NetworkFavoriteCacheManager.backgroundSummaryRefreshAfter,
      (_) => _maybeRefreshSummaries(),
    );
  }

  /// Releases the service-owned timers/listener and invalidates the active
  /// generation. The in-flight network request is not forcefully interrupted
  /// here, but its result can no longer commit after disposal.
  static void disposeChecker() {
    _checkTimer?.cancel();
    _checkTimer = null;
    _summaryTimer?.cancel();
    _summaryTimer = null;
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _autoScanTimer?.cancel();
    _autoScanTimer = null;
    _cancelCurrent?.call();
    _activeToken?.cancel();
    _activeToken = null;
    _activeTask = null;
    _cancelCurrent = null;
    _taskRunning = false;
    taskRunning.value = false;
    baselineStatus.value = null;
    _resumeCheckPending = false;
    _resumeCheckAfterTask = false;
    if (_cacheListenerAttached) {
      NetworkFavoriteCacheManager().removeListener(_onCacheChanged);
      _cacheListenerAttached = false;
    }
    _isInitialized = false;
    _lastScanCompletedAt = null;
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
