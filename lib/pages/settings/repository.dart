part of 'settings_page.dart';

typedef CatalogRestartAction = Future<void> Function();

class CatalogRepositorySettings extends StatefulWidget {
  const CatalogRepositorySettings({
    super.key,
    required this.controller,
    this.restartAction,
  });

  final CatalogController controller;
  final CatalogRestartAction? restartAction;

  @override
  State<CatalogRepositorySettings> createState() =>
      _CatalogRepositorySettingsState();
}

class _CatalogRepositorySettingsState extends State<CatalogRepositorySettings> {
  late final TextEditingController _repositoryController;
  late final TextEditingController _branchController;
  CatalogRepositorySource? _savedSource;
  CatalogSetupFailure? _failure;
  String? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _savedSource = _readSavedSource();
    _repositoryController = TextEditingController(
      text:
          _savedSource?.repositoryUrl ??
          CatalogRepositorySource.defaultRepositoryUrl,
    );
    _branchController = TextEditingController(
      text: _savedSource?.branch ?? CatalogRepositorySource.defaultBranch,
    );
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _repositoryController.dispose();
    _branchController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  CatalogRepositorySource? _readSavedSource() {
    try {
      return widget.controller.repositorySource;
    } on CatalogRepositorySourceException {
      return null;
    }
  }

  CatalogRepositorySource? _parseDraft() {
    try {
      return CatalogRepositorySource.parse(
        _repositoryController.text,
        branch: _branchController.text,
      );
    } on CatalogRepositorySourceException catch (error) {
      setState(() {
        _failure = CatalogSetupFailure(
          CatalogSetupFailureKind.invalidRepositorySource,
          diagnostic: 'repositoryHead:${error.code}',
        );
      });
      return null;
    }
  }

  bool get _draftDirty {
    final saved = _savedSource;
    final draft = _parseDraftWithoutFeedback();
    if (saved == null) return true;
    return draft == null || draft != saved;
  }

  CatalogRepositorySource? _parseDraftWithoutFeedback() {
    try {
      return CatalogRepositorySource.parse(
        _repositoryController.text,
        branch: _branchController.text,
      );
    } on CatalogRepositorySourceException {
      return null;
    }
  }

  Future<void> _verifyAndSave() async {
    if (_busy) return;
    final source = _parseDraft();
    if (source == null) return;
    setState(() {
      _busy = true;
      _failure = null;
      _status = null;
    });
    final verification = await widget.controller.verifyAndSaveRepositorySource(
      source,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (verification.succeeded) {
        _savedSource = source;
        _repositoryController.text = source.repositoryUrl;
        _branchController.text = source.branch;
        _status = '来源已验证并保存；下次启动时使用。'.tl;
      } else {
        _failure = verification.failure;
      }
    });
  }

  Future<void> _checkForUpdates() async {
    if (_busy) return;
    if (_draftDirty) {
      setState(() {
        _failure = const CatalogSetupFailure(
          CatalogSetupFailureKind.operationInProgress,
          diagnostic: 'repositoryHead:unsavedDraft',
        );
      });
      return;
    }
    final saved = _readSavedSource();
    if (saved == null) {
      setState(() {
        _failure = const CatalogSetupFailure(
          CatalogSetupFailureKind.invalidRepositorySource,
          diagnostic: 'repositoryHead:invalidSavedSource',
        );
      });
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
      _status = null;
    });
    await widget.controller.checkRepositoryUpdate(source: saved);
    if (!mounted) return;
    setState(() => _busy = false);
  }

  void _discardDraft() {
    final saved = _readSavedSource();
    _savedSource = saved;
    _repositoryController.text =
        saved?.repositoryUrl ?? CatalogRepositorySource.defaultRepositoryUrl;
    _branchController.text =
        saved?.branch ?? CatalogRepositorySource.defaultBranch;
    setState(() {
      _failure = null;
      _status = null;
    });
  }

  Future<void> _restartToUpdate() async {
    final action = widget.restartAction;
    if (action != null) {
      await action();
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('重启并更新'.tl),
        content: SingleChildScrollView(
          child: Text(
            '请完全关闭 Venera，然后再打开。\n\n'
                    '届时应用会检查并更新配置。请等待正在进行的保存、上传、下载或数据同步完成后再关闭应用。'
                .tl,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('知道了'.tl),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final runtime = widget.controller.runtimePointer;
    final latest = widget.controller.latestRepositoryCheck;
    final updateAvailable = widget.controller.hasRepositoryUpdate;
    final checkSourceMatchesSaved =
        latest?.source != null && latest!.source == _readSavedSource();
    return Scaffold(
      appBar: Appbar(title: Text('配置仓库'.tl)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _repositoryStatusCard(
            context,
            title: '已保存目标',
            lines: _savedSource == null
                ? ['保存的设备来源无效，请在下方修复并重新保存'.tl]
                : [
                    _savedSource!.repositoryUrl,
                    '${'分支'.tl}: ${_savedSource!.branch}',
                  ],
          ),
          const SizedBox(height: 12),
          _repositoryStatusCard(
            context,
            title: '当前运行版本',
            lines: runtime == null
                ? ['当前没有可用的漫画源配置'.tl]
                : [
                    'https://github.com/${runtime.catalogId}',
                    '${'提交'.tl}: ${_shortCommit(runtime.revision)}',
                  ],
            footer: widget.controller.usingLocalFallback
                ? '${'正在使用本地版本'.tl}：'
                      '${_fallbackReasonText(widget.controller.localFallbackReason)}'
                : null,
            emphasizeFooter: widget.controller.usingLocalFallback,
          ),
          const SizedBox(height: 20),
          TextField(
            key: const Key('repository-url-field'),
            controller: _repositoryController,
            enabled: !_busy,
            keyboardType: TextInputType.url,
            onChanged: (_) => setState(() {
              _failure = null;
              _status = null;
            }),
            decoration: InputDecoration(
              labelText: 'GitHub 配置仓库'.tl,
              hintText: 'https://github.com/owner/repo',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('repository-branch-field'),
            controller: _branchController,
            enabled: !_busy,
            onChanged: (_) => setState(() {
              _failure = null;
              _status = null;
            }),
            decoration: InputDecoration(
              labelText: '分支'.tl,
              hintText: CatalogRepositorySource.defaultBranch,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  key: const Key('verify-repository-button'),
                  onPressed: _busy ? null : _verifyAndSave,
                  child: Text(_busy ? '正在处理…'.tl : '验证并保存来源'.tl),
                ),
              ),
              if (_draftDirty) ...[
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _busy ? null : _discardDraft,
                  child: Text('放弃修改'.tl),
                ),
              ],
            ],
          ),
          if (_failure != null) ...[
            const SizedBox(height: 12),
            Text(
              _failureMessage(_failure!.kind),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (_status != null) ...[const SizedBox(height: 12), Text(_status!)],
          const SizedBox(height: 20),
          FilledButton.tonal(
            key: const Key('check-update-button'),
            onPressed: _busy ? null : _checkForUpdates,
            child: Text('检查更新'.tl),
          ),
          const SizedBox(height: 6),
          Text(
            _draftDirty
                ? '存在未保存修改。请先验证保存或放弃修改，再检查已保存来源。'
                : '检查只查询已保存来源的最新提交；不会下载漫画源文件或切换当前配置。'.tl,
          ),
          if (latest != null) ...[
            const SizedBox(height: 16),
            _repositoryStatusCard(
              context,
              title: '最近查询',
              lines: [
                latest.source?.repositoryUrl ?? '保存来源无效'.tl,
                if (latest.source != null)
                  '${'分支'.tl}: ${latest.source!.branch}',
                '${'时间'.tl}: ${latest.checkedAt.toLocal()}',
                '${'状态'.tl}: ${_checkStatusText(latest, updateAvailable: updateAvailable, runtime: runtime, sourceMatchesSaved: checkSourceMatchesSaved, usingLocalFallback: widget.controller.usingLocalFallback)}',
                if (latest.latest != null)
                  '${'检查结果'.tl}: '
                      '${latest.latest!.catalogId}@${_shortCommit(latest.latest!.revision)}',
              ],
            ),
          ],
          if (updateAvailable) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('restart-update-button'),
              onPressed: _busy ? null : _restartToUpdate,
              icon: const Icon(Icons.restart_alt),
              label: Text('重启并更新'.tl),
            ),
            const SizedBox(height: 6),
            Text('保存的目标有新提交。完全关闭再打开后，应用会检查并更新配置。'.tl),
          ],
          const SizedBox(height: 20),
          Text('来源和分支保存在本设备，不参与 WebDAV 或用户数据导入导出。'.tl),
        ],
      ),
    );
  }

  Widget _repositoryStatusCard(
    BuildContext context, {
    required String title,
    required List<String> lines,
    String? footer,
    bool emphasizeFooter = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(line),
            ),
          if (footer != null)
            Text(
              footer,
              style: TextStyle(
                color: emphasizeFooter
                    ? context.colorScheme.error
                    : context.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

String _shortCommit(String revision) =>
    revision.length <= 8 ? revision : revision.substring(0, 8);

String _fallbackReasonText(CatalogLocalFallbackReason? reason) =>
    switch (reason) {
      CatalogLocalFallbackReason.userSelected => '用户选择了本地版本',
      CatalogLocalFallbackReason.repositoryCheckFailed => '配置仓库检查失败',
      CatalogLocalFallbackReason.updatePreparationFailed => '新版本准备失败',
      null => '已保存的本地版本',
    }.tl;

String _checkStatusText(
  CatalogRepositoryCheck check, {
  required bool updateAvailable,
  required CatalogPointer? runtime,
  required bool sourceMatchesSaved,
  required bool usingLocalFallback,
}) {
  if (check.status == CatalogRepositoryCheckStatus.cancelled) {
    return '检查已取消'.tl;
  }
  if (check.status == CatalogRepositoryCheckStatus.failed ||
      check.failure != null) {
    final failure = check.failure;
    return failure == null
        ? '检查失败'.tl
        : '${'检查失败'.tl}：${_failureMessage(failure.kind)}';
  }
  if (!sourceMatchesSaved) return '查询来源与已保存目标不同'.tl;
  final latest = check.latest;
  if (runtime == null) return '检查完成；当前没有运行版本'.tl;
  if (latest == null) return '检查完成'.tl;
  final sameRuntime =
      latest.catalogId == runtime.catalogId &&
      latest.revision == runtime.revision;
  if (sameRuntime) {
    return usingLocalFallback ? '检查完成；当前仍在使用本地版本'.tl : '与当前运行版本一致'.tl;
  }
  if (updateAvailable) return '发现可用更新'.tl;
  return '检查完成'.tl;
}

String _failureMessage(CatalogSetupFailureKind kind) {
  final text = switch (kind) {
    CatalogSetupFailureKind.invalidRepositorySource => '配置来源无效',
    CatalogSetupFailureKind.repositoryHeadUnavailable => '无法获取分支最新提交',
    CatalogSetupFailureKind.invalidRepositoryHead => '分支响应无效',
    CatalogSetupFailureKind.connectionFailed => '无法连接配置仓库',
    CatalogSetupFailureKind.storageUnavailable => '无法保存本地配置',
    CatalogSetupFailureKind.contentPreparationFailed => '配置索引或脚本无效',
    CatalogSetupFailureKind.operationInProgress => '请先处理未保存修改或等待当前操作完成',
    CatalogSetupFailureKind.cancelled => '操作已取消',
  };
  return text.tl;
}
