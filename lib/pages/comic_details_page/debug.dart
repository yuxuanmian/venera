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

  DateTime? _nextCheckTime(FavoriteItemWithUpdateInfo info) {
    final next = info.nextCheckAt;
    final retry = info.retryAfter;
    if (next == null) return retry;
    if (retry == null || retry.isBefore(next)) return next;
    return retry;
  }

  String _fmt(DateTime? time) =>
      time == null ? '-' : time.toLocal().toString().substring(0, 19);

  String _yesNo(bool value) => value ? "Yes".tl : "No".tl;

  String _rawJson() {
    final details = widget.details;
    if (details == null) return '{}';
    return const JsonEncoder.withIndent('  ').convert(details.toJson());
  }

  bool get _usesListUpdateStrategy =>
      ComicSource.find(widget.sourceKey)?.favoriteData?.updateCheck != null;

  NetworkFavoriteFolderRef? _debugFolder() {
    final known = _cache.getKnownFolderIds(widget.sourceKey, widget.comicId);
    for (final folder in _cache.getAllCachedFolders()) {
      if (folder.sourceKey == widget.sourceKey &&
          (known.isEmpty || known.contains(folder.folderId))) {
        return folder;
      }
    }
    return null;
  }

  Future<void> _recheck() async {
    setState(() => _rechecking = true);
    final result = await recheckFavoriteComicDetailed(
      widget.sourceKey,
      widget.comicId,
    );
    if (!mounted) return;
    setState(() => _rechecking = false);
    final message = !result.succeeded
        ? "Failed".tl
        : result.found == false
        ? "Not present in favorite snapshot".tl
        : "Success".tl;
    context.showMessage(message: message);
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
            if (!_usesListUpdateStrategy)
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
    if (_usesListUpdateStrategy) return _buildListFollowUpSection();
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
        _infoRow(
          "Last Effective Activity Time",
          _fmt(info.effectiveActivityAt),
        ),
        _infoRow("Baseline Time", _fmt(info.baselineAt)),
        _infoRow("Source Activity Time", _fmt(info.sourceActivityAt)),
        _infoRow(
          "Hot Window Active",
          _yesNo(info.isHotActiveAt(DateTime.now())),
        ),
        _infoRow("Hot Window Source", _hotSource(info)),
        _infoRow("Hot Window Until", _fmt(info.hotUntilAt(DateTime.now()))),
        _infoRow("Manual Hot Enabled", _yesNo(info.manualHotEnabled)),
        _infoRow("Update Marker", info.updateMarker ?? '-'),
        _infoRow("Last Update Time", info.updateTime ?? '-'),
        _infoRow("Has New Update", _yesNo(info.hasNewUpdate)),
        _infoRow("Check Failures", '${info.checkFailures}'),
        _infoRow("Not Found Hits", '${info.checkNotFoundCount}'),
        _infoRow("Suspected Removed", _yesNo(info.isSuspectGone)),
      ],
    ];
  }

  List<Widget> _buildListFollowUpSection() {
    final source = ComicSource.find(widget.sourceKey);
    final updateCheck = source?.favoriteData?.updateCheck;
    final folder = _debugFolder();
    final scan = folder == null
        ? null
        : _cache.getFavoriteUpdateScanState(folder);
    final info = _updateInfo();
    final marker = info?.updateMarker == null
        ? null
        : decodeFollowUpdateMarker(info!.updateMarker!);
    final metadata = info?.sourceUpdateMetadata;
    String sourceBool(String key) {
      final value = metadata?[key];
      return value is bool ? _yesNo(value) : '-';
    }

    return [
      ListTile(title: Text("Follow-up State".tl)),
      _infoRow("Update Check Strategy", "Favorite list snapshot".tl),
      _infoRow("Source is_new", sourceBool('isNew')),
      _infoRow("Source full_is_new", sourceBool('fullIsNew')),
      _infoRow("Marker Scheme", marker?.scheme ?? '-'),
      _infoRow("Marker Value", marker?.value ?? '-'),
      _infoRow(
        "List Scan Interval",
        updateCheck == null ? '-' : _formatInterval(updateCheck.scanInterval),
      ),
      _infoRow("Last List Scan Attempt", _fmt(scan?.lastAttemptAt)),
      _infoRow("Last Successful List Scan", _fmt(scan?.lastSuccessAt)),
      _infoRow(
        "Next Automatic List Scan",
        _nextListScanText(scan, updateCheck?.scanInterval),
      ),
      _infoRow("List Retry After", _fmt(scan?.retryAfter)),
      _infoRow("List Check Failures", '${scan?.checkFailures ?? 0}'),
      _infoRow(
        "Last Snapshot Pages / Comics",
        '${scan?.lastPageCount ?? 0} / ${scan?.lastComicCount ?? 0}',
      ),
      _infoRow(
        "Has New Update",
        info == null ? '-' : _yesNo(info.hasNewUpdate),
      ),
      _infoRow("Last Update Time", info?.updateTime ?? '-'),
    ];
  }

  String _formatInterval(Duration interval) {
    final seconds = interval.inSeconds;
    if (seconds % 3600 == 0) return '${seconds ~/ 3600}h';
    if (seconds % 60 == 0) return '${seconds ~/ 60}m';
    return '${seconds}s';
  }

  String _nextListScanText(FavoriteUpdateScanState? scan, Duration? interval) {
    if (scan?.lastSuccessAt == null || interval == null) return '-';
    var next = scan!.lastSuccessAt!.add(interval);
    if (scan.retryAfter != null && scan.retryAfter!.isAfter(next)) {
      next = scan.retryAfter!;
    }
    final ready = !next.isAfter(DateTime.now());
    return '${_fmt(next)} (${ready ? "Ready".tl : "In Cooldown".tl})';
  }

  String _nextCheckText(FavoriteItemWithUpdateInfo info) {
    final next = _nextCheckTime(info);
    if (next == null) return "Not checked yet".tl;
    final ready = !next.isAfter(DateTime.now());
    return '${_fmt(next)} (${ready ? "Ready".tl : "In Cooldown".tl})';
  }

  String _hotSource(FavoriteItemWithUpdateInfo info) {
    final now = DateTime.now();
    final automatic = info.isAutoHotActiveAt(now);
    final manual = info.isManualHotActiveAt(now);
    if (automatic && manual) return "Automatic + Manual".tl;
    if (automatic) return "Automatic".tl;
    if (manual) return "Manual".tl;
    return "None".tl;
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
      _infoRow(
        "Supports Detail Check",
        _usesListUpdateStrategy ? '-' : _yesNo(source?.loadComicInfo != null),
      ),
      _infoRow(
        "Update Check Strategy",
        _usesListUpdateStrategy
            ? "Favorite list snapshot".tl
            : "Comic details".tl,
      ),
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
