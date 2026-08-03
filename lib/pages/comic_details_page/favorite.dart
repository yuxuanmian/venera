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
      _added = result.subData is List
          ? List<String>.from(result.subData).toSet()
          : <String>{};
      cache.cacheFolderSnapshot(_data.key, result.data);
      cache.replaceComicMembership(_data.key, widget.cid, _added);
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
                  ? Button.filled(
                      onPressed: () => _change('', !isAdded),
                      child: Text(isAdded ? 'Remove'.tl : 'Add'.tl),
                    )
                  : Text('Not login'.tl),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: Appbar(title: Text('Favorite'.tl)),
      body: ListView(
        children: [
          for (final entry in _folders!.entries)
            ListTile(
              title: Text(entry.value),
              subtitle: !canChange ? Text('Not login'.tl) : null,
              trailing: canChange
                  ? Button.filled(
                      onPressed: () =>
                          _change(entry.key, !_added.contains(entry.key)),
                      child: Text(
                        _added.contains(entry.key) ? 'Remove'.tl : 'Add'.tl,
                      ),
                    )
                  : Text('Not login'.tl),
            ),
        ],
      ),
    );
  }
}
