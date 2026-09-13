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
    this.scheduleRepository,
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

  /// Test injection point for the schedule store (007).
  ///
  /// Production callers use the app-owned schedule repository.  The Debug page
  /// reads it, never writes it: this page answers "what is stored right now".
  final ScheduleStateRepository? scheduleRepository;

  final NetworkFavoriteCacheManager? favoriteCache;

  @override
  State<ComicDebugPage> createState() => _ComicDebugPageState();
}

class _ComicDebugPageState extends State<ComicDebugPage> {
  late final NetworkFavoriteCacheManager _cache;
  ScanStoredItem? _scanItem;
  ScanStoredScope? _scanScope;
  bool _scanLoaded = false;
  String? _scanError;
  StreamSubscription<ScanRepositoryEvent>? _scanEvents;

  JudgmentState? _judgment;
  bool _judgmentLoaded = false;
  String? _judgmentError;

  ScheduleState? _schedule;
  bool _scheduleLoaded = false;
  String? _scheduleError;

  @override
  void initState() {
    super.initState();
    _cache = widget.favoriteCache ?? NetworkFavoriteCacheManager();
    _reloadScanResult();
    _reloadJudgment();
    _reloadSchedule();
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
    _reloadSchedule();
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
        _scanError = null;
        _scanLoaded = true;
      });
    } catch (error) {
      // A corrupt/unavailable scan database must not break the existing
      // details debug page, but it MUST be reported rather than rendered as
      // "no record": Contract D4 keeps the two apart.
      if (!mounted) return;
      setState(() {
        _scanItem = null;
        _scanScope = null;
        _scanError = error is ScanStorageException
            ? error.message
            : error.runtimeType.toString();
        _scanLoaded = true;
      });
    }
  }

  /// Reads the schedule row for this identity (007 FR-014).
  ///
  /// One primary-key lookup, read-only.  Contract D4: a missing row, a missing
  /// field and a storage failure are three different answers, so the three are
  /// tracked separately here.
  Future<void> _reloadSchedule() async {
    try {
      final repository = widget.scheduleRepository ?? scheduleStateRepository;
      await repository.ensureOpen();
      final state = await repository.readByIdentity(
        widget.sourceKey,
        widget.comicId,
      );
      if (!mounted) return;
      setState(() {
        _schedule = state;
        _scheduleError = null;
        _scheduleLoaded = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _schedule = null;
        _scheduleError = error is ScheduleStorageException
            ? error.message
            : error.runtimeType.toString();
        _scheduleLoaded = true;
      });
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

  String _fmt(DateTime? time) =>
      time == null ? '-' : time.toLocal().toString().substring(0, 19);

  /// Like [_fmt], but the caller names what "absent" means.
  ///
  /// Contract D4 forbids `-`, `0` and the empty string as stand-ins for a real
  /// value, so an absent field is spelled out instead of impersonating one.
  String _fmtOr(DateTime? time, String whenNull) =>
      time == null ? whenNull : _fmt(time);

  DateTime? _msUtc(int? millis) => millis == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);

  String _yesNo(bool value) => value ? "Yes".tl : "No".tl;

  String _rawJson() {
    final details = widget.details;
    if (details == null) return '{}';
    return const JsonEncoder.withIndent(
      '  ',
    ).convert(TrackingDiagnostics.redactForDisplay(details.toJson()));
  }

  /// Whether the source declares the **retired** list-update channel.
  ///
  /// This is the last place in the app UI that reads `favorites.updateCheck`.
  /// It exists only so the two diagnostic rows below can say which strategy the
  /// retired scanner used; it drives no behaviour.
  ///
  /// **重访触发条件**：当源侧按 005 的 FR-045 删除该声明时，下面两行 MUST 改指
  /// 004 的扫描能力（`source.scan`）或被删除 —— `test/scan_retirement/debug_test.dart`
  /// 的用例钉住了这两行当前的读数，因此删除会让测试**明确失败**，而不是让标签
  /// 静默变义。
  bool get _usesRetiredUpdateCheckDeclaration =>
      ComicSource.find(widget.sourceKey)?.favoriteData?.updateCheck != null;

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
          // The two in-place blocks (007 Contract D1): the same two positions,
          // showing current values instead of the retired scheduler's state.
          ..._buildScheduleSection(),
          const Divider(),
          ..._buildCollectionScopeSection(),
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

  // ---------------------------------------------------------------------------
  // The two in-place blocks (007 Contract D)
  //
  // Both positions used to show the **retired** scheduler's state, and the two
  // were mutually exclusive (one for per-comic sources, one for list-strategy
  // sources).  Since 007 they show the **current** schedule and the **current**
  // collection scope, and they are shown for every comic — the branch on
  // "does this source use the list update strategy" is gone, because the answer
  // no longer changes what is displayed.
  //
  // No new page section was added: these are the same two positions, with the
  // fields replaced.  Contract D4 keeps three answers apart — a missing record,
  // a missing field on an existing record, and a storage failure — so the
  // defaults below never use `0`, an empty string or `-` to impersonate a real
  // value, and the failure text is not the same as the "no record" text.
  // ---------------------------------------------------------------------------

  /// Block 1: the current schedule row for this identity (FR-014).
  List<Widget> _buildScheduleSection() {
    final header = [ListTile(title: Text('Schedule'.tl))];
    if (!_scheduleLoaded) {
      return [...header, _infoRow('Next Check Time', 'Loading'.tl)];
    }
    if (_scheduleError != null) {
      return [
        ...header,
        _infoRow('Schedule State Unreadable'.tl, _scheduleError!),
      ];
    }
    final state = _schedule;
    if (state == null) {
      // "No record at all" is distinct from "a record whose fields are empty".
      return [
        ...header,
        _infoRow('Next Check Time', 'No check record'.tl),
        _infoRow('Activity Anchor', 'No check record'.tl),
        _infoRow('Auto Hot Window', 'No check record'.tl),
        _infoRow('Auto Hot Until', 'No check record'.tl),
        _infoRow('Schedule Jitter Applied', 'No check record'.tl),
      ];
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final autoHotUntil = _msUtc(state.autoHotUntilMs);
    final autoHotActive =
        state.autoHotUntilMs != null && state.autoHotUntilMs! > nowMs;
    return [
      ...header,
      _infoRow(
        'Next Check Time',
        _fmtOr(_msUtc(state.nextAtMs), 'Not computed yet'.tl),
      ),
      _infoRow(
        'Activity Anchor',
        _fmtOr(_msUtc(state.activityAtMs), 'None'.tl),
      ),
      _infoRow('Auto Hot Window', autoHotActive ? 'Active'.tl : 'Inactive'.tl),
      _infoRow('Auto Hot Until', _fmtOr(autoHotUntil, 'None'.tl)),
      _infoRow(
        'Schedule Jitter Applied',
        _yesNo(state.oldScheduleJitterApplied),
      ),
    ];
  }

  /// Block 2: the current collection scope plus this source's declared scan
  /// capability (FR-015).
  List<Widget> _buildCollectionScopeSection() {
    final header = [ListTile(title: Text('Collection Scope'.tl))];
    final capabilityRows = _scanCapabilityRows();
    if (!_scanLoaded) {
      return [
        ...header,
        ...capabilityRows,
        _infoRow('Scope Type', 'Loading'.tl),
      ];
    }
    if (_scanError != null) {
      return [
        ...header,
        ...capabilityRows,
        _infoRow('Scan State Unreadable'.tl, _scanError!),
      ];
    }
    final item = _scanItem;
    if (item == null) {
      // No observation row for this identity ⇒ the scope attempt identifier it
      // would have carried does not exist, so the whole block is a default.
      return [
        ...header,
        ...capabilityRows,
        _infoRow('Scope Type', 'No scan record'.tl),
        _infoRow('Scope Key', 'No scan record'.tl),
        _infoRow('Scope Status', 'No scan record'.tl),
        _infoRow('Scope Started', 'No scan record'.tl),
        _infoRow('Scope Finished', 'No scan record'.tl),
        _infoRow('Scope Items', 'No scan record'.tl),
        _infoRow('Scope Failure', 'No scan record'.tl),
      ];
    }
    final scope = _scanScope;
    if (scope == null) {
      return [
        ...header,
        ...capabilityRows,
        _infoRow('Scope Type', 'No scope record'.tl),
        _infoRow('Scope Key', 'No scope record'.tl),
        _infoRow('Scope Status', 'No scope record'.tl),
        _infoRow('Scope Started', 'No scope record'.tl),
        _infoRow('Scope Finished', 'No scope record'.tl),
        _infoRow('Scope Items', 'No scope record'.tl),
        _infoRow('Scope Failure', 'No scope record'.tl),
      ];
    }
    return [
      ...header,
      ...capabilityRows,
      _infoRow('Scope Type', scope.producer.value),
      _infoRow('Scope Key', scope.scopeKey),
      _infoRow('Scope Status', scope.status.value),
      _infoRow('Scope Started', _fmt(_msUtc(scope.startedAtMs))),
      _infoRow(
        'Scope Finished',
        _fmtOr(_msUtc(scope.finishedAtMs), 'Not finished'.tl),
      ),
      _infoRow('Scope Items', '${scope.itemCount}'),
      _infoRow(
        'Scope Failure',
        scope.failure == null ? 'None'.tl : _failureText(scope.failure!),
      ),
    ];
  }

  /// The source's declared scan capability: unit, preferred branch, and whether
  /// the declaration is unusable (Contract D3).
  List<Widget> _scanCapabilityRows() {
    final capabilities = ComicSource.find(widget.sourceKey)?.scan;
    if (capabilities == null) {
      return [
        _infoRow('Scan Capability', 'No scan capability'.tl),
        _infoRow('Scan Preferred Method', 'None'.tl),
      ];
    }
    if (capabilities.state == ScanCapabilitiesState.invalid) {
      return [
        _infoRow('Scan Capability', 'Invalid scan capability'.tl),
        _infoRow(
          'Scan Capability Invalid',
          capabilities.reason ?? 'No scan capability'.tl,
        ),
        _infoRow('Scan Preferred Method', 'None'.tl),
      ];
    }
    if (!capabilities.isSupported) {
      return [
        _infoRow('Scan Capability', 'No scan capability'.tl),
        _infoRow('Scan Preferred Method', 'None'.tl),
      ];
    }
    final selected = capabilities.selected;
    return [
      _infoRow(
        'Scan Capability',
        selected == null ? 'No scan capability'.tl : selected.producer.value,
      ),
      _infoRow(
        'Scan Preferred Method',
        capabilities.primary?.value ?? 'None'.tl,
      ),
    ];
  }

  /// A failure fact, rendered from its already-sanitized fields.
  String _failureText(ScanFailure failure) {
    final parts = <String>[
      if (failure.httpStatus != null) 'HTTP ${failure.httpStatus}',
      if (failure.sourceCode != null) failure.sourceCode!,
      if (failure.exceptionType != null) failure.exceptionType!,
      if (failure.message != null) failure.message!,
    ];
    return parts.isEmpty ? 'None'.tl : parts.join(' · ');
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
      // Diagnostic only, and the last reader of the retired declaration: these
      // two rows describe the *old* strategy, which is a different fact from the
      // 004 scan capability shown by the "Collection Scope" block.  See the
      // getter above for the revisit trigger.
      _infoRow(
        "Supports Detail Check",
        _usesRetiredUpdateCheckDeclaration ? '-' : _yesNo(source?.loadComicInfo != null),
      ),
      _infoRow(
        "Update Check Strategy",
        _usesRetiredUpdateCheckDeclaration
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
