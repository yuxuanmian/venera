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
    this.scanRepository,
    this.judgmentRepository,
    this.favoriteCache,
  });

  final String sourceKey;

  final String comicId;

  /// The details currently loaded on the details page; used for the raw JSON
  /// view. Null while the details page is still loading/errored.
  final ComicDetails? details;

  /// Test and embedded-debug injection point. Production callers use the
  /// app-owned latest-result repository.
  final ScanResultRepository? scanRepository;

  /// Test injection point for the judgment state store. Production callers use
  /// the app-owned judgment repository through [judgmentService].
  final JudgmentStateRepository? judgmentRepository;

  final NetworkFavoriteCacheManager? favoriteCache;

  @override
  State<ComicDebugPage> createState() => _ComicDebugPageState();
}

class _ComicDebugPageState extends State<ComicDebugPage> {
  late final NetworkFavoriteCacheManager _cache;
  ScanStoredItem? _scanItem;
  ScanStoredScope? _scanScope;
  bool _scanLoaded = false;
  StreamSubscription<ScanRepositoryEvent>? _scanEvents;

  JudgmentState? _judgment;
  bool _judgmentLoaded = false;
  String? _judgmentError;

  @override
  void initState() {
    super.initState();
    _cache = widget.favoriteCache ?? NetworkFavoriteCacheManager();
    _reloadScanResult();
    _reloadJudgment();
    final repository = widget.scanRepository ?? scanResultRepository;
    _scanEvents = repository.events.listen((event) {
      final item = event.item?.result;
      final scope = event.scope;
      if (item != null &&
          (item.sourceKey != widget.sourceKey ||
              item.comicId != widget.comicId)) {
        return;
      }
      if (scope != null && scope.sourceKey != widget.sourceKey) return;
      _reloadScanResult();
    });
  }

  @override
  void dispose() {
    _scanEvents?.cancel();
    super.dispose();
  }

  /// A widget test or a future in-page navigation can reuse this State for a
  /// different comic, so identity changes must reload both stores.
  @override
  void didUpdateWidget(covariant ComicDebugPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceKey == widget.sourceKey &&
        oldWidget.comicId == widget.comicId) {
      return;
    }
    _reloadScanResult();
    _reloadJudgment();
  }

  Future<void> _reloadScanResult() async {
    try {
      final repository = widget.scanRepository ?? scanResultRepository;
      final item = await repository.readLatestItem(
        widget.sourceKey,
        widget.comicId,
      );
      final scope = item == null
          ? null
          : await repository.readScopeByAttemptId(
              item.result.sourceKey,
              item.result.producer,
              item.result.scopeAttemptId,
            );
      if (!mounted) return;
      setState(() {
        _scanItem = item;
        _scanScope = scope;
        _scanLoaded = true;
      });
    } catch (_) {
      // A corrupt/unavailable scan database must not break the existing
      // details debug page.
    }
  }

  /// Reads the persisted judgment state.
  ///
  /// Contract U3 requires a storage failure to be *reported*, never silently
  /// rendered as "no record": those are different situations and conflating
  /// them hides a broken database.
  Future<void> _reloadJudgment() async {
    try {
      final state = widget.judgmentRepository != null
          ? await _readInjectedJudgment()
          : await judgmentService.readFor(widget.sourceKey, widget.comicId);
      if (!mounted) return;
      setState(() {
        _judgment = state;
        _judgmentError = null;
        _judgmentLoaded = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _judgment = null;
        _judgmentError = error is JudgmentStorageException
            ? error.message
            : error.runtimeType.toString();
        _judgmentLoaded = true;
      });
    }
  }

  Future<JudgmentState?> _readInjectedJudgment() async {
    final repository = widget.judgmentRepository!;
    await repository.ensureOpen();
    return repository.readFor(widget.sourceKey, widget.comicId);
  }

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
    return const JsonEncoder.withIndent(
      '  ',
    ).convert(TrackingDiagnostics.redactForDisplay(details.toJson()));
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

  void _recheck() =>
      context.showMessage(message: followUpdateScannerUnavailableMessage.tl);

  void _copyJson() {
    Clipboard.setData(ClipboardData(text: _rawJson()));
    context.showMessage(message: "Copied".tl);
  }

  void _copyTrackingTrace() {
    final trace = trackingDiagnostics.latest(widget.sourceKey, widget.comicId);
    if (trace == null) return;
    Clipboard.setData(
      ClipboardData(text: const JsonEncoder.withIndent('  ').convert(trace)),
    );
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
          ..._buildJudgmentSection(),
          const Divider(),
          ..._buildRawScanSection(),
          const Divider(),
          ..._buildFollowUpSection(),
          const Divider(),
          ..._buildTrackingTraceSection(),
          const Divider(),
          ..._buildOwnershipSection(),
          const Divider(),
          ..._buildSourceSection(),
          const Divider(),
          ..._buildRawDataSection(),
          ..._buildScanFieldsSection(),
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
              isLoading: false,
              onPressed: _recheck,
              child: Text("Recheck Now".tl),
            ),
            Button.outlined(onPressed: _copyJson, child: Text("Copy JSON".tl)),
            if (trackingDiagnostics.latest(widget.sourceKey, widget.comicId) !=
                null)
              Button.outlined(
                onPressed: _copyTrackingTrace,
                child: Text("Copy Tracking Trace".tl),
              ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _buildFollowUpSection() {
    if (_usesListUpdateStrategy) return _buildListFollowUpSection();
    final info = _updateInfo();
    return [
      ListTile(title: Text(followUpdateScannerUnavailableMessage.tl)),
      ListTile(title: Text('Displayed scan state is historical'.tl)),
      ListTile(title: Text("Follow-up State".tl)),
      if (info == null)
        ListTile(
          title: Text("Not tracked by follow-up scans".tl, style: ts.s14),
        )
      else ...[
        _infoRow("Last Check Time", _fmt(info.lastCheckTime)),
        _infoRow("Historical Next Check Time", _historicalNextCheckText(info)),
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
    final metadata = info?.sourceUpdateMetadata;
    String sourceBool(String key) {
      final value = metadata?[key];
      return value is bool ? _yesNo(value) : '-';
    }

    return [
      ListTile(title: Text(followUpdateScannerUnavailableMessage.tl)),
      ListTile(title: Text('Displayed scan state is historical'.tl)),
      ListTile(title: Text("Follow-up State".tl)),
      _infoRow("Update Check Strategy", "Favorite list snapshot".tl),
      _infoRow("Source is_new", sourceBool('isNew')),
      _infoRow("Source full_is_new", sourceBool('fullIsNew')),
      _infoRow("Marker Value", info?.updateMarker ?? '-'),
      _infoRow(
        "Historical List Scan Interval",
        updateCheck == null ? '-' : _formatInterval(updateCheck.scanInterval),
      ),
      _infoRow("Last List Scan Attempt", _fmt(scan?.lastAttemptAt)),
      _infoRow("Last Successful List Scan", _fmt(scan?.lastSuccessAt)),
      _infoRow(
        "Historical Next List Check",
        _historicalNextListCheckText(scan, updateCheck?.scanInterval),
      ),
      _infoRow("Historical List Retry After", _fmt(scan?.retryAfter)),
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

  String _historicalNextListCheckText(
    FavoriteUpdateScanState? scan,
    Duration? interval,
  ) {
    if (scan?.lastSuccessAt == null || interval == null) return '-';
    var next = scan!.lastSuccessAt!.add(interval);
    if (scan.retryAfter != null && scan.retryAfter!.isAfter(next)) {
      next = scan.retryAfter!;
    }
    return _fmt(next);
  }

  String _historicalNextCheckText(FavoriteItemWithUpdateInfo info) {
    final next = _nextCheckTime(info);
    if (next == null) return "Not checked yet".tl;
    return _fmt(next);
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

  List<Widget> _buildOwnershipSection() {
    return [
      ListTile(title: Text("Catalog Runtime".tl)),
      _infoRow("Source", widget.sourceKey),
      _infoRow(
        "Server",
        (appdata.settings['serverUrl'] as String?)?.isNotEmpty == true
            ? appdata.settings['serverUrl'] as String
            : "Not configured".tl,
      ),
      _infoRow("Loaded", _yesNo(ComicSource.find(widget.sourceKey) != null)),
    ];
  }

  List<Widget> _buildTrackingTraceSection() {
    final trace = trackingDiagnostics.latest(widget.sourceKey, widget.comicId);
    if (trace == null) {
      return [
        ListTile(title: Text("Tracking Diagnostics".tl)),
        _infoRow("Decision Trace", "No trace in this session".tl),
      ];
    }
    Widget section(String title, Object? value) {
      final text = value == null
          ? '-'
          : const JsonEncoder.withIndent('  ').convert(value);
      return ExpansionTile(
        title: Text(title.tl),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SelectableText(text, style: ts.s14),
          ),
        ],
      );
    }

    return [
      ListTile(title: Text("Tracking Diagnostics".tl)),
      section("Runtime", trace['runtime']),
      section("Raw Observation", trace['rawObservation']),
      section("Normalized UpdateState", trace['normalization']),
      section("Comparison", trace['comparison']),
      section("Presentation", trace['presentation']),
      section("Rejection", trace['rejection']),
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

  List<Widget> _buildScanFieldsSection() {
    return [
      ExpansionTile(
        title: Text('Scan Fields'.tl),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SelectableText(
              !_scanLoaded
                  ? 'Loading'.tl
                  : _scanItem == null
                  ? 'No persisted scan result'.tl
                  : _scanJson(),
              style: ts.s14,
            ),
          ),
        ],
      ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Judgment (Contract U1/U2/U3)
  // ---------------------------------------------------------------------------

  /// Renders the Judgment section, kept separate from Raw Scan Result so a
  /// reader can tell "what the source said" from "what we concluded".
  ///
  /// Every value comes from persisted state, so it survives a restart.
  List<Widget> _buildJudgmentSection() {
    final header = [ListTile(title: Text('Judgment'.tl))];
    if (!_judgmentLoaded) {
      return [...header, _infoRow('Conclusion', 'Loading'.tl)];
    }
    if (_judgmentError != null) {
      // A broken store is reported, never rendered as an empty record.
      return [
        ...header,
        _infoRow('Judgment State Unreadable'.tl, _judgmentError!),
      ];
    }
    final state = _judgment;
    if (state == null) {
      // "No record at all" is distinct from "a record whose fields are empty".
      return [...header, _infoRow('No Judgment Record'.tl, '-')];
    }

    final item = _scanItem;
    return [
      ...header,
      // U2.1 decision result.
      _infoRow('Conclusion', state.lastDecision.value),
      _infoRow('Selected Evidence', state.lastEvidence?.value ?? 'None'.tl),
      _infoRow(
        'Previous Value',
        state.lastPreviousValue ?? 'No Previous Fact'.tl,
      ),
      _infoRow('Current Value', _currentValueText(state)),
      _infoRow('Reason', state.lastReason.value),
      // U2.2 fact.
      if (state.factJson != null)
        _judgmentFactTile(state.factJson!)
      else
        _infoRow('Fact Content', 'No Previous Fact'.tl),
      _infoRow(
        'Fact Observed At',
        state.factObservedAtMs == null
            ? 'No Previous Fact'.tl
            : _fmt(
                DateTime.fromMillisecondsSinceEpoch(
                  state.factObservedAtMs!,
                  isUtc: true,
                ),
              ),
      ),
      _infoRow('Comparable Label', state.evidenceSchema ?? 'None'.tl),
      // U2.3 visible flag and diagnostics.
      _infoRow('Has New Update', _yesNo(state.hasNewUpdate)),
      _infoRow(
        'Decided At',
        _fmt(
          DateTime.fromMillisecondsSinceEpoch(state.decidedAtMs, isUtc: true),
        ),
      ),
      _infoRow('No Common Field Streak', '${state.noCommonStreak}'),
      // U3: the reasons the current observation contributed nothing.
      _infoRow('Scan Evidence', _scanEvidenceText(item)),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Button.outlined(
            onPressed: _copyJudgment,
            child: Text('Copy Judgment Data'.tl),
          ),
        ),
      ),
    ];
  }

  /// U3: distinguishes "there is no scan evidence" from "this comic's scan
  /// failed" from "there is evidence but it carries nothing usable".
  String _scanEvidenceText(ScanStoredItem? item) {
    if (!_scanLoaded) return 'Loading'.tl;
    if (item == null) return 'No Scan Evidence'.tl;
    if (!item.result.isSuccess) return 'Scan Failed For This Comic'.tl;
    return 'OK'.tl;
  }

  /// U3: an empty current value means either "no usable evidence" or "no
  /// comparison happened yet"; the two are reported differently.
  String _currentValueText(JudgmentState state) {
    final value = state.lastCurrentValue;
    if (value != null && value.isNotEmpty) return value;
    return switch (state.lastReason) {
      JudgmentReason.noUsableEvidence => 'No Usable Evidence'.tl,
      JudgmentReason.noPreviousEvidence => 'No Previous Fact'.tl,
      _ => 'None'.tl,
    };
  }

  Widget _judgmentFactTile(String factJson) {
    String pretty = factJson;
    try {
      pretty = const JsonEncoder.withIndent(
        '  ',
      ).convert(TrackingDiagnostics.redactForDisplay(jsonDecode(factJson)));
    } catch (_) {
      // A malformed fact is shown verbatim rather than hidden.
    }
    return ExpansionTile(
      title: Text('Fact Content'.tl),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: SelectableText(pretty, style: ts.s14),
        ),
      ],
    );
  }

  /// U2.4: exports persisted judgment fields only, and goes through the same
  /// redaction allow-list as the existing diagnostics because the fact holds
  /// source-provided observation JSON.
  String _judgmentJson() {
    final state = _judgment;
    if (_judgmentError != null) {
      return const JsonEncoder.withIndent(
        '  ',
      ).convert({'state': 'unreadable', 'error': _judgmentError});
    }
    if (state == null) return '{}';
    return const JsonEncoder.withIndent('  ').convert(
      TrackingDiagnostics.redactForDisplay({
        'sourceKey': state.sourceKey,
        'comicId': state.comicId,
        'conclusion': state.lastDecision.value,
        'selectedEvidence': state.lastEvidence?.value,
        'previousValue': state.lastPreviousValue,
        'currentValue': state.lastCurrentValue,
        'reason': state.lastReason.value,
        'decidedAtMs': state.decidedAtMs,
        'noCommonStreak': state.noCommonStreak,
        'hasNewUpdate': state.hasNewUpdate,
        'processedAttemptId': state.processedAttemptId,
        'factObservedAtMs': state.factObservedAtMs,
        'comparableLabel': state.evidenceSchema,
        'fact': state.factJson == null ? null : jsonDecode(state.factJson!),
      }),
    );
  }

  void _copyJudgment() {
    Clipboard.setData(ClipboardData(text: _judgmentJson()));
    context.showMessage(message: 'Copied'.tl);
  }

  List<Widget> _buildRawScanSection() {
    if (!_scanLoaded) return const [];
    final stored = _scanItem;
    if (stored == null) {
      return [
        ListTile(
          title: Text('Raw Scan Result'.tl),
          subtitle: Text('No persisted scan result'.tl),
        ),
      ];
    }
    final result = stored.result;
    final scope = _scanScope;
    return [
      ListTile(title: Text('Raw Scan Result'.tl)),
      _infoRow('Scan Source', result.sourceKey),
      _infoRow('Scan Comic ID', result.comicId),
      _infoRow('Scan Producer', result.producer.value),
      _infoRow('Definition Revision', result.definitionRevision),
      _infoRow('Attempt ID', result.attemptId),
      _infoRow('Scope Attempt ID', result.scopeAttemptId),
      _infoRow('Observed At', result.observedAt),
      _infoRow(
        'Committed At',
        _fmt(
          DateTime.fromMillisecondsSinceEpoch(
            stored.committedAtMs,
            isUtc: true,
          ),
        ),
      ),
      ..._scanFactRows(result),
      if (result.observation != null)
        _scanPayload('Observation', result.observation!.toJson())
      else
        _scanPayload('Failure', result.failure?.toJson() ?? const {}),
      if (scope != null) ...[
        _infoRow('Scope Status', scope.status.value),
        _infoRow('Scope Item Count', '${scope.itemCount}'),
        _infoRow('Scope Attempt ID', scope.scopeAttemptId),
      ] else
        _infoRow('Scope Status', 'Associated scope was replaced'.tl),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Button.outlined(
            onPressed: _copyScanResult,
            child: Text('Copy Scan Result'.tl),
          ),
        ),
      ),
    ];
  }

  Widget _scanPayload(String title, Map<String, dynamic> value) {
    return ExpansionTile(
      title: Text(title.tl),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: SelectableText(
            const JsonEncoder.withIndent('  ').convert(value),
            style: ts.s14,
          ),
        ),
      ],
    );
  }

  List<Widget> _scanFactRows(ScanItemResult result) {
    final observation = result.observation;
    if (observation != null) {
      final update = observation.update;
      return [
        if (observation.sourceUnread != null)
          _infoRow('Source Unread', _yesNo(observation.sourceUnread!)),
        if (update?.updatedAt != null)
          _infoRow('Updated At', update!.updatedAt!),
        if (update?.latestChapterId != null)
          _infoRow('Latest Chapter ID', update!.latestChapterId!),
        if (update?.chapterCount != null)
          _infoRow('Chapter Count', '${update!.chapterCount}'),
        if (update?.recentChapterIds.isNotEmpty == true)
          _infoRow('Recent Chapter IDs', update!.recentChapterIds.join(', ')),
      ];
    }
    final failure = result.failure;
    if (failure == null) return const [];
    return [
      if (failure.httpStatus != null)
        _infoRow('HTTP Status', '${failure.httpStatus}'),
      if (failure.sourceCode != null)
        _infoRow('Source Code', failure.sourceCode!),
      if (failure.exceptionType != null)
        _infoRow('Exception Type', failure.exceptionType!),
      if (failure.message != null)
        _infoRow('Failure Message', failure.message!),
      if (failure.retryAfter != null)
        _infoRow('Retry After', failure.retryAfter!),
    ];
  }

  String _scanJson() {
    final item = _scanItem;
    if (item == null) return '{}';
    final result = item.result;
    final scope = _scanScope;
    return const JsonEncoder.withIndent('  ').convert({
      'result': result.toJson(),
      'attemptOrdinal': item.attemptOrdinal,
      'observedAtMs': item.observedAtMs,
      'committedAtMs': item.committedAtMs,
      if (scope != null)
        'scope': {
          'sourceKey': scope.sourceKey,
          'producer': scope.producer.value,
          'scopeKey': scope.scopeKey,
          'scopeAttemptId': scope.scopeAttemptId,
          'attemptOrdinal': scope.attemptOrdinal,
          'definitionRevision': scope.definitionRevision,
          'startedAtMs': scope.startedAtMs,
          'finishedAtMs': scope.finishedAtMs,
          'status': scope.status.value,
          'itemCount': scope.itemCount,
          if (scope.failure != null) 'failure': scope.failure!.toJson(),
        }
      else
        'scope': null,
    });
  }

  void _copyScanResult() {
    Clipboard.setData(ClipboardData(text: _scanJson()));
    context.showMessage(message: 'Copied'.tl);
  }
}
