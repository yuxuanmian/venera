import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:sliver_tools/sliver_tools.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/rich_comment_content.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/follow_updates_service.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/schedule/schedule_repository.dart';
import 'package:venera/foundation/schedule/schedule_state.dart';
import 'package:venera/foundation/schedule/sqlite_schedule_repository.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_result_repository.dart';
import 'package:venera/foundation/scan/sqlite_scan_result_repository.dart';
import 'package:venera/foundation/scan/source_adapter.dart';
import 'package:venera/foundation/tracking/diagnostics.dart';
import 'package:venera/foundation/tracking/judgment.dart';
import 'package:venera/foundation/tracking/judgment_event.dart';
import 'package:venera/foundation/tracking/judgment_repository.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';
import 'package:venera/network/download.dart';
import 'package:venera/pages/reader/entry_route.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/comic_author_copy.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';
import 'dart:math' as math;

part 'comments_page.dart';

part 'chapters.dart';

part 'thumbnails.dart';

part 'favorite.dart';

part 'comments_preview.dart';

part 'actions.dart';

part 'cover_viewer.dart';

part 'debug.dart';

@visibleForTesting
bool shouldShowFavoriteHotWindowIndicator({
  required bool followUpdatesEnabled,
  required bool isFavorite,
  required bool hasCheckRecord,
  bool hasCollectionFailure = false,
}) =>
    followUpdatesEnabled &&
    isFavorite &&
    (hasCheckRecord || hasCollectionFailure);

@visibleForTesting
bool isExplicitCollectionScanFailure({
  required ScanItemResult? result,
  required bool sourceOptedIn,
  required bool inFollowUpdateRange,
}) =>
    sourceOptedIn &&
    inFollowUpdateRange &&
    result?.producer == ScanProducer.collection &&
    result?.failure != null;

bool _isAuthorNamespace(String namespace) {
  switch (namespace.trim().toLowerCase()) {
    case 'author':
    case 'authors':
    case 'artist':
    case 'artists':
    case '作者':
    case '画师':
      return true;
    default:
      return false;
  }
}

String _briefLoadError(Object? error) {
  final message = (error?.toString() ?? '').replaceAll(RegExp(r'\s+'), ' ');
  return message.length <= 160 ? message : '${message.substring(0, 160)}...';
}

@visibleForTesting
String selectComicCoverUrl(String? widgetCover, String comicCover) {
  final loadedCover = comicCover.trim();
  if (loadedCover.isNotEmpty) {
    return loadedCover;
  }
  return (widgetCover ?? '').trim();
}

List<String> _collectKnownAuthorNames(ComicDetails comic) {
  final names = <String>[];
  for (final entry in comic.tags.entries) {
    if (_isAuthorNamespace(entry.key)) {
      names.addAll(entry.value);
    }
  }
  final author = comic.findAuthor();
  if (author != null) names.add(author);
  return names;
}

class ComicPage extends StatefulWidget {
  const ComicPage({
    super.key,
    required this.id,
    required this.sourceKey,
    this.cover,
    this.title,
    this.heroID,
    this.scheduleReader,
    this.judgmentEvents,
    this.scanItemReader,
    this.scanEvents,
    this.followUpdateRangeReader,
  });

  final String id;

  final String sourceKey;

  final String? cover;

  final String? title;

  final int? heroID;

  /// Test injection point for the schedule point-read (007 FR-004).
  ///
  /// Production callers leave this null and read through the app-owned
  /// schedule service (`followUpdateScheduleService`); a test uses it to
  /// control the answer and count the reads without standing up the whole
  /// composition layer.
  final Future<ScheduleState?> Function(String sourceKey, String comicId)?
  scheduleReader;

  /// Test injection point for the judgment batch stream (007 FR-006).
  ///
  /// Production callers leave this null: the page subscribes to the app-owned
  /// judgment service's **existing** event stream.  This is an injection point,
  /// not a second event channel — the type is the same one the service
  /// publishes, and nothing in production constructs one here.
  final Stream<JudgmentBatchEvent>? judgmentEvents;

  final Future<ScanStoredItem?> Function(String sourceKey, String comicId)?
  scanItemReader;

  final Stream<ScanRepositoryEvent>? scanEvents;

  final bool Function(String sourceKey)? followUpdateRangeReader;

  @override
  State<ComicPage> createState() => _ComicPageState();
}

class _ComicPageState extends LoadingState<ComicPage, ComicDetails>
    with _ComicPageActions {
  String get _comicCoverUrl => selectComicCoverUrl(widget.cover, comic.cover);

  @override
  History? history;

  bool showAppbarTitle = false;

  var scrollController = ScrollController();

  final _followUpdateCache = NetworkFavoriteCacheManager();

  bool isDownloaded = false;

  bool showFAB = false;

  FavoriteCoverSnapshot? _coverSnapshot;
  int _coverGeneration = 0;
  bool _coverWritebackHandled = false;

  void _onDetailCoverDisplayed({
    required String detailCover,
    required FavoriteCoverSnapshot snapshot,
    required int generation,
  }) {
    if (detailCover.isEmpty || !snapshot.hasRows) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _coverGeneration ||
          comic.cover.trim() != detailCover ||
          !identical(snapshot, _coverSnapshot)) {
        return;
      }
      _performCoverWriteback(snapshot: snapshot, detailCover: detailCover);
    });
  }

  void _performCoverWriteback({
    required FavoriteCoverSnapshot snapshot,
    required String detailCover,
  }) {
    if (_coverWritebackHandled) return;
    _coverWritebackHandled = true;
    _followUpdateCache.writebackFavoriteCover(
      snapshot: snapshot,
      newCover: detailCover,
    );
  }

  /// The schedule record of this comic, when it has one.
  ///
  /// Null means "no check record yet" — which is also what a read failure and a
  /// not-yet-finished read look like (Contract W8).  The page therefore shows
  /// nothing rather than guessing a state, and it MUST NOT write a record to
  /// fill the gap: "no schedule record" is a due condition (Contract S4), so
  /// writing one would change when this comic is checked next.
  ScheduleState? _scheduleState;
  ScanItemResult? _latestScanResult;
  int _scanReadGeneration = 0;

  StreamSubscription<JudgmentBatchEvent>? _judgmentSubscription;
  StreamSubscription<ScanRepositoryEvent>? _scanSubscription;

  /// Whether the details page is showing the "recently updated" indicator.
  ///
  /// Visible ⇔ 追更总开关开启 ∧ 该本已有检查记录 (Contract W2).  The criterion is
  /// deliberately **not** "does this source currently have a scan capability":
  /// sources gain capabilities over time, and keying on the record means the
  /// indicator follows along without a judgement edit per source.
  bool get _showFollowUpIndicator => shouldShowFavoriteHotWindowIndicator(
    followUpdatesEnabled: followUpdatesEnabled,
    isFavorite: isFavorite,
    hasCheckRecord: _scheduleState != null,
    hasCollectionFailure: _showCollectionFailure,
  );

  bool get _showCollectionFailure {
    final result = _latestScanResult;
    final source = ComicSource.find(widget.sourceKey);
    if (result == null ||
        result.producer != ScanProducer.collection ||
        result.failure == null ||
        source == null ||
        !sourceSupportsCollectionItemFailures(source)) {
      return false;
    }
    final inRange =
        widget.followUpdateRangeReader?.call(widget.sourceKey) ??
        followUpdateCoordinator.evaluateGate().satisfiedSourceKeys.contains(
          widget.sourceKey,
        );
    return inRange;
  }

  FavoriteHotWindowIndicator? get _hotWindowIndicator {
    final state = _scheduleState;
    final collectionFailure = _showCollectionFailure;
    if (state == null && !collectionFailure) return null;
    return FavoriteHotWindowIndicator(
      autoHotUntil: state?.autoHotUntilMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              state!.autoHotUntilMs!,
              isUtc: true,
            ),
      collectionUnavailable: collectionFailure,
    );
  }

  void _onFollowUpdateCacheChanged() {
    if (mounted) setState(() {});
  }

  /// Point-reads this identity's schedule for display (FR-004 / W3 / W8).
  ///
  /// One primary-key lookup, never the whole table: opening a details page must
  /// not cost a row per stored schedule.  The stored value is used as-is — the
  /// page MUST NOT re-derive bands or window lengths (Contract W3).
  ///
  /// The read is **not** gated on the favorite or follow-up switches: those
  /// decide *visibility* (Contract W2), not whether there is a record to show,
  /// and a single indexed row is the whole cost.
  Future<void> _loadScheduleIndicator() async {
    final reader = widget.scheduleReader;
    ScheduleState? state;
    try {
      if (reader != null) {
        state = await reader(widget.sourceKey, widget.id);
      } else {
        final schedule = followUpdateScheduleService;
        // Null before startup has attached the service.  Rendered exactly like
        // "no record"; the page MUST NOT create a second service of its own.
        state = schedule == null
            ? null
            : await schedule.readIdentity(widget.sourceKey, widget.id);
      }
    } catch (_) {
      // A read failure is rendered as "no record" and MUST NOT break the rest
      // of the page (W8).
      state = null;
    }
    if (!mounted) return;
    setState(() => _scheduleState = state);
  }

  Future<void> _loadCollectionFailure() async {
    final source = ComicSource.find(widget.sourceKey);
    if (source == null || !sourceSupportsCollectionItemFailures(source)) {
      _scanReadGeneration++;
      if (mounted) setState(() => _latestScanResult = null);
      return;
    }
    final generation = ++_scanReadGeneration;
    final reader = widget.scanItemReader;
    ScanItemResult? result;
    try {
      final stored = reader != null
          ? await reader(widget.sourceKey, widget.id)
          : await scanResultRepository.readLatestItem(
              widget.sourceKey,
              widget.id,
            );
      result = stored?.result;
    } catch (_) {
      result = null;
    }
    if (!mounted || generation != _scanReadGeneration) return;
    setState(() => _latestScanResult = result);
  }

  void _onScanEvent(ScanRepositoryEvent event) {
    final item = event.item;
    if (item == null ||
        item.result.sourceKey != widget.sourceKey ||
        item.result.comicId != widget.id) {
      return;
    }
    if (!mounted) return;
    _scanReadGeneration++;
    setState(() => _latestScanResult = item.result);
  }

  /// Re-reads the schedule when this identity itself appears in a batch (W4).
  ///
  /// Batches carrying only other identities are **not** re-read: that would be
  /// pointless I/O.  The listener holds no correctness role — it decides when
  /// to redraw, never what the schedule is.
  void _onJudgmentBatch(JudgmentBatchEvent event) {
    final identity = '${widget.sourceKey}\u0000${widget.id}';
    var relevant = false;
    for (final row in event.rows) {
      if (row.identity == identity) {
        relevant = true;
        break;
      }
    }
    if (!relevant) return;
    unawaited(_loadScheduleIndicator());
  }

  @override
  void onReadEnd() {
    history ??= HistoryManager().find(
      widget.id,
      ComicType(widget.sourceKey.hashCode),
    );
    update();
  }

  @override
  Widget buildLoading() => _buildDetails(context, null);

  @override
  Widget buildError() {
    final isDownloaded = LocalManager().isDownloaded(
      widget.id,
      ComicType.fromKey(widget.sourceKey),
    );
    final cache = NetworkFavoriteCacheManager();
    final isFavorite = cache.isFavoriteKnown(widget.sourceKey, widget.id);
    // FR-023: the "suspected removed" verdict and its two buttons are gone.
    // The only destructive action left is removing a favorite the user still
    // has, which needs no delist evidence to justify it.
    final buttons = <Widget>[
      if (isDownloaded)
        FilledButton.tonalIcon(
          icon: const Icon(Icons.menu_book_outlined),
          label: Text("Read".tl),
          onPressed: () {
            final localComic = LocalManager().find(
              widget.id,
              ComicType.fromKey(widget.sourceKey),
            );
            if (localComic == null) {
              context.showMessage(message: "Local comic not found".tl);
              return;
            }
            localComic.read();
          },
        ),
      if (isFavorite)
        FilledButton.tonalIcon(
          icon: const Icon(Icons.delete_outline),
          onPressed: removeFavorite,
          label: Text('Remove Favorite'.tl),
        ),
    ];
    return NetworkError(
      message: error!,
      retry: retry,
      action: buttons.isEmpty ? null : buttons,
    );
  }

  Future<void> removeFavorite() async {
    final result = await NetworkFavoriteCacheManager().removeFavoriteEverywhere(
      widget.sourceKey,
      widget.id,
    );
    if (!mounted) return;
    if (result.error) {
      context.showMessage(message: result.errorMessage!);
      return;
    }
    context.pop();
  }

  @override
  void initState() {
    scrollController.addListener(onScroll);
    _followUpdateCache.addListener(_onFollowUpdateCacheChanged);
    // One read on open, then one more per judgment batch that contains this
    // identity.  Subscribing in the page's own lifecycle is what keeps the
    // listener from outliving the page (Contract W4).
    unawaited(_loadScheduleIndicator());
    unawaited(_loadCollectionFailure());
    _judgmentSubscription = (widget.judgmentEvents ?? judgmentService.events)
        .listen(_onJudgmentBatch);
    _scanSubscription = (widget.scanEvents ?? scanResultRepository.events)
        .listen(_onScanEvent);
    super.initState();
  }

  @override
  void dispose() {
    scrollController.removeListener(onScroll);
    scrollController.dispose();
    _followUpdateCache.removeListener(_onFollowUpdateCacheChanged);
    unawaited(_judgmentSubscription?.cancel());
    _judgmentSubscription = null;
    unawaited(_scanSubscription?.cancel());
    _scanSubscription = null;
    super.dispose();
  }

  @override
  void update() {
    setState(() {});
  }

  @override
  void reloadScheduleIndicator() => unawaited(_loadScheduleIndicator());

  @override
  ComicDetails get comic => data!;

  void onScroll() {
    var offset =
        scrollController.position.pixels -
        scrollController.position.minScrollExtent;
    var showFAB = offset > 0;
    if (showFAB != this.showFAB) {
      setState(() {
        this.showFAB = showFAB;
      });
    }
    if (offset > 100) {
      if (!showAppbarTitle) {
        setState(() {
          showAppbarTitle = true;
        });
      }
    } else {
      if (showAppbarTitle) {
        setState(() {
          showAppbarTitle = false;
        });
      }
    }
  }

  var isFirst = true;

  List<String> get _knownAuthorNames => _collectKnownAuthorNames(comic);

  @override
  Widget buildContent(BuildContext context, ComicDetails data) =>
      _buildDetails(context, data);

  Widget _buildDetails(BuildContext context, ComicDetails? details) {
    final loading = details == null;
    return Scaffold(
      floatingActionButton: !loading && showFAB
          ? FloatingActionButton(
              onPressed: () {
                scrollController.animateTo(
                  0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.ease,
                );
              },
              child: const Icon(Icons.arrow_upward),
            )
          : null,
      body: SmoothCustomScrollView(
        controller: scrollController,
        slivers: [
          ...buildTitle(details),
          buildActions(loading: loading),
          buildDescription(loading: loading),
          buildInfo(loading: loading),
          if (!loading) ...[
            buildChapters(),
            buildComments(),
            buildThumbnails(),
            buildRecommend(),
          ],
          SliverPadding(
            padding: EdgeInsets.only(
              bottom: context.padding.bottom + 80,
            ), // Add additional padding for FAB
          ),
        ],
      ),
    );
  }

  @override
  Future<Res<ComicDetails>> loadData() async {
    if (widget.sourceKey == 'local') {
      var localComic = LocalManager().find(widget.id, ComicType.local);
      if (localComic == null) {
        return const Res.error('Local comic not found');
      }
      var history = HistoryManager().find(widget.id, ComicType.local);
      if (isFirst) {
        Future.microtask(() {
          pushReader(App.rootContext, () {
            return Reader(
              type: ComicType.local,
              cid: widget.id,
              name: localComic.title,
              chapters: localComic.chapters,
              initialPage: history?.page,
              initialChapter: history?.ep,
              initialChapterGroup: history?.group,
              history:
                  history ??
                  History.fromModel(model: localComic, ep: 0, page: 0),
              author: localComic.subTitle ?? '',
              tags: localComic.tags,
            );
          });
          App.mainNavigatorKey!.currentContext!.pop();
        });
        isFirst = false;
      }
      await Future.delayed(const Duration(milliseconds: 200));
      return const Res.error('Local comic');
    }
    var comicSource = ComicSource.find(widget.sourceKey);
    if (comicSource == null) {
      return const Res.error('Comic source not found');
    }
    history = HistoryManager().find(
      widget.id,
      ComicType(widget.sourceKey.hashCode),
    );
    _coverGeneration++;
    _coverWritebackHandled = false;
    try {
      _coverSnapshot = _followUpdateCache.captureFavoriteCoverSnapshot(
        widget.sourceKey,
        widget.id,
      );
    } catch (e, s) {
      _coverSnapshot = null;
      Log.error('Favorite cover snapshot', e.toString(), s);
    }
    final watch = Stopwatch()..start();
    try {
      final res = await comicSource.loadComicInfo!(widget.id);
      watch.stop();
      if (kDebugMode) {
        Log.info(
          'ComicPage',
          'loadComicInfo sourceKey=${widget.sourceKey} comicId=${widget.id} '
              '${res.success ? 'success' : 'failure'} '
              'total=${watch.elapsedMilliseconds}ms'
              '${res.error ? ' error=${_briefLoadError(res.errorMessage)}' : ''}',
        );
      }
      return res;
    } catch (e) {
      watch.stop();
      if (kDebugMode) {
        Log.info(
          'ComicPage',
          'loadComicInfo sourceKey=${widget.sourceKey} comicId=${widget.id} '
              'failure total=${watch.elapsedMilliseconds}ms '
              'error=${_briefLoadError(e)}',
        );
      }
      rethrow;
    }
  }

  @override
  void onDataLoaded() {
    isLiked = comic.isLiked ?? false;
    isFavorite =
        comic.isFavorite ??
        NetworkFavoriteCacheManager().isFavoriteKnown(
          comic.sourceKey,
          comic.id,
        );
    // For sources with multi-folder favorites, prefer querying folders to get accurate favorite status
    // Some sources may not set isFavorite reliably when multi-folder is enabled
    if (comic.chapters == null) {
      isDownloaded = LocalManager().isDownloaded(comic.id, comic.comicType, 0);
    }
    if (comicSource.favoriteData?.loadFolders != null && comicSource.isLogged) {
      unawaited(_refreshFavoriteFoldersInBackground());
    }
  }

  Future<void> _refreshFavoriteFoldersInBackground() async {
    final source = comicSource;
    final loadFolders = source.favoriteData?.loadFolders;
    if (loadFolders == null || !source.isLogged) return;

    final watch = Stopwatch()..start();
    try {
      final res = await loadFolders(comic.id);
      watch.stop();
      if (res.error) {
        if (kDebugMode) {
          Log.info(
            'ComicPage',
            'loadFolders sourceKey=${comic.sourceKey} comicId=${comic.id} '
                'failure total=${watch.elapsedMilliseconds}ms '
                'error=${_briefLoadError(res.errorMessage)}',
          );
        }
        return;
      }

      final membership = res.subData is List
          ? List<String>.from(res.subData)
          : null;
      if (kDebugMode) {
        Log.info(
          'ComicPage',
          'loadFolders sourceKey=${comic.sourceKey} comicId=${comic.id} '
              'success folders=${res.data.length} '
              'membership=${membership?.length ?? 0} '
              'total=${watch.elapsedMilliseconds}ms',
        );
      }
      if (!mounted) return;

      final cache = _followUpdateCache;
      cache.cacheFolderSnapshot(comic.sourceKey, res.data);
      final wasFavoriteKnown = cache.isFavoriteKnown(comic.sourceKey, comic.id);
      var shouldUpdate = false;
      if (membership != null) {
        if (membership.isNotEmpty) {
          cache.replaceComicMembership(comic.sourceKey, comic.id, membership);
          isFavorite = true;
        } else if (!wasFavoriteKnown) {
          // The server reports no membership and the device cache agrees:
          // the comic is not favorited.
          cache.replaceComicMembership(comic.sourceKey, comic.id, membership);
          isFavorite = false;
        } else {
          // The server reports no membership but the device cache knows the
          // comic is favorited (stale report right after a successful add):
          // keep the local knowledge instead of un-favoriting.
          isFavorite = true;
        }
        shouldUpdate = true;
      } else if (wasFavoriteKnown) {
        // The source did not report membership; the device cache is the more
        // reliable source for the favorited state.
        isFavorite = true;
        shouldUpdate = true;
      }
      if (shouldUpdate && mounted) {
        update();
      }
    } catch (e) {
      watch.stop();
      if (kDebugMode) {
        Log.info(
          'ComicPage',
          'loadFolders sourceKey=${widget.sourceKey} comicId=${widget.id} '
              'failure total=${watch.elapsedMilliseconds}ms '
              'error=${_briefLoadError(e)}',
        );
      }
    }
  }

  Iterable<Widget> buildTitle(ComicDetails? details) sync* {
    final detailCover = details?.cover.trim() ?? '';
    final coverUrl = selectComicCoverUrl(widget.cover, detailCover);
    final title = details?.title ?? widget.title;
    final snapshot = details == null ? null : _coverSnapshot;
    final generation = _coverGeneration;
    yield SliverAppbar(
      title: AnimatedOpacity(
        opacity: showAppbarTitle ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: Text(title ?? ''),
      ),
      actions: [
        IconButton(
          onPressed: details == null ? null : showMoreActions,
          icon: const Icon(Icons.more_horiz),
        ),
      ],
    );

    yield const SliverPadding(padding: EdgeInsets.only(top: 8));

    yield SliverLazyToBoxAdapter(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 16),
          GestureDetector(
            onTap: details == null ? null : () => _viewCover(context),
            onLongPress: details == null ? null : () => _saveCover(context),
            child: Hero(
              tag: "cover${widget.heroID}",
              child: Container(
                decoration: BoxDecoration(
                  color: context.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: context.colorScheme.outlineVariant,
                      blurRadius: 1,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                height: 144,
                width: 144 * 0.72,
                clipBehavior: Clip.antiAlias,
                child: coverUrl.isEmpty
                    ? const SkeletonBlock(height: 144, radius: 8)
                    : AnimatedImage(
                        image: CachedImageProvider(
                          coverUrl,
                          sourceKey: details?.sourceKey ?? widget.sourceKey,
                          cid: details?.id ?? widget.id,
                        ),
                        width: double.infinity,
                        height: double.infinity,
                        sweepOnReplacement: true,
                        onFirstFrame: snapshot == null
                            ? null
                            : (_) => _onDetailCoverDisplayed(
                                detailCover: detailCover,
                                snapshot: snapshot,
                                generation: generation,
                              ),
                      ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: AnimatedSize(
              duration: _detailMotionDuration,
              alignment: Alignment.topLeft,
              curve: Curves.easeOutCubic,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title == null)
                    const SkeletonBlock(width: 168, height: 19)
                  else
                    ComicTitleSelectableText(text: title, style: ts.s18),
                  if (details?.subTitle case final subtitle?)
                    ComicTitleSelectableText(
                      text: subtitle,
                      style: ts.s14,
                    ).paddingVertical(4),
                  Row(
                    key: const ValueKey('comic-source-copy-row'),
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Flexible(
                        fit: FlexFit.loose,
                        child: Text(
                          (ComicSource.find(widget.sourceKey)?.name) ?? '',
                          key: const ValueKey('comic-source-name'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ts.s12,
                        ),
                      ),
                      const SizedBox(width: 2),
                      if (details == null)
                        const SizedBox(height: 48)
                      else
                        ComicTitleCopyButton(
                          title: details.title,
                          subtitle: details.subTitle,
                          knownAuthors: _knownAuthorNames,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Duration get _detailMotionDuration => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 180);

  Widget _detailSection(Widget child, {required bool loading}) {
    return SliverLazyToBoxAdapter(
      child: AnimatedSize(
        alignment: Alignment.topCenter,
        curve: Curves.easeOutCubic,
        duration: _detailMotionDuration,
        child: TweenAnimationBuilder<double>(
          key: ValueKey(loading),
          duration: _detailMotionDuration,
          tween: Tween(begin: loading ? 1.0 : .2, end: 1.0),
          builder: (context, opacity, child) =>
              Opacity(opacity: opacity, child: child),
          child: child,
        ),
      ),
    );
  }

  Widget buildActions({required bool loading}) {
    bool isMobile = context.width < changePoint;
    if (loading) {
      return _detailSection(
        Column(
          children: [
            SkeletonSweep(
              child: Column(
                children: [
                  SizedBox(
                    height: 48,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      children: [
                        for (final width in [82.0, 74.0, 86.0, 70.0])
                          Center(
                            child: SkeletonBlock(
                              width: width,
                              height: 36,
                              radius: 20,
                            ),
                          ).paddingHorizontal(4),
                      ],
                    ),
                  ),
                  if (isMobile)
                    const Row(
                      children: [
                        Expanded(child: SkeletonBlock(height: 40, radius: 24)),
                        SizedBox(width: 16),
                        Expanded(
                          child: SkeletonBlock(
                            height: 40,
                            radius: 24,
                            emphasized: true,
                          ),
                        ),
                      ],
                    ).paddingHorizontal(16).paddingVertical(12),
                  if (history != null)
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: SkeletonBlock(width: 162, height: 36, radius: 20),
                    ).paddingHorizontal(16).paddingVertical(8),
                ],
              ),
            ),
            const Divider(),
          ],
        ).paddingTop(16),
        loading: true,
      );
    }
    bool hasHistory = history != null && (history!.ep > 1 || history!.page > 1);
    final indicator = _hotWindowIndicator;
    final showIndicator = _showFollowUpIndicator && indicator != null;
    return _detailSection(
      Column(
        children: [
          ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              if (hasHistory && !isMobile)
                ReaderEntryTarget(
                  onOpen: continueRead,
                  builder: (onPressed) => _ActionButton(
                    icon: const Icon(Icons.menu_book),
                    text: 'Continue'.tl,
                    onPressed: onPressed,
                    iconColor: context.useTextColor(Colors.yellow),
                  ),
                ),
              if (!isMobile || hasHistory)
                ReaderEntryTarget(
                  onOpen: (position) => read(null, null, null, position),
                  builder: (onPressed) => _ActionButton(
                    icon: const Icon(Icons.play_circle_outline),
                    text: 'Start'.tl,
                    onPressed: onPressed,
                    iconColor: context.useTextColor(Colors.orange),
                  ),
                ),
              if (!isMobile && !isDownloaded)
                _ActionButton(
                  icon: const Icon(Icons.download),
                  text: 'Download'.tl,
                  onPressed: download,
                  iconColor: context.useTextColor(Colors.cyan),
                ),
              if (data!.isLiked != null)
                _ActionButton(
                  icon: const Icon(Icons.favorite_border),
                  activeIcon: const Icon(Icons.favorite),
                  isActive: isLiked,
                  text:
                      ((data!.likesCount != null)
                              ? (data!.likesCount! + (isLiked ? 1 : 0))
                              : (isLiked ? 'Liked'.tl : 'Like'.tl))
                          .toString(),
                  isLoading: isLiking,
                  onPressed: likeOrUnlike,
                  iconColor: context.useTextColor(Colors.red),
                ),
              if (comicSource.favoriteData != null)
                if (showIndicator)
                  FavoriteHotWindowActionButton(
                    isLoading: isFavoriting,
                    onFavorite: toggleFavorite,
                    onFavoriteLongPress: openFavPanel,
                    indicator: indicator,
                    // 007 retired the manual hot window: the right segment is a
                    // read-only indicator, so no action is wired here.  There is
                    // deliberately no call site that passes a callback.
                  )
                else
                  _ActionButton(
                    icon: const Icon(Icons.bookmark_outline_outlined),
                    activeIcon: const Icon(Icons.bookmark),
                    isActive: isFavorite,
                    isLoading: isFavoriting,
                    text: 'Favorite'.tl,
                    onPressed: toggleFavorite,
                    onLongPress: openFavPanel,
                    iconColor: context.useTextColor(Colors.purple),
                  ),
              if (comicSource.commentsLoader != null)
                _ActionButton(
                  icon: const Icon(Icons.comment),
                  text: (comic.commentCount ?? 'Comments'.tl).toString(),
                  onPressed: showComments,
                  iconColor: context.useTextColor(Colors.green),
                ),
              _ActionButton(
                icon: const Icon(Icons.share),
                text: 'Share'.tl,
                onPressed: share,
                iconColor: context.useTextColor(Colors.blue),
              ),
            ],
          ).fixHeight(48),
          if (isMobile)
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: download,
                    child: Text("Download".tl),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ReaderEntryTarget(
                    onOpen: hasHistory
                        ? continueRead
                        : (position) => read(null, null, null, position),
                    builder: (onPressed) => FilledButton(
                      onPressed: onPressed,
                      child: Text((hasHistory ? 'Continue' : 'Read').tl),
                    ),
                  ),
                ),
              ],
            ).paddingHorizontal(16).paddingVertical(8),
          if (history != null)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: context.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history, color: context.useTextColor(Colors.teal)),
                  const SizedBox(width: 8),
                  Builder(
                    builder: (context) {
                      bool haveChapter = comic.chapters != null;
                      var page = history!.page;
                      var ep = history!.ep;
                      var group = history!.group;
                      String text;
                      if (haveChapter) {
                        var epName = "E$ep";
                        String? groupName;
                        try {
                          if (group == null) {
                            epName = comic.chapters!.titles.elementAt(
                              math.min(ep - 1, comic.chapters!.length - 1),
                            );
                          } else {
                            groupName = comic.chapters!.groups.elementAt(
                              group - 1,
                            );
                            epName = comic.chapters!
                                .getGroupByIndex(group - 1)
                                .values
                                .elementAt(ep - 1);
                          }
                        } catch (e) {
                          // ignore
                        }
                        text = groupName == null
                            ? "${"Last Reading".tl}: $epName P$page"
                            : "${"Last Reading".tl}: $groupName $epName P$page";
                      } else {
                        text = "${"Last Reading".tl}: P$page";
                      }
                      return Text(text);
                    },
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ).toAlign(Alignment.centerLeft),
          const Divider(),
        ],
      ).paddingTop(16),
      loading: false,
    );
  }

  Widget buildDescription({required bool loading}) {
    if (loading) {
      return _detailSection(
        Column(
          children: [
            ListTile(title: Text('Description'.tl)),
            const SkeletonSweep(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBlock(width: double.infinity, height: 12),
                  SizedBox(height: 8),
                  FractionallySizedBox(
                    widthFactor: .88,
                    child: SkeletonBlock(height: 12),
                  ),
                  SizedBox(height: 8),
                  FractionallySizedBox(
                    widthFactor: .67,
                    child: SkeletonBlock(height: 12),
                  ),
                ],
              ),
            ).paddingHorizontal(16),
            const SizedBox(height: 16),
            const Divider(),
          ],
        ),
        loading: true,
      );
    }
    if (comic.description == null || comic.description!.trim().isEmpty) {
      return _detailSection(const SizedBox.shrink(), loading: false);
    }
    return _detailSection(
      Column(
        children: [
          ListTile(title: Text("Description".tl)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SelectableText(comic.description!).fixWidth(double.infinity),
          ),
          const SizedBox(height: 16),
          const Divider(),
        ],
      ),
      loading: false,
    );
  }

  Widget buildInfo({required bool loading}) {
    if (loading) {
      return _detailSection(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(title: Text('Information'.tl)),
            SkeletonSweep(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final widths in const [
                    [54.0, 66.0, 83.0],
                    [54.0, 97.0],
                    [54.0, 58.0, 70.0, 84.0, 64.0, 92.0, 56.0, 76.0],
                    [54.0, 68.0, 92.0, 61.0],
                  ])
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final (index, width) in widths.indexed)
                          SkeletonBlock(
                            width: width,
                            height: 30,
                            radius: 12,
                            emphasized: index == 0,
                          ),
                      ],
                    ).paddingBottom(8),
                ],
              ),
            ).paddingHorizontal(16),
            const SizedBox(height: 12),
            const Divider(),
          ],
        ),
        loading: true,
      );
    }
    if (comic.tags.isEmpty &&
        comic.uploader == null &&
        comic.uploadTime == null &&
        comic.uploadTime == null &&
        comic.maxPage == null) {
      return _detailSection(const SizedBox.shrink(), loading: false);
    }

    int i = 0;

    Widget buildTag({
      required String text,
      VoidCallback? onTap,
      bool isTitle = false,
      ComicAuthorCopyResolution? authorCopyResolution,
    }) {
      Color color;
      if (isTitle) {
        const colors = [
          Colors.blue,
          Colors.cyan,
          Colors.red,
          Colors.pink,
          Colors.purple,
          Colors.indigo,
          Colors.teal,
          Colors.green,
          Colors.lime,
          Colors.yellow,
        ];
        color = context.useBackgroundColor(colors[(i++) % (colors.length)]);
      } else {
        color = context.colorScheme.surfaceContainerLow;
      }

      final borderRadius = BorderRadius.circular(12);

      const padding = EdgeInsets.symmetric(horizontal: 16, vertical: 6);

      if (onTap != null) {
        return Material(
          color: color,
          borderRadius: borderRadius,
          child: ComicAuthorCopyTarget(
            text: text,
            resolution: authorCopyResolution,
            onTap: onTap,
            borderRadius: borderRadius,
            child: Text(text).padding(padding),
          ),
        );
      } else {
        return Container(
          decoration: BoxDecoration(color: color, borderRadius: borderRadius),
          child: Text(text).padding(padding),
        );
      }
    }

    String formatTime(String time) {
      if (int.tryParse(time) != null) {
        var t = int.tryParse(time);
        if (t! > 1000000000000) {
          return DateTime.fromMillisecondsSinceEpoch(
            t,
          ).toString().substring(0, 19);
        } else {
          return DateTime.fromMillisecondsSinceEpoch(
            t * 1000,
          ).toString().substring(0, 19);
        }
      }
      if (time.contains('T') || time.contains('Z')) {
        var t = DateTime.parse(time);
        return t.toString().substring(0, 19);
      }
      return time;
    }

    Widget buildWrap({required List<Widget> children}) {
      return Wrap(
        runSpacing: 8,
        spacing: 8,
        children: children,
      ).paddingHorizontal(16).paddingBottom(8);
    }

    bool enableTranslation =
        App.locale.languageCode == 'zh' && comicSource.enableTagsTranslate;

    return _detailSection(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(title: Text("Information".tl)),
          if (comic.stars != null)
            Row(
              children: [
                StarRating(value: comic.stars!, size: 24, onTap: starRating),
                const SizedBox(width: 8),
                Text(comic.stars!.toStringAsFixed(2)),
              ],
            ).paddingLeft(16).paddingVertical(8),
          for (var e in comic.tags.entries)
            buildWrap(
              children: [
                if (e.value.isNotEmpty)
                  buildTag(text: e.key.ts(comicSource.key), isTitle: true),
                for (var tag in e.value)
                  Builder(
                    builder: (context) {
                      final text = enableTranslation
                          ? TagsTranslation.translationTagWithNamespace(
                              tag,
                              e.key.toLowerCase(),
                            )
                          : tag;
                      return buildTag(
                        text: text,
                        onTap: () => onTapTag(tag, e.key),
                        authorCopyResolution: _isAuthorNamespace(e.key)
                            ? resolveComicAuthorCopyCandidates(text)
                            : null,
                      );
                    },
                  ),
              ],
            ),
          if (comic.uploader != null)
            buildWrap(
              children: [
                buildTag(text: 'Uploader'.tl, isTitle: true),
                buildTag(text: comic.uploader!),
              ],
            ),
          if (comic.uploadTime != null)
            buildWrap(
              children: [
                buildTag(text: 'Upload Time'.tl, isTitle: true),
                buildTag(text: formatTime(comic.uploadTime!)),
              ],
            ),
          if (comic.updateTime != null)
            buildWrap(
              children: [
                buildTag(text: 'Update Time'.tl, isTitle: true),
                buildTag(text: formatTime(comic.updateTime!)),
              ],
            ),
          if (comic.maxPage != null)
            buildWrap(
              children: [
                buildTag(text: 'Pages'.tl, isTitle: true),
                buildTag(text: comic.maxPage.toString()),
              ],
            ),
          const SizedBox(height: 12),
          const Divider(),
        ],
      ),
      loading: false,
    );
  }

  Widget buildChapters() {
    if (comic.chapters == null) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return _ComicChapters(
      history: history,
      groupedMode: comic.chapters!.isGrouped,
    );
  }

  Widget buildThumbnails() {
    if (comic.thumbnails == null && comicSource.loadComicThumbnail == null) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return const _ComicThumbnails();
  }

  Widget buildRecommend() {
    if (comic.recommend == null || comic.recommend!.isEmpty) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(child: ListTile(title: Text("Related".tl))),
        SliverGridComics(comics: comic.recommend!),
      ],
    );
  }

  Widget buildComments() {
    if (comic.comments == null || comic.comments!.isEmpty) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return _CommentsPart(comments: comic.comments!, showMore: showComments);
  }

  void _viewCover(BuildContext context) {
    final imageProvider = CachedImageProvider(
      _comicCoverUrl,
      sourceKey: comic.sourceKey,
      cid: comic.id,
    );

    context.to(
      () => _CoverViewer(
        imageProvider: imageProvider,
        title: comic.title,
        heroTag: "cover${widget.heroID}",
      ),
    );
  }

  void _saveCover(BuildContext context) async {
    try {
      final imageProvider = CachedImageProvider(
        _comicCoverUrl,
        sourceKey: comic.sourceKey,
        cid: comic.id,
      );

      final imageStream = imageProvider.resolve(const ImageConfiguration());
      final completer = Completer<Uint8List>();

      imageStream.addListener(
        ImageStreamListener((ImageInfo info, bool _) async {
          final byteData = await info.image.toByteData(
            format: ImageByteFormat.png,
          );
          if (byteData != null) {
            completer.complete(byteData.buffer.asUint8List());
          }
        }),
      );

      final data = await completer.future;
      final fileType = detectFileType(data);
      await saveFile(filename: "cover${fileType.ext}", data: data);
    } catch (e) {
      if (context.mounted) {
        context.showMessage(message: "Error".tl);
      }
    }
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.text,
    required this.onPressed,
    this.activeIcon,
    this.isActive,
    this.isLoading,
    this.iconColor,
    this.onLongPress,
  });

  final Widget icon;

  final Widget? activeIcon;

  final bool? isActive;

  final String text;

  final void Function() onPressed;

  final bool? isLoading;

  final Color? iconColor;

  final void Function()? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: context.colorScheme.outlineVariant,
          width: 0.6,
        ),
      ),
      child: InkWell(
        onTap: () {
          if (!(isLoading ?? false)) {
            onPressed();
          }
        },
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(18),
        child: IconTheme.merge(
          data: IconThemeData(size: 20, color: iconColor),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLoading ?? false)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                )
              else
                (isActive ?? false) ? (activeIcon ?? icon) : icon,
              const SizedBox(width: 8),
              Text(text),
            ],
          ).paddingHorizontal(16),
        ),
      ),
    );
  }
}

class _SelectDownloadChapter extends StatefulWidget {
  const _SelectDownloadChapter(this.eps, this.finishSelect, this.downloadedEps);

  final List<String> eps;
  final void Function(List<int>) finishSelect;
  final List<int> downloadedEps;

  @override
  State<_SelectDownloadChapter> createState() => _SelectDownloadChapterState();
}

class _SelectDownloadChapterState extends State<_SelectDownloadChapter> {
  List<int> selected = [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Download".tl),
        backgroundColor: context.colorScheme.surfaceContainerLow,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: widget.eps.length,
              itemBuilder: (context, i) {
                return CheckboxListTile(
                  title: Text(widget.eps[i]),
                  value:
                      selected.contains(i) || widget.downloadedEps.contains(i),
                  onChanged: widget.downloadedEps.contains(i)
                      ? null
                      : (v) {
                          setState(() {
                            if (selected.contains(i)) {
                              selected.remove(i);
                            } else {
                              selected.add(i);
                            }
                          });
                        },
                );
              },
            ),
          ),
          Container(
            height: 50,
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: context.colorScheme.outlineVariant),
              ),
            ),
            child: Row(
              children: [
                const SizedBox(width: 16),
                Expanded(
                  child: TextButton(
                    onPressed: () {
                      var res = <int>[];
                      for (int i = 0; i < widget.eps.length; i++) {
                        if (!widget.downloadedEps.contains(i)) {
                          res.add(i);
                        }
                      }
                      widget.finishSelect(res);
                      context.pop();
                    },
                    child: Text("Download All".tl),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    onPressed: selected.isEmpty
                        ? null
                        : () {
                            widget.finishSelect(selected);
                            context.pop();
                          },
                    child: Text("Download Selected".tl),
                  ),
                ),
                const SizedBox(width: 16),
              ],
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}
