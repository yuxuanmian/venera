import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';
import 'package:venera/pages/favorites/favorite_updates_page.dart';
import 'package:venera/utils/translations.dart';

const _favoriteSidebarWidth = 256.0;

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  String? _selectedSource;

  List<FavoriteData> get _sources {
    final enabled = List<String>.from(appdata.settings['favorites'] as List);
    return enabled
        .map(getFavoriteDataOrNull)
        .whereType<FavoriteData>()
        .where((source) => isSourceEnabled(source.key))
        .toList();
  }

  @override
  void initState() {
    final stored = appdata.implicitData['favoriteFolder'];
    if (stored is Map && stored['sourceKey'] is String) {
      _selectedSource = stored['sourceKey'] as String;
    }
    appdata.settings.addListener(_onSettingsChanged);
    ComicSourceManager().addListener(_onSettingsChanged);
    super.initState();
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_onSettingsChanged);
    ComicSourceManager().removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _select(String sourceKey) {
    setState(() => _selectedSource = sourceKey);
    appdata.implicitData['favoriteFolder'] = {'sourceKey': sourceKey};
    appdata.writeImplicitData();
  }

  @override
  Widget build(BuildContext context) {
    final sources = _sources;
    if (_selectedSource == null ||
        !sources.any((source) => source.key == _selectedSource)) {
      _selectedSource = sources.firstOrNull?.key;
    }
    final selected = _selectedSource == null
        ? null
        : getFavoriteDataOrNull(_selectedSource!);
    final content = selected == null
        ? const _NoFavoriteSource()
        : NetworkFavoritePage(data: selected);
    if (context.width < changePoint) {
      return Column(
        children: [
          _FavoriteSourcePicker(
            sources: sources,
            selected: _selectedSource,
            onSelect: _select,
          ),
          Expanded(child: content),
        ],
      );
    }
    return Row(
      children: [
        SizedBox(
          width: _favoriteSidebarWidth,
          child: _FavoriteSources(
            sources: sources,
            selected: _selectedSource,
            onSelect: _select,
          ),
        ),
        Expanded(child: content),
      ],
    );
  }
}

class _FavoriteSourcePicker extends StatelessWidget {
  const _FavoriteSourcePicker({
    required this.sources,
    required this.selected,
    required this.onSelect,
  });

  final List<FavoriteData> sources;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        height: 56,
        width: double.infinity,
        child: sources.isEmpty
            ? Center(child: Text('Unselected'.tl))
            : ListView.separated(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                scrollDirection: Axis.horizontal,
                itemCount: sources.length,
                separatorBuilder: (context, index) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final data = sources[index];
                  return ChoiceChip(
                    label: Text(data.title),
                    selected: data.key == selected,
                    onSelected: (_) => onSelect(data.key),
                  );
                },
              ),
      ),
    );
  }
}

class _FavoriteSources extends StatelessWidget {
  const _FavoriteSources({
    required this.sources,
    required this.selected,
    required this.onSelect,
  });

  final List<FavoriteData> sources;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Material(
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.only(top: context.padding.top + 16, bottom: 8),
            child: Row(
              children: [
                const SizedBox(width: 16),
                Icon(Icons.cloud, color: context.colorScheme.secondary),
                const SizedBox(width: 12),
                Text('Network'.tl, style: ts.s16),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: sources.length,
              itemBuilder: (context, index) {
                final data = sources[index];
                final active = data.key == selected;
                return ListTile(
                  selected: active,
                  title: Text(data.title),
                  onTap: () => onSelect(data.key),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _NoFavoriteSource extends StatelessWidget {
  const _NoFavoriteSource();

  @override
  Widget build(BuildContext context) {
    return Center(child: Text('Unselected'.tl));
  }
}

class NetworkFavoritePage extends StatelessWidget {
  const NetworkFavoritePage({required this.data, super.key});

  final FavoriteData data;

  @override
  Widget build(BuildContext context) {
    return !data.multiFolder
        ? _CachedFavoriteFolderPage(
            key: ValueKey(data.key),
            data: data,
            folder: NetworkFavoriteFolderRef(
              sourceKey: data.key,
              folderId: '',
              title: data.title,
            ),
          )
        : _RemoteFolderList(key: ValueKey(data.key), data: data);
  }
}

class _RemoteFolderList extends StatefulWidget {
  const _RemoteFolderList({required this.data, super.key});

  final FavoriteData data;

  @override
  State<_RemoteFolderList> createState() => _RemoteFolderListState();
}

class _RemoteFolderListState extends State<_RemoteFolderList> {
  late List<NetworkFavoriteFolder> _folders;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _folders = NetworkFavoriteCacheManager().getCachedFolders(widget.data.key);
    NetworkFavoriteCacheManager().addListener(_onCacheChanged);
    _refresh();
  }

  @override
  void dispose() {
    NetworkFavoriteCacheManager().removeListener(_onCacheChanged);
    super.dispose();
  }

  void _onCacheChanged() {
    if (!mounted) return;
    setState(() {
      _folders = NetworkFavoriteCacheManager().getCachedFolders(
        widget.data.key,
      );
    });
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final result = await NetworkFavoriteCacheManager().refreshFolders(
        widget.data,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = result.errorMessage;
        if (result.success) _folders = result.data;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: 'Create a folder'.tl,
        content: TextField(controller: controller).paddingHorizontal(16),
        actions: [
          Button.filled(
            onPressed: () async {
              final result = await NetworkFavoriteCacheManager()
                  .createRemoteFolder(widget.data, controller.text);
              if (!context.mounted) return;
              if (result.success) {
                context.pop();
                await _refresh();
              } else {
                context.showMessage(message: result.errorMessage!);
              }
            },
            child: Text('Confirm'.tl),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final source = ComicSource.find(widget.data.key);
    return Scaffold(
      appBar: Appbar(
        title: Text(widget.data.title),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
          FavoriteUpdatesButton(sourceKey: widget.data.key),
          if (widget.data.addFolder != null && source?.isLogged == true)
            IconButton(
              icon: const Icon(Icons.create_new_folder),
              onPressed: _createFolder,
            ),
        ],
      ),
      body: _folders.isEmpty
          ? _buildEmptyFolders()
          : ListView.builder(
              itemCount: _folders.length,
              itemBuilder: (context, index) {
                final folder = _folders[index];
                return ListTile(
                  leading: const Icon(Icons.folder),
                  title: Text(favoriteFolderDisplayTitle(folder.title ?? '')),
                  trailing:
                      widget.data.deleteFolder == null ||
                          source?.isLogged != true
                      ? const Icon(Icons.arrow_right)
                      : IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            final result = await NetworkFavoriteCacheManager()
                                .deleteRemoteFolder(widget.data, folder);
                            if (!context.mounted) return;
                            if (result.error) {
                              context.showMessage(
                                message: result.errorMessage!,
                              );
                            }
                          },
                        ),
                  onTap: () => context.to(
                    () => _CachedFavoriteFolderPage(
                      data: widget.data,
                      folder: folder,
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _buildEmptyFolders() {
    if (_loading) {
      return ListView(
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (final width in const [106.0, 150.0, 82.0, 122.0, 96.0])
            SkeletonSweep(
              child: ListTile(
                leading: const SkeletonBlock(width: 24, height: 21),
                title: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: SkeletonBlock(width: width, height: 13),
                ),
                trailing: const SkeletonBlock(width: 18, height: 18),
              ),
            ),
        ],
      );
    }
    if (_error case final error?) {
      return NetworkError(withAppbar: false, message: error, retry: _refresh);
    }
    return Center(child: Text('No folders available'.tl));
  }
}

class _CachedFavoriteFolderPage extends StatefulWidget {
  const _CachedFavoriteFolderPage({
    required this.data,
    required this.folder,
    super.key,
  });

  final FavoriteData data;
  final NetworkFavoriteFolderRef folder;

  @override
  State<_CachedFavoriteFolderPage> createState() =>
      _CachedFavoriteFolderPageState();
}

class _CachedFavoriteFolderPageState extends State<_CachedFavoriteFolderPage> {
  GlobalKey<ComicListState> _comicListKey = GlobalKey<ComicListState>();
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  List<Comic>? _searchResults;
  FavoriteFullCacheProgress? _syncProgress;
  bool _searchExpanded = false;
  late int _cacheGeneration;
  FavoriteCollectionVisit? _visit;
  Object? _visitStorageKey;
  bool _routeVisible = false;
  bool _showingUpdates = false;
  Set<String> _detectedUpdates = const {};
  int _updateRequest = 0;

  bool get _usesPage => widget.data.loadComic != null;

  bool get _canSyncAll =>
      widget.data.usesCollectionCache ||
      (ComicSource.find(widget.data.key)?.isLogged == true &&
          (widget.data.loadComic != null || widget.data.loadNext != null));

  bool get _isSearching => _searchController.text.trim().isNotEmpty;

  NetworkFavoriteCacheManager get _cache => NetworkFavoriteCacheManager();

  @override
  void initState() {
    super.initState();
    _cacheGeneration = _cache.cacheGeneration;
    _searchController.addListener(_onFilterChanged);
    _cache.addListener(_onCacheChanged);
    _cache.favoriteCoverChanges.addListener(_onFavoriteCoverChanged);
    _cache.collections.mutations.addListener(_onCollectionMutation);
    judgmentService.unreadRevision.addListener(_onUnreadChanged);
    _openCollection();
  }

  void _openCollection({bool restart = false, bool usePublished = false}) {
    final previous = _visit;
    if (!widget.data.usesCollectionCache) {
      _visit = null;
    } else {
      _visit = _cache.collections.open(
        widget.data,
        widget.folder,
        restart: restart,
        usePublished: usePublished,
      );
    }
    if (previous != null && previous != _visit) {
      _cache.collections.hide(previous);
    }
    if (previous != _visit && !usePublished) {
      _visitStorageKey = _visit?.pageStorageKey;
    }
    if (_visit case final visit? when _routeVisible || _showingUpdates) {
      _cache.collections.show(visit);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible =
        (ModalRoute.isCurrentOf(context) ?? true) &&
        TickerMode.valuesOf(context).enabled;
    if (_routeVisible == visible) return;
    _routeVisible = visible;
    if (visible) {
      if (!_showingUpdates || _visit?.isCurrent == false) _openCollection();
      unawaited(_refreshDetectedUpdates());
    } else if (_visit case final visit? when !_showingUpdates) {
      _cache.collections.hide(visit);
    }
  }

  void _onUpdatesRouteChanged(bool showing) {
    if (!mounted) return;
    _showingUpdates = showing;
    if (!showing && !_routeVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_showingUpdates && !_routeVisible && _visit != null) {
          _cache.collections.hide(_visit!);
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant _CachedFavoriteFolderPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data || oldWidget.folder != widget.folder) {
      _openCollection();
    }
    if (oldWidget.data.key != widget.data.key) {
      _detectedUpdates = const {};
      unawaited(_refreshDetectedUpdates());
    }
  }

  void _onUnreadChanged() => unawaited(_refreshDetectedUpdates());

  Future<void> _refreshDetectedUpdates() async {
    final sourceKey = widget.data.key;
    if (!_routeVisible || sourceDeclaresUnreadSignal(sourceKey)) return;
    final request = ++_updateRequest;
    try {
      final ids = await judgmentStateRepository.readUnreadComicIds(sourceKey);
      if (mounted &&
          request == _updateRequest &&
          sourceKey == widget.data.key &&
          !setEquals(ids, _detectedUpdates)) {
        setState(() => _detectedUpdates = ids);
      }
    } catch (_) {
      // The update indicator is optional when the judgment store is unavailable.
    }
  }

  void _onCollectionMutation() {
    final visit = _visit;
    if (!mounted || visit == null) return;
    if (_routeVisible && !visit.isCurrent) {
      _openCollection(restart: true);
      _comicListKey = GlobalKey<ComicListState>();
    }
    if (_routeVisible && identical(visit, _visit) && visit.takeCacheWarning()) {
      _showCacheWarning();
    }
    setState(() {});
  }

  void _showCacheWarning() {
    showToast(
      message: 'Could not cache favorites. Try again later.'.tl,
      context: context,
      icon: const Icon(Icons.warning_amber_rounded),
    );
  }

  @override
  void dispose() {
    if (_visit case final visit?) _cache.collections.hide(visit);
    _cache.collections.mutations.removeListener(_onCollectionMutation);
    _searchController
      ..removeListener(_onFilterChanged)
      ..dispose();
    _searchFocusNode.dispose();
    _cache.removeListener(_onCacheChanged);
    _cache.favoriteCoverChanges.removeListener(_onFavoriteCoverChanged);
    judgmentService.unreadRevision.removeListener(_onUnreadChanged);
    super.dispose();
  }

  void _onFilterChanged() {
    _updateSearchResults();
    _comicListKey.currentState?.refreshFilter();
  }

  void _toggleSearch() {
    if (_searchExpanded) {
      _searchFocusNode.unfocus();
      _searchController.clear();
      setState(() => _searchExpanded = false);
    } else {
      setState(() => _searchExpanded = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocusNode.requestFocus();
      });
    }
  }

  void _onCacheChanged() {
    if (!mounted) return;
    final generation = _cache.cacheGeneration;
    if (generation != _cacheGeneration || _visit?.isCurrent == false) {
      _cacheGeneration = generation;
      _openCollection(restart: true);
      _comicListKey = GlobalKey<ComicListState>();
      _searchResults = null;
      _detectedUpdates = const {};
      _onUnreadChanged();
      setState(() {});
      return;
    }
    if (_visit != null && _searchResults != null) return;
    _updateSearchResults();
  }

  void _onFavoriteCoverChanged() {
    final change = _cache.favoriteCoverChanges.value;
    if (!mounted ||
        change == null ||
        change.sourceKey != widget.folder.sourceKey) {
      return;
    }
    final listState = _comicListKey.currentState;
    if (listState == null) return;
    if (_visit != null) {
      listState.updateComicCovers(change.covers);
      if (_searchResults case final results?) {
        setState(() {
          _searchResults = [
            for (final item in results)
              if (change.covers[item.id] case final cover?
                  when cover != item.cover)
                Comic.fromJson({
                  ...item.toJson(),
                  'cover': cover,
                }, item.sourceKey)
              else
                item,
          ];
        });
      }
      return;
    }
    final changedIds = change.covers.keys.toSet();
    for (final page in listState.loadedPagesContainingAnyComicIds(changedIds)) {
      final cached = _cache.getCachedPageByIndex(widget.folder, page);
      if (cached != null) {
        listState.updatePageComics(cached.pageIndex, cached.comics);
      }
    }
    _updateSearchResults();
  }

  void _updateSearchResults() {
    if (_visit != null &&
        !_cache.getFullCacheStatus(widget.folder).isComplete) {
      if (mounted) setState(() => _searchResults = null);
      return;
    }
    final results = _isSearching
        ? _cache.searchCachedComics(widget.folder, _searchController.text)
        : null;
    if (mounted) setState(() => _searchResults = results);
  }

  void _replacePage(CachedFavoritePage page) {
    _comicListKey.currentState?.replacePage(
      page.pageIndex,
      page.comics,
      maxPage: page.maxPage,
      nextUrl: page.nextToken,
      isCursor: !_usesPage,
    );
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    if (_canSyncAll) {
      await _syncFavorites();
      return;
    }
    final data = widget.data;
    final folder = widget.folder;
    final epoch = _cache.captureFavoriteSessionEpoch(data.key);
    final listState = _comicListKey.currentState;
    final page = listState?.currentPage ?? 1;
    final requestToken = listState?.currentRequestToken;
    if (!_usesPage &&
        page > 1 &&
        !(listState?.hasCurrentRequestToken ?? false)) {
      return;
    }
    final result = _usesPage
        ? await _cache.refreshPage(data, folder, page)
        : await _cache.refreshNextPage(data, folder, requestToken);
    if (!mounted ||
        widget.folder != folder ||
        !_cache.isFavoriteSessionEpochCurrent(data.key, epoch)) {
      return;
    }
    if (result.success) {
      _replacePage(result.data);
    } else {
      context.showMessage(message: result.errorMessage!);
    }
  }

  Future<void> _syncFavorites() async {
    if (_syncProgress != null) return;
    final data = widget.data;
    final folder = widget.folder;
    final initialScope = data.cacheScope;
    final epoch = _cache.captureFavoriteSessionEpoch(data.key);
    final wasEnabled = isSourceEnabled(data.key);
    bool isCurrent() =>
        _cache.isFavoriteSessionEpochCurrent(data.key, epoch) &&
        data.cacheScope == initialScope &&
        (!wasEnabled ||
            (isSourceEnabled(data.key) &&
                identical(getFavoriteDataOrNull(data.key), data)));
    bool isShowingSyncTarget() =>
        mounted &&
        widget.data == data &&
        widget.folder == folder &&
        isCurrent();

    setState(
      () => _syncProgress = const FavoriteFullCacheProgress(
        pagesCached: 0,
        comicsCached: 0,
      ),
    );
    // A manual sync belongs to the folder, and may continue across navigation.
    // Cache invalidation still cancels work from an old account or cache scope.
    var receivedTerminalProgress = false;
    try {
      await for (final progress in _cache.cacheAllPages(
        data,
        folder,
        isCanceled: () => !isCurrent(),
      )) {
        if (!isShowingSyncTarget()) return;
        if (progress.isComplete ||
            progress.isCanceled ||
            progress.errorMessage != null) {
          receivedTerminalProgress = true;
          setState(() => _syncProgress = null);
          if (progress.isComplete) {
            _useSyncedCollection();
          } else if (_routeVisible && progress.errorMessage != null) {
            _showCacheWarning();
          }
          return;
        }
        setState(() => _syncProgress = progress);
      }
    } catch (_) {
      if (isShowingSyncTarget() && _routeVisible) _showCacheWarning();
    } finally {
      if (mounted && !receivedTerminalProgress) {
        setState(() => _syncProgress = null);
      }
    }
  }

  void _useSyncedCollection() {
    final listState = _comicListKey.currentState;
    final pageCount = _cache.getFullCacheStatus(widget.folder).pageCount;
    final maxPage = pageCount == 0 ? 1 : pageCount;
    setState(() {
      _openCollection(restart: true, usePublished: true);
      if (listState != null && listState.currentPage > maxPage) {
        _visitStorageKey = _visit?.pageStorageKey ?? Object();
        _comicListKey = GlobalKey<ComicListState>();
      } else if (listState != null) {
        final loaded = listState.state['data'] as Map<int, List<Comic>>;
        for (final page in loaded.keys) {
          final cached = _cache.getCachedPageByIndex(widget.folder, page);
          listState.replacePage(
            page,
            cached?.comics ?? const [],
            maxPage: maxPage,
            nextUrl: cached?.nextToken,
            isCursor: !widget.data.usesCollectionCache && !_usesPage,
          );
        }
      }
    });
    _updateSearchResults();
  }

  Future<Res<List<Comic>>> _loadCollectionPage(int page) async {
    var visit = _visit!;
    var result = await visit.loadPage(page);
    while (mounted && _visit != null && !identical(visit, _visit)) {
      visit = _visit!;
      result = await visit.loadPage(page);
    }
    return result;
  }

  Widget _buildSyncProgress(FavoriteFullCacheProgress progress) {
    final total = progress.totalPages;
    final message = progress.pagesCached == 0
        ? 'Syncing favorites...'.tl
        : total == null
        ? 'Caching favorites: @page pages (@count comics)'.tlParams({
            'page': progress.pagesCached,
            'count': progress.comicsCached,
          })
        : 'Caching favorites: @page / @total pages (@count comics)'.tlParams({
            'page': progress.pagesCached,
            'total': total,
            'count': progress.comicsCached,
          });
    return Material(
      child: Column(
        children: [
          LinearProgressIndicator(
            value: total == null
                ? null
                : total == 0
                ? 1
                : (progress.pagesCached / total).clamp(0.0, 1.0),
            semanticsLabel: 'Syncing favorites...'.tl,
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(message, style: ts.s12),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = favoriteFolderDisplayTitle(
      widget.folder.title ?? widget.data.title,
    );
    final updateIds = sourceDeclaresUnreadSignal(widget.data.key)
        ? _cache.collections.readSourceUnreadIds(widget.data.key)
        : _detectedUpdates;
    final isSearching = _isSearching;
    final visit = _visit;
    final preparingSearch =
        visit != null &&
        isSearching &&
        !_cache.getFullCacheStatus(widget.folder).isComplete;
    final searchResults = isSearching
        ? (preparingSearch
                  ? const <Comic>[]
                  : _searchResults ??
                        _cache.searchCachedComics(
                          widget.folder,
                          _searchController.text,
                        ))
              .where((comic) => visit?.wasRemoved(comic.id) != true)
              .toList()
        : null;
    final cachedComicCount = _cache.countCachedComics(widget.folder);
    final actions = [
      IconButton(
        tooltip: _canSyncAll ? 'Sync all favorites'.tl : 'Refresh'.tl,
        icon: const Icon(Icons.refresh),
        onPressed: _syncProgress == null ? _refresh : null,
      ),
      if (!widget.data.multiFolder)
        FavoriteUpdatesButton(
          sourceKey: widget.data.key,
          onRouteChanged: _onUpdatesRouteChanged,
        ),
      IconButton(
        tooltip: _searchExpanded ? 'Close'.tl : 'Search'.tl,
        onPressed: _toggleSearch,
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: Icon(
            _searchExpanded ? Icons.close : Icons.search,
            key: ValueKey(_searchExpanded),
          ),
        ),
      ),
    ];
    final comicList = ComicList(
      key: _comicListKey,
      enablePageStorage: true,
      showLoadingSkeleton: true,
      emptyMessage: 'No favorites in this list'.tl,
      leadingSliver: SliverMainAxisGroup(
        slivers: [
          SliverAppbar(title: Text(title), actions: actions),
          SliverToBoxAdapter(
            child: Column(
              children: [
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: _searchExpanded
                      ? TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            hintText: 'Search cached favorites (@count)'
                                .tlParams({'count': cachedComicCount}),
                          ),
                        ).paddingHorizontal(16).paddingTop(8)
                      : const SizedBox(width: double.infinity),
                ),
                Row(
                  children: [
                    Expanded(
                      child: searchResults != null
                          ? Text(
                              '@count cached favorites found'.tlParams({
                                'count': searchResults.length,
                              }),
                              style: ts.s12,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ).padding(
                  EdgeInsets.fromLTRB(16, _searchExpanded ? 8 : 0, 16, 0),
                ),
              ],
            ),
          ),
        ],
      ),
      errorLeading: Appbar(title: Text(title), actions: actions),
      staticComics: searchResults,
      staticEmptyMessage: preparingSearch
          ? (visit.cacheFailed
                ? 'Could not prepare favorites. Sync all favorites to retry.'.tl
                : 'Preparing favorites for search'.tl)
          : null,
      firstPagePinnedComics: visit?.recent ?? const [],
      onFirstPageShown: visit?.markRecentShown,
      badgeBuilder: visit == null
          ? null
          : (comic) => visit.isRecent(comic.id) ? 'Just added'.tl : null,
      updateBadgeBuilder: (comic) => updateIds.contains(comic.id),
      comicFilter: visit == null
          ? null
          : (comic) => !visit.wasRemoved(comic.id),
      loadPage: visit != null
          ? _loadCollectionPage
          : widget.data.loadComic == null
          ? null
          : (page) async {
              final result = await _cache.loadCachedThenRefreshPage(
                widget.data,
                widget.folder,
                page,
                _replacePage,
              );
              return result.success
                  ? Res<List<Comic>>(
                      result.data.comics,
                      subData: result.data.maxPage,
                    )
                  : Res.error(result.errorMessage!);
            },
      loadNext: visit != null || widget.data.loadNext == null
          ? null
          : (next) async {
              final result = await _cache.loadCachedThenRefreshNextPage(
                widget.data,
                widget.folder,
                next,
                _replacePage,
              );
              return result.success
                  ? Res<List<Comic>>(
                      result.data.comics,
                      subData: result.data.nextToken,
                    )
                  : Res.error(result.errorMessage!);
            },
      // FR-023: the "suspected removed" badge and dimming are gone.  The
      // verdict had no producer left, so every entry would have rendered as
      // un-suspect; keeping the branch would have been dead presentation.
      menuBuilder: (comic) => [
        MenuEntry(
          icon: Icons.delete_outline,
          text: 'Remove'.tl,
          onClick: () async {
            final result = await _cache.changeFavorite(
              data: widget.data,
              folder: widget.folder,
              comicId: comic.id,
              isAdding: false,
              favoriteId: comic.favoriteId,
            );
            if (!mounted) return;
            if (result.success) {
              if (_isSearching) {
                setState(
                  () => _searchResults?.removeWhere(
                    (result) => result.id == comic.id,
                  ),
                );
              } else {
                _comicListKey.currentState?.remove(comic);
              }
            } else {
              context.showMessage(message: result.errorMessage!);
            }
          },
        ),
      ],
    );
    return KeyedSubtree(
      key: PageStorageKey<(String, String, int)>((
        widget.folder.sourceKey,
        widget.folder.folderId,
        _cacheGeneration,
        // Use a separate PageStorage namespace when an explicit opening starts
        // over on page one. Resuming a visit keeps the same key.
      )),
      child: KeyedSubtree(
        key: _visitStorageKey == null ? null : PageStorageKey(_visitStorageKey),
        child: Column(
          children: [
            Expanded(child: comicList),
            if (_syncProgress case final progress?)
              _buildSyncProgress(progress),
          ],
        ),
      ),
    );
  }
}
