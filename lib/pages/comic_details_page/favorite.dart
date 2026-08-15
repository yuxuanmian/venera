part of 'comic_page.dart';

class _FavoritePanel extends StatefulWidget {
  const _FavoritePanel({
    required this.cid,
    required this.source,
    required this.isFavorite,
    required this.onFavorite,
  });

  final String cid;
  final ComicSource source;
  final bool isFavorite;
  final ValueChanged<bool> onFavorite;

  @override
  State<_FavoritePanel> createState() => _FavoritePanelState();
}

class _FavoritePanelState extends State<_FavoritePanel> {
  Map<String, String>? _folders;
  Set<String> _added = {};
  bool _loading = true;
  String? _error;

  FavoriteData get _data => widget.source.favoriteData!;

  @override
  void initState() {
    super.initState();
    _loadFolders();
  }

  Future<void> _loadFolders() async {
    final cache = NetworkFavoriteCacheManager();
    _added = cache.getKnownFolderIds(_data.key, widget.cid);
    if (!_data.multiFolder) {
      _added = _added.contains('') ? {''} : <String>{};
      setState(() => _loading = false);
      return;
    }
    _folders = {
      for (final folder in cache.getCachedFolders(_data.key))
        folder.folderId: folder.title ?? folder.folderId,
    };
    if (_data.loadFolders == null || !widget.source.isLogged) {
      setState(() => _loading = false);
      return;
    }
    final result = await _data.loadFolders!(widget.cid);
    if (!mounted) return;
    if (result.error) {
      setState(() {
        _loading = false;
        // A folder list already in the device cache remains usable for
        // display; only remote mutations are disabled below.
        if (_folders!.isEmpty) _error = result.errorMessage;
      });
      return;
    }
    setState(() {
      _folders = result.data;
      // Only trust the membership list when the source actually returned
      // one; otherwise keep the device-cache value so already-favorited
      // folders do not suddenly show as "Add". An empty report is also
      // ignored when the device cache knows the comic is favorited: some
      // sources report stale membership right after a successful add.
      if (result.subData is List) {
        final list = List<String>.from(result.subData).toSet();
        if (list.isNotEmpty || !cache.isFavoriteKnown(_data.key, widget.cid)) {
          _added = list;
          cache.replaceComicMembership(_data.key, widget.cid, _added);
        }
      }
      cache.cacheFolderSnapshot(_data.key, result.data);
      _loading = false;
    });
  }

  Future<void> _change(String folderId, bool isAdding) async {
    final result = await NetworkFavoriteCacheManager().changeFavorite(
      data: _data,
      folder: NetworkFavoriteFolderRef(
        sourceKey: _data.key,
        folderId: folderId,
      ),
      comicId: widget.cid,
      isAdding: isAdding,
    );
    if (!mounted) return;
    if (result.error) {
      context.showMessage(message: result.errorMessage!);
      return;
    }
    setState(() {
      if (isAdding) {
        _added.add(folderId);
      } else {
        _added.remove(folderId);
      }
    });
    widget.onFavorite(_added.isNotEmpty || (!_data.multiFolder && isAdding));
    if (appdata.settings['autoCloseFavoritePanel'] ?? false) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final canChange = widget.source.isLogged && _data.addOrDelFavorite != null;
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
        appBar: Appbar(title: Text('Favorite'.tl)),
        body: NetworkError(message: _error!),
      );
    }
    if (!_data.multiFolder) {
      final isAdded = widget.isFavorite || _added.isNotEmpty;
      return Scaffold(
        appBar: Appbar(title: Text('Favorite'.tl)),
        body: ListView(
          children: [
            ListTile(
              title: Text('Network Favorites'.tl),
              subtitle: !canChange ? Text('Not login'.tl) : null,
              trailing: canChange
                  ? _FavoriteToggleButton(
                      isAdded: isAdded,
                      onPressed: () => _change('', !isAdded),
                    )
                  : Text('Not login'.tl),
            ),
          ],
        ),
      );
    }
    // Multi-folder sources always render the folder list; each row carries
    // its own favorited state so toggling never jumps between views.
    return Scaffold(
      appBar: Appbar(title: Text('Favorite'.tl)),
      body: ListView(
        children: [
          for (final entry in _folders!.entries)
            ListTile(
              leading: Icon(
                _added.contains(entry.key)
                    ? Icons.folder_special
                    : Icons.folder_outlined,
                color: _added.contains(entry.key)
                    ? context.colorScheme.primary
                    : null,
              ),
              title: Text(
                favoriteFolderDisplayTitle(entry.value),
                style: _added.contains(entry.key)
                    ? ts.withColor(context.colorScheme.primary)
                    : null,
              ),
              subtitle: !canChange ? Text('Not login'.tl) : null,
              trailing: canChange
                  ? _FavoriteToggleButton(
                      isAdded: _added.contains(entry.key),
                      onPressed: () =>
                          _change(entry.key, !_added.contains(entry.key)),
                    )
                  : Text('Not login'.tl),
            ),
        ],
      ),
    );
  }
}

/// Compact favorite toggle used in folder rows: an outline bookmark when the
/// comic is not in the folder, a filled bookmark (with a Material 3 selected
/// background) when it is. Bookmark keeps the same icon language as the
/// favorite button on the details page.
class _FavoriteToggleButton extends StatelessWidget {
  const _FavoriteToggleButton({
    required this.isAdded,
    required this.onPressed,
  });

  final bool isAdded;

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: isAdded ? 'Remove'.tl : 'Add'.tl,
      onPressed: onPressed,
      isSelected: isAdded,
      icon: const Icon(Icons.bookmark_outline),
      selectedIcon: const Icon(Icons.bookmark),
      // M3 gives the selected icon the primary color automatically; the
      // container background makes the favorited state unmistakable.
      style: IconButton.styleFrom(
        backgroundColor: isAdded ? context.colorScheme.primaryContainer : null,
      ),
    );
  }
}
