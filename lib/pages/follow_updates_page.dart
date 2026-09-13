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
import 'package:venera/foundation/follow_updates_service.dart';
import 'package:venera/foundation/global_state.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

/// Debug builds may bypass the pre-condition gate (Contract F2.6).
///
/// Kept as a top-level flag so the bypass survives page rebuilds, and gated on
/// [kDebugMode] so a release build cannot reach the toggle at all.
bool _debugGateBypass = false;

/// The entry badge.
///
/// Reads the **same** source as the list (Contract F3.2): a count that came
/// from anywhere else could disagree with the list, which is exactly the
/// "badge says 3, list is empty" failure.
class FollowUpdatesWidget extends StatefulWidget {
  const FollowUpdatesWidget({super.key});

  @override
  State<FollowUpdatesWidget> createState() => _FollowUpdatesWidgetState();
}

class _FollowUpdatesWidgetState
    extends AutomaticGlobalState<FollowUpdatesWidget> {
  int _count = 0;
  int _requestId = 0;
  StreamSubscription<void>? _judgmentBatches;

  bool get _enabled => followUpdatesEnabled;

  /// Reads the count asynchronously, discarding a response whose request is no
  /// longer current (Contract F7).
  ///
  /// The judgment store is asynchronous while the old local cache was not, so
  /// "call and it is done" no longer holds: two overlapping reads can return
  /// out of order and leave the older one displayed.
  ///
  /// A failed read leaves the badge at zero rather than showing a stale count,
  /// and the page itself reports the unreadable state explicitly — the badge is
  /// a decoration, and the page is where "we could not read it" belongs.
  ///
  /// The count applies the **same per-source rule as the list** (Contract F3.2):
  /// a flagged comic whose source is still caching is not on screen, so counting
  /// it would produce the "badge says 3, list shows 1" failure this contract
  /// exists to prevent.
  Future<void> getCount() async {
    if (!_enabled) {
      _count = 0;
      return;
    }
    final requestId = ++_requestId;
    try {
      await judgmentService.repository.ensureOpen();
      final snapshot = await judgmentService.repository.readSnapshot();
      if (!mounted || requestId != _requestId) return;
      final sources = followUpdateCoordinator
          .evaluateGate()
          .satisfiedSourceKeys;
      setState(() {
        _count = snapshot.values
            .where(
              (state) =>
                  state.hasNewUpdate && sources.contains(state.sourceKey),
            )
            .length;
      });
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() => _count = 0);
    }
  }

  void updateCount() => unawaited(getCount());

  @override
  void initState() {
    super.initState();
    updateCount();
    followUpdateCoordinator.progress.addListener(_onProgress);
    // FR-009: the UI side consumes the judgment batch event.  The count can
    // only change when judgment commits, so this is the precise moment to
    // re-read; the per-task progress frames are for the bar, not for the count.
    _judgmentBatches = judgmentService.events.listen((_) => updateCount());
  }

  @override
  void dispose() {
    followUpdateCoordinator.progress.removeListener(_onProgress);
    unawaited(_judgmentBatches?.cancel());
    super.dispose();
  }

  /// Re-reads the count only when a round (or a cache run) has ended.
  ///
  /// Nothing the badge shows can change in between, and a read per task would
  /// scan the whole judgment table per task.
  void _onProgress() {
    if (!mounted) return;
    if (followUpdateCoordinator.currentProgress.isRoundEnd) updateCount();
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

/// Public so [updateFollowUpdatesUI] can reach it through [GlobalState].
class FollowUpdatesPageState extends AutomaticGlobalState<FollowUpdatesPage> {
  /// The single update list (Contract F3.1).
  List<FavoriteItemWithUpdateInfo> updatedComics = [];

  bool _loading = true;
  bool _unreadable = false;
  int _requestId = 0;
  StreamSubscription<void>? _judgmentBatches;

  bool get _enabled => followUpdatesEnabled;

  /// The gate, read from configuration (Contract F2).
  ///
  /// The coordinator's own criterion set is used, so the gate judges exactly the
  /// sources a round would scan, and the coordinator's cache reader, so the
  /// completeness answer comes from the same store.
  FollowUpdateGate get gate => followUpdateCoordinator.evaluateGate();

  bool get _gateBypassed => kDebugMode && _debugGateBypass;

  /// The source whose account-switch clear explains an unsatisfied gate.
  ///
  /// Read once per build from the process-lifetime marker the cache manager
  /// sets, so the page can attribute the empty cache to an account change
  /// (FR-034) rather than presenting it as "never cached".
  String? get _accountSwitchSourceKey =>
      NetworkFavoriteCacheManager.accountSwitchClearedSourceKey;

  bool get _showList => !_enabled || _gateBypassed || gate.isSatisfied;

  /// The entries the gate currently allows on screen (F2.3, revised).
  ///
  /// Per source: a source's entries are shown only once **that source's** own
  /// cache is complete, because a partial cache would render a partial answer
  /// as if it were the whole one.  Applied at build time rather than when the
  /// snapshot is read, so a source that finishes caching appears as soon as the
  /// next frame arrives instead of waiting for another store read.
  ///
  /// The debug bypass (F2.6) is exactly the switch that removes this rule, so it
  /// returns everything.
  List<FavoriteItemWithUpdateInfo> get visibleComics {
    if (_gateBypassed) return updatedComics;
    final sources = gate.satisfiedSourceKeys;
    return updatedComics
        .where((comic) => sources.contains(comic.sourceKeyValue))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    unawaited(updateComics());
    followUpdateCoordinator.progress.addListener(_onProgress);
    // FR-009: the judgment batch event is consumed by the UI side as well as
    // by the schedule.  It is the signal that actually corresponds to content
    // changing, so it — rather than the per-task progress frames — decides when
    // the list is re-read.
    _judgmentBatches = judgmentService.events.listen((_) {
      unawaited(updateComics());
    });
  }

  @override
  void dispose() {
    followUpdateCoordinator.progress.removeListener(_onProgress);
    unawaited(_judgmentBatches?.cancel());
    super.dispose();
  }

  /// Repaints the bar on every frame; re-reads the list only at a boundary.
  ///
  /// The bar has to move as each task settles (F5.4), while a read is a join of
  /// the whole judgment table with the favorite cache: reading per task would
  /// make the page's cost grow with the number of comics.
  void _onProgress() {
    if (!mounted) return;
    if (followUpdateCoordinator.currentProgress.isRoundEnd) {
      unawaited(updateComics());
      return;
    }
    setState(() {});
  }

  /// Reads the visible update set and joins it to the presentation cache.
  ///
  /// Asynchronous, with a sequencing guard: the page is refreshed from progress
  /// and cache events as well as from the first build, and an older response
  /// arriving late must not overwrite a newer one.
  Future<void> updateComics() async {
    if (!mounted) return;
    final requestId = ++_requestId;
    if (!_enabled) {
      setState(() {
        updatedComics = [];
        _loading = false;
        _unreadable = false;
      });
      return;
    }
    try {
      await judgmentService.repository.ensureOpen();
      final snapshot = await judgmentService.repository.readSnapshot();
      if (!mounted || requestId != _requestId) return;
      setState(() {
        updatedComics = _resolvePresentation(
          snapshot.values
              .where((state) => state.hasNewUpdate)
              .map((state) => (state.sourceKey, state.comicId))
              .toList(),
        );
        _loading = false;
        _unreadable = false;
      });
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        updatedComics = [];
        _loading = false;
        _unreadable = true;
      });
    }
  }

  /// Joins each flagged identity to its cached favorite entry.
  ///
  /// The judgment store deliberately carries no title or cover; those live in
  /// the favorite cache.  Contract F3.3 requires every listed entry to render,
  /// so this returns only identities the cache can describe — which is
  /// precisely why the gate exists: the cache is guaranteed complete for a
  /// criterion source before the list is shown at all.
  List<FavoriteItemWithUpdateInfo> _resolvePresentation(
    List<(String, String)> identities,
  ) {
    if (identities.isEmpty) return const [];
    final cache = NetworkFavoriteCacheManager();
    final result = <FavoriteItemWithUpdateInfo>[];
    try {
      final foldersBySource = <String, List<NetworkFavoriteFolderRef>>{};
      for (final folder in cache.getAllCachedFolders()) {
        foldersBySource.putIfAbsent(folder.sourceKey, () => []).add(folder);
      }
      for (final (sourceKey, comicId) in identities) {
        for (final folder in foldersBySource[sourceKey] ?? const []) {
          final item = cache.getComicUpdateInfo(
            sourceKey,
            comicId,
            folder.folderId,
          );
          if (item != null) {
            result.add(item);
            break;
          }
        }
      }
    } catch (_) {
      return const [];
    }
    result.sort((a, b) => a.name.compareTo(b.name));
    return result;
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
            buildProgressArea(context),
            if (!_showList) buildGateNotice(context) else buildUpdatedComics(),
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

  /// The gate's presentation (Contract F2.3/F2.4).
  ///
  /// Shows an explanation and an entry point to the full cache, and **no list
  /// in any form** — not a partial one and not a placeholder one.  A partial
  /// list would look like a complete answer, and the whole reason the gate
  /// exists is that the presentation data is not complete yet.
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
                  // FR-034: the user must be told the results are missing
                  // *because the account changed*, not because something broke.
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
                  onChanged: (value) =>
                      setState(() => _debugGateBypass = value),
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

  /// The in-progress state of a full cache, or of a round (Contract F2.3).
  Widget buildProgressArea(BuildContext context) {
    final caching = followUpdateCoordinator.isCachingFavorites;
    final running = followUpdateCoordinator.isRunning;
    if (!running && !caching) return buildPostCacheTransition(context);
    final progress = followUpdateCoordinator.currentProgress;
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
            // A full cache is named as such: it is the step that unblocks the
            // gate, so presenting it as an ordinary update check would leave
            // the user waiting for a list that is still withheld (F2.3/F2.5).
            Text(caching ? 'Caching favorites'.tl : 'Checking updates'.tl),
            const SizedBox(height: 8),
            // A determinate bar, never an indeterminate spinner: both counts
            // are known before the work starts (Contract F5.2).
            LinearProgressIndicator(value: progress.fraction),
            const SizedBox(height: 4),
            Text(followUpdateProgressLabel(progress), style: ts.s12),
            if (caching) ...[
              const SizedBox(height: 4),
              Text('Caching is not finished yet'.tl, style: ts.s12),
            ],
            const SizedBox(height: 8),
            // Non-modal: the page stays fully operable while work runs
            // (Contract F1.3 / FR-005).
            OutlinedButton.icon(
              onPressed: caching
                  ? followUpdateCoordinator.cancelFullCache
                  : followUpdateCoordinator.cancel,
              icon: const Icon(Icons.stop),
              label: Text('Cancel'.tl),
            ),
          ],
        ),
      ),
    );
  }

  /// The transition once a full cache has finished (Contract F2.3).
  ///
  /// The gate has just opened, so the list is available for the first time.  A
  /// refresh entry point is shown rather than silently swapping the page's
  /// content: the user pressed "cache completely", so they should be able to see
  /// that it worked and that the results are now theirs to look at.
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
                unawaited(updateComics());
              },
              child: Text('Show updates'.tl),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildUpdatedComics() {
    final comics = visibleComics;
    return SliverMainAxisGroup(
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
                if (followUpdateCoordinator.isRunning)
                  Text('Follow-up scan in progress'.tl, style: ts.s12),
                IconButton(
                  tooltip: 'Check Now'.tl,
                  onPressed: startRefresh,
                  icon: const Icon(Icons.refresh),
                ),
                if (comics.isNotEmpty)
                  IconButton(
                    tooltip: 'Mark all as read'.tl,
                    icon: const Icon(Icons.clear_all),
                    onPressed: markAllAsRead,
                  ),
              ],
            ),
          ),
        ),
        // The partial case (F2.7): results are shown, but not from every
        // tracked source.  Without this line the list would simply be missing
        // entries with nothing to explain why — the failure mode the old
        // all-or-nothing gate avoided by showing nothing at all.
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
        if (comics.isNotEmpty)
          SliverToBoxAdapter(
            child: Text(
              'Updates are marked read when you start reading.'.tl,
            ).paddingHorizontal(16).paddingVertical(4),
          ),
        if (_loading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else if (_unreadable)
          SliverToBoxAdapter(child: buildUnreadableNotice(context))
        else if (comics.isNotEmpty)
          SliverGridComics(
            comics: comics,
            // Entering from the follow-up list counts as read (Contract F4), so
            // the entry clears the flag on the way through.  The navigation is
            // still the default one: the clear is a side effect, not a
            // replacement for opening the comic.
            onTap: (comic, heroID) => _openFromList(comic, heroID),
          )
        else
          SliverToBoxAdapter(child: buildEmptyState(context)),
      ],
    );
  }

  /// Opens one comic from the list, clearing its flag first (Contract F4).
  ///
  /// The clear is awaited before navigating so the list behind the pushed page
  /// is already correct when the user comes back — no manual refresh, and no
  /// window in which the comic is both open and still listed.
  Future<void> _openFromList(Comic comic, int? heroID) async {
    try {
      await judgmentService.clearVisibleFlag(comic.sourceKey, comic.id);
    } catch (_) {
      // A storage problem must not stop the comic from opening; the flag will
      // be cleared on the next entry instead.
    }
    if (!mounted) return;
    // Refresh the list and the badge before the push, so returning shows the
    // comic already gone.
    await updateComics();
    updateFollowUpdatesUI();
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

  /// Unreadable is reported, never rendered as an empty list (Contract F3.4).
  Widget buildUnreadableNotice(BuildContext context) => Container(
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
          onPressed: () => unawaited(updateComics()),
          child: Text('Retry'.tl),
        ),
      ],
    ),
  );

  Widget buildEmptyState(BuildContext context) => SizedBox(
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
  );

  void markAllAsRead() {
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
    // Only what the user can actually see: marking a hidden source's entries
    // read would silently discard flags they were never shown (F2.3, revised).
    // One single-row clear per entry; never a whole-table rewrite (Contract E6).
    for (final comic in List.of(visibleComics)) {
      await judgmentService.clearVisibleFlag(comic.sourceKey, comic.id);
    }
    await updateComics();
    updateFollowUpdatesUI();
  }

  void enable() {
    appdata.settings['followUpdatesEnabled'] = true;
    appdata.saveData();
    updateFollowUpdatesUI();
    unawaited(followUpdateCoordinator.onProcessStart());
  }

  void disable() {
    followUpdateCoordinator.cancel();
    appdata.settings['followUpdatesEnabled'] = false;
    appdata.settings['followUpdatesFolder'] = null;
    appdata.saveData();
    updateFollowUpdatesUI();
  }

  /// The manual entry point.
  ///
  /// Goes through the coordinator's single range rule, so it is a
  /// schedule-respecting check and **not** a forced full scan (Contract F1).
  void startRefresh() {
    if (!_enabled) return;
    unawaited(followUpdateCoordinator.runRound(FollowUpdateTrigger.manual));
  }

  /// Starts (or reports) the full favorite cache, which is what unblocks the
  /// gate (Contract F2.5: cache first, then check).
  void startFullCache() {
    final coordinator = followUpdateCoordinator;
    if (coordinator.startFullFavoriteCache()) {
      context.showMessage(message: 'Caching favorites'.tl);
    } else {
      context.showMessage(message: 'A check is already in progress'.tl);
    }
  }

  /// Reports the current round's progress rather than starting anything.
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

/// The one wording for "how far along the round is".
///
/// Shared by the progress area and the app-bar entry so the two cannot
/// disagree, and so that "0 / 0" cannot be shown for a round that has not
/// finished finding out what it has to do: before target enumeration completes
/// there is no denominator, only an unknown one, and reporting that as zero is
/// what made a running check look stuck at zero (Contract F5.4).
String followUpdateProgressLabel(FollowUpdateProgress progress) =>
    progress.discovered > 0 || progress.isComplete
    ? '@done/@total tasks'.tlParams({
        'done': progress.finished,
        'total': progress.discovered,
      })
    : 'Finding what to check'.tl;

void updateFollowUpdatesUI() {
  GlobalState.findOrNull<_FollowUpdatesWidgetState>()?.updateCount();
  // `updateComics` is asynchronous now, so `unawaited` makes the intent
  // explicit rather than leaving a discarded future for the linter to find.
  final page = GlobalState.findOrNull<FollowUpdatesPageState>();
  if (page != null) unawaited(page.updateComics());
}
