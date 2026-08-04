import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/download.dart';
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
        .toList();
  }

  @override
  void initState() {
    final stored = appdata.implicitData['favoriteFolder'];
    if (stored is Map && stored['sourceKey'] is String) {
      _selectedSource = stored['sourceKey'] as String;
    }
    super.initState();
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
        Expanded(
          child: selected == null
              ? const _NoFavoriteSource()
              : NetworkFavoritePage(data: selected),
        ),
      ],
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
    if (!data.multiFolder) {
      return _CachedFavoriteFolderPage(
        key: ValueKey(data.key),
        data: data,
        folder: NetworkFavoriteFolderRef(
          sourceKey: data.key,
          folderId: '',
          title: data.title,
        ),
      );
    }
    return _RemoteFolderList(key: ValueKey(data.key), data: data);
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
    final result = await NetworkFavoriteCacheManager().refreshFolders(
      widget.data,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = result.errorMessage;
      if (result.success) _folders = result.data;
    });
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
          if (widget.data.addFolder != null && source?.isLogged == true)
            IconButton(
              icon: const Icon(Icons.create_new_folder),
              onPressed: _createFolder,
            ),
        ],
      ),
      body: _folders.isEmpty
          ? Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : Text(_error ?? 'No folders available'.tl),
            )
          : ListView.builder(
              itemCount: _folders.length,
              itemBuilder: (context, index) {
                final folder = _folders[index];
                return ListTile(
                  leading: const Icon(Icons.folder),
                  title: Text(folder.title ?? ''),
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
  final _comicListKey = GlobalKey<ComicListState>();
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  String _readFilter = 'all';
  List<FavoriteItem>? _searchResults;
  bool _fullCacheRunning = false;
  bool _searchExpanded = false;

  bool get _usesPage => widget.data.loadComic != null;

  bool get _isSearching => _searchController.text.trim().isNotEmpty;

  NetworkFavoriteCacheManager get _cache => NetworkFavoriteCacheManager();

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onFilterChanged);
    _cache.addListener(_onCacheChanged);
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_onFilterChanged)
      ..dispose();
    _searchFocusNode.dispose();
    _cache.removeListener(_onCacheChanged);
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
    _updateSearchResults();
    final first = _usesPage
        ? _cache.getCachedPage(widget.folder, 1)
        : _cache.getCachedNextPage(widget.folder, null);
    if (first != null && first.updatedAt.millisecondsSinceEpoch == 0) {
      _refresh();
    } else if (first == null) {
      final data = _comicListKey.currentState?.state['data'];
      if (data is Map && data.isNotEmpty) {
        _comicListKey.currentState?.refresh();
      }
    }
  }

  void _updateSearchResults() {
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
      invalidateFollowing: !_usesPage,
    );
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    final result = _usesPage
        ? await _cache.refreshPage(widget.data, widget.folder, 1)
        : await _cache.refreshNextPage(widget.data, widget.folder, null);
    if (result.success) {
      _replacePage(result.data);
    } else {
      if (mounted) context.showMessage(message: result.errorMessage!);
    }
  }

  Future<void> _cacheAllFavorites() async {
    final source = ComicSource.find(widget.data.key);
    if (source?.isLogged != true ||
        (widget.data.loadComic == null && widget.data.loadNext == null) ||
        _fullCacheRunning) {
      return;
    }

    var canceled = false;
    var completed = false;
    String? error;
    setState(() => _fullCacheRunning = true);
    final loading = showLoadingDialog(
      App.rootContext,
      withProgress: true,
      barrierDismissible: false,
      allowCancel: true,
      cancelButtonText: 'Cancel'.tl,
      message: 'Caching favorites...'.tl,
      onCancel: () => canceled = true,
    );
    try {
      await for (final progress in _cache.cacheAllPages(
        widget.data,
        widget.folder,
        isCanceled: () => canceled,
      )) {
        final totalPages = progress.totalPages;
        if (totalPages != null) {
          loading.setProgress(
            totalPages == 0 ? 1 : progress.pagesCached / totalPages,
          );
          loading.setMessage(
            'Caching favorites: @page / @total pages (@count comics)'.tlParams({
              'page': progress.pagesCached,
              'total': totalPages,
              'count': progress.comicsCached,
            }),
          );
        } else {
          loading.setProgress(null);
          loading.setMessage(
            'Caching favorites: @page pages (@count comics)'.tlParams({
              'page': progress.pagesCached,
              'count': progress.comicsCached,
            }),
          );
        }
        completed = progress.isComplete;
        canceled = canceled || progress.isCanceled;
        error ??= progress.errorMessage;
      }
    } finally {
      loading.close();
      if (mounted) {
        setState(() {
          _fullCacheRunning = false;
          if (_isSearching) {
            _searchResults = _cache.searchCachedComics(
              widget.folder,
              _searchController.text,
            );
          }
        });
      }
    }
    if (!mounted || canceled) return;
    if (error != null) {
      context.showMessage(message: error);
    } else if (completed) {
      context.showMessage(message: 'Favorites cached'.tl);
    }
  }

  Future<void> _downloadCached() async {
    final comics = <FavoriteItem>[];
    String? token;
    for (var page = 1; ; page++) {
      final cached = _usesPage
          ? _cache.getCachedPage(widget.folder, page)
          : _cache.getCachedNextPage(widget.folder, token);
      if (cached == null) break;
      comics.addAll(cached.comics);
      if (_usesPage) {
        if (cached.maxPage != null && page >= cached.maxPage!) break;
      } else {
        if (cached.nextToken == null) break;
        token = cached.nextToken;
      }
    }
    final source = ComicSource.find(widget.data.key);
    if (source == null || comics.isEmpty) return;
    var count = 0;
    for (final comic in comics) {
      if (!LocalManager().isDownloading(comic.id, comic.type) &&
          !LocalManager().isDownloaded(comic.id, comic.type)) {
        LocalManager().addTask(
          ImagesDownloadTask(
            source: source,
            comicId: comic.id,
            comicTitle: comic.title,
          ),
        );
        count++;
      }
    }
    if (mounted && count > 0) {
      context.showMessage(
        message: 'Added @c comics to download queue.'.tlParams({'c': count}),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.folder.title ?? widget.data.title;
    final source = ComicSource.find(widget.data.key);
    final canCacheAll =
        source?.isLogged == true &&
        (widget.data.loadComic != null || widget.data.loadNext != null) &&
        !_fullCacheRunning;
    final isSearching = _isSearching;
    final searchResults = isSearching
        ? (_searchResults ??
              _cache.searchCachedComics(widget.folder, _searchController.text))
        : null;
    final cachedComicCount = _cache.countCachedComics(widget.folder);
    return ComicList(
      key: _comicListKey,
      leadingSliver: SliverMainAxisGroup(
        slivers: [
          SliverAppbar(
            title: Text(title),
            actions: [
              IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
              IconButton(
                tooltip: 'Cache all favorites'.tl,
                icon: _fullCacheRunning
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_download_outlined),
                onPressed: canCacheAll ? _cacheAllFavorites : null,
              ),
              MenuButton(
                entries: [
                  MenuEntry(
                    icon: Icons.download,
                    text: 'Download'.tl,
                    onClick: _downloadCached,
                  ),
                ],
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
            ],
          ),
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
                    PopupMenuButton<String>(
                      tooltip: 'Read filter'.tl,
                      icon: const Icon(Icons.filter_list),
                      onSelected: (value) =>
                          setState(() => _readFilter = value),
                      itemBuilder: (context) => [
                        CheckedPopupMenuItem(
                          value: 'all',
                          checked: _readFilter == 'all',
                          child: Text('All'.tl),
                        ),
                        CheckedPopupMenuItem(
                          value: 'read',
                          checked: _readFilter == 'read',
                          child: Text('Read'.tl),
                        ),
                        CheckedPopupMenuItem(
                          value: 'unread',
                          checked: _readFilter == 'unread',
                          child: Text('Unread'.tl),
                        ),
                      ],
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
      errorLeading: Appbar(title: Text(title)),
      staticComics: searchResults,
      loadPage: widget.data.loadComic == null
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
      loadNext: widget.data.loadNext == null
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
      comicFilter: (comic) {
        if (_readFilter == 'all') return true;
        final read =
            HistoryManager().find(
              comic.id,
              ComicType.fromKey(comic.sourceKey),
            ) !=
            null;
        return _readFilter == 'read' ? read : !read;
      },
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
  }
}
