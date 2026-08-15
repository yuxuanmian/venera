part of 'comic_page.dart';

/// Debug page for one comic, opened from the details page "more" menu.
///
/// Only reachable while the global developer-mode switch (Settings -> Debug)
/// is on; the switch itself lives there.
class ComicDebugPage extends StatefulWidget {
  const ComicDebugPage({
    super.key,
    required this.sourceKey,
    required this.comicId,
    this.details,
  });

  final String sourceKey;

  final String comicId;

  /// The details currently loaded on the details page; used for the raw JSON
  /// view. Null while the details page is still loading/errored.
  final ComicDetails? details;

  @override
  State<ComicDebugPage> createState() => _ComicDebugPageState();
}

class _ComicDebugPageState extends State<ComicDebugPage> {
  final _cache = NetworkFavoriteCacheManager();
  bool _rechecking = false;

  /// Follow-up state of this comic, from whichever favorite folder row the
  /// cache knows about (state is comic-level, shared across folders).
  FavoriteItemWithUpdateInfo? _updateInfo() {
    final folderIds = _cache.getKnownFolderIds(
      widget.sourceKey,
      widget.comicId,
    );
    for (final folderId in folderIds) {
      final info = _cache.getComicUpdateInfo(
        widget.sourceKey,
        widget.comicId,
        folderId,
      );
      if (info != null) return info;
    }
    return null;
  }

  /// Next moment this comic becomes eligible for an automatic follow-up
  /// check: the failure backoff deadline while retrying, or the regular 24h
  /// window after the last check for healthy comics.
  DateTime? _nextCheckTime(FavoriteItemWithUpdateInfo info) {
    if (info.retryAfter != null) return info.retryAfter;
    final last = info.lastCheckTime;
    if (last == null) return null;
    return last.add(const Duration(hours: 24));
  }

  String _fmt(DateTime? time) =>
      time == null ? '-' : time.toLocal().toString().substring(0, 19);

  String _yesNo(bool value) => value ? "Yes".tl : "No".tl;

  String _rawJson() {
    final details = widget.details;
    if (details == null) return '{}';
    return const JsonEncoder.withIndent('  ').convert(details.toJson());
  }

  Future<void> _recheck() async {
    setState(() => _rechecking = true);
    final ok = await recheckFavoriteComic(widget.sourceKey, widget.comicId);
    if (!mounted) return;
    setState(() => _rechecking = false);
    context.showMessage(message: ok ? "Success".tl : "Failed".tl);
  }

  void _clearSuspect() {
    _cache.clearComicSuspectGoneEverywhere(widget.sourceKey, widget.comicId);
    setState(() {});
    context.showMessage(message: "Cleared".tl);
  }

  void _copyJson() {
    Clipboard.setData(ClipboardData(text: _rawJson()));
    context.showMessage(message: "Copied".tl);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text("Debug Info".tl)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          ..._buildActions(),
          const Divider(),
          ..._buildFollowUpSection(),
          const Divider(),
          ..._buildSourceSection(),
          const Divider(),
          ..._buildRawDataSection(),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 150, child: Text(label.tl, style: ts.s14)),
          Expanded(child: SelectableText(value, style: ts.s14)),
        ],
      ),
    );
  }

  List<Widget> _buildActions() {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Button.filled(
              isLoading: _rechecking,
              onPressed: _recheck,
              child: Text("Recheck Now".tl),
            ),
            Button.outlined(
              onPressed: _clearSuspect,
              child: Text("Clear Suspected Removed".tl),
            ),
            Button.outlined(onPressed: _copyJson, child: Text("Copy JSON".tl)),
          ],
        ),
      ),
    ];
  }

  List<Widget> _buildFollowUpSection() {
    final info = _updateInfo();
    return [
      ListTile(title: Text("Follow-up State".tl)),
      if (info == null)
        ListTile(
          title: Text("Not tracked by follow-up scans".tl, style: ts.s14),
        )
      else ...[
        _infoRow("Last Check Time", _fmt(info.lastCheckTime)),
        _infoRow("Next Check Time", _nextCheckText(info)),
        _infoRow("Update Marker", info.updateMarker ?? '-'),
        _infoRow("Last Update Time", info.updateTime ?? '-'),
        _infoRow("Has New Update", _yesNo(info.hasNewUpdate)),
        _infoRow("Check Failures", '${info.checkFailures}'),
        _infoRow("Not Found Hits", '${info.checkNotFoundCount}'),
        _infoRow("Suspected Removed", _yesNo(info.isSuspectGone)),
      ],
    ];
  }

  String _nextCheckText(FavoriteItemWithUpdateInfo info) {
    final next = _nextCheckTime(info);
    if (next == null) return "Not checked yet".tl;
    final ready = !next.isAfter(DateTime.now());
    return '${_fmt(next)} (${ready ? "Ready".tl : "In Cooldown".tl})';
  }

  List<Widget> _buildSourceSection() {
    final source = ComicSource.find(widget.sourceKey);
    final folderIds = _cache.getKnownFolderIds(
      widget.sourceKey,
      widget.comicId,
    );
    final folders = _cache.getAllCachedFolders().where(
      (f) => f.sourceKey == widget.sourceKey,
    );
    final titles = {for (final f in folders) f.folderId: f.title};
    final foldersText = folderIds.isEmpty
        ? '-'
        : folderIds.map((id) => '${titles[id] ?? id} ($id)').join(', ');
    return [
      ListTile(title: Text("Source Info".tl)),
      _infoRow("Source Key", widget.sourceKey),
      _infoRow("Source Name", source?.name ?? '-'),
      _infoRow("Logged In", _yesNo(source?.isLogged ?? false)),
      _infoRow("Supports Detail Check", _yesNo(source?.loadComicInfo != null)),
      _infoRow("Follow Updates Enabled", _yesNo(followUpdatesEnabled)),
      _infoRow("Folders", foldersText),
    ];
  }

  List<Widget> _buildRawDataSection() {
    return [
      ExpansionTile(
        title: Text("Raw Data".tl),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SelectableText(_rawJson(), style: ts.s14),
          ),
          const SizedBox(height: 12),
        ],
      ),
    ];
  }
}
