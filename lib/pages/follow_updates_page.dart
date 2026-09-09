import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/global_state.dart';
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
              if (_enabled && _count > 0)
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
  List<FavoriteItemWithUpdateInfo> suspectComics = [];
  int _allComicsPage = 0;
  int _allComicsTotal = 0;
  int _allComicsRequestId = 0;
  bool _allComicsHasMore = false;
  bool _allComicsLoading = false;
  bool _allComicsExpanded = false;
  bool _allComicsLoadedOnce = false;
  bool _suspectComicsExpanded = true;

  bool get _enabled => followUpdatesEnabled;

  @override
  void initState() {
    super.initState();
    updateComics();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SmoothCustomScrollView(
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
            buildScannerUnavailableNotice(context),
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

  Widget buildScannerUnavailableNotice(BuildContext context) {
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
            Text(followUpdateScannerUnavailableMessage.tl),
            const SizedBox(height: 4),
            Text('Displayed scan state is historical'.tl, style: ts.s12),
          ],
        ),
      ),
    );
  }

  Widget buildBaselineInProgress(BuildContext context) =>
      buildScannerUnavailableNotice(context);

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
              IconButton(
                tooltip: 'Check Now'.tl,
                onPressed: startRefresh,
                icon: const Icon(Icons.refresh),
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
      SliverToBoxAdapter(
        child: Text(
          'Displayed scan state is historical'.tl,
        ).paddingHorizontal(16).paddingVertical(4),
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
      if (_suspectComicsExpanded && suspectComics.isNotEmpty)
        SliverGridComics(
          comics: suspectComics,
          badgeBuilder: (_) => 'Suspected removed'.tl,
          dimmedBuilder: (_) => true,
        ),
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
    context.showMessage(message: followUpdateScannerUnavailableMessage.tl);
  }

  void disable() {
    FollowUpdatesService.cancelChecking();
    appdata.settings['followUpdatesEnabled'] = false;
    appdata.settings['followUpdatesFolder'] = null;
    appdata.saveData();
    updateFollowUpdatesUI();
  }

  void startRefresh() {
    if (!_enabled) return;
    context.showMessage(message: followUpdateScannerUnavailableMessage.tl);
  }

  Future<void> showBaselineProgress() async {
    if (!_enabled) return;
    context.showMessage(message: followUpdateScannerUnavailableMessage.tl);
  }

  void updateComics() {
    if (!mounted) return;
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
      final folders = getFollowUpdateFolders();
      updatedComics = cache.getUpdatedComicsInFolders(folders);
      suspectComics = cache.getSuspectGoneComicsInFolders(folders);
      allComics = [];
      _allComicsPage = 0;
      _allComicsTotal = 0;
      _allComicsHasMore = false;
      _allComicsLoading = false;
      _allComicsLoadedOnce = false;
      _allComicsRequestId++;
    });
    if (_enabled && _allComicsExpanded) _loadAllComics();
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
    if (!_allComicsLoading && _allComicsHasMore) _loadAllComics();
  }

  @override
  Object? get key => 'FollowUpdatesPage';
}

/// Public compatibility shell for the retired scanner.
///
/// The service owns no task, timer, queue, source request or scan write. Its
/// methods remain so app lifecycle and existing UI callers stay source
/// compatible while every scan entry is unavailable.
abstract class FollowUpdatesService {
  static bool _isInitialized = false;
  static bool _cacheListenerAttached = false;

  static final ValueNotifier<BaselineStatus?> baselineStatus =
      ValueNotifier<BaselineStatus?>(null);
  static final ValueNotifier<bool> taskRunning = ValueNotifier<bool>(false);

  static void cancelChecking() {
    baselineStatus.value = null;
    taskRunning.value = false;
  }

  static Future<void> runCheckNow() => Future<void>.value();

  static Future<void> forceScanAll() => Future<void>.value();

  static Future<void> refreshRandomComics() => Future<void>.value();

  static void startBaseline() {}

  static void onAppResumed() {}

  static void initChecker() {
    if (_isInitialized) return;
    _isInitialized = true;
    if (!_cacheListenerAttached) {
      NetworkFavoriteCacheManager().addListener(_onCacheChanged);
      _cacheListenerAttached = true;
    }
  }

  static void disposeChecker() {
    if (_cacheListenerAttached) {
      NetworkFavoriteCacheManager().removeListener(_onCacheChanged);
      _cacheListenerAttached = false;
    }
    _isInitialized = false;
    baselineStatus.value = null;
    taskRunning.value = false;
  }

  static void _onCacheChanged() => updateFollowUpdatesUI();
}

void updateFollowUpdatesUI() {
  GlobalState.findOrNull<_FollowUpdatesWidgetState>()?.updateCount();
  GlobalState.findOrNull<_FollowUpdatesPageState>()?.updateComics();
}
