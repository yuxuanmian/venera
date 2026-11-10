import 'package:flutter/material.dart';

import 'package:venera/foundation/catalog/controller.dart';
import 'package:venera/foundation/catalog/http_client.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/utils/translations.dart';

class CatalogBootstrapPage extends StatefulWidget {
  const CatalogBootstrapPage({
    super.key,
    required this.controller,
    CatalogRepositorySource? repositorySource,
    this.hasLegacy = false,
    this.recovery = false,
    this.failure,
    required this.onReady,
  }) : repositorySource = repositorySource ?? CatalogRepositorySource.defaults;

  final CatalogController controller;
  final CatalogRepositorySource repositorySource;
  final bool hasLegacy;
  final bool recovery;
  final CatalogSetupFailure? failure;
  final void Function(CatalogReady result) onReady;

  @override
  State<CatalogBootstrapPage> createState() => _CatalogBootstrapPageState();
}

class _CatalogBootstrapPageState extends State<CatalogBootstrapPage> {
  late final TextEditingController _repositoryController;
  late final TextEditingController _branchController;
  bool _busy = false;
  String? _error;
  String? _status;
  String _phase = '检查配置仓库';
  int _completed = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _repositoryController = TextEditingController(
      text: widget.repositorySource.repositoryUrl,
    );
    _branchController = TextEditingController(
      text: widget.repositorySource.branch,
    );
    _error = widget.failure == null
        ? (widget.recovery ? _recoveryMessage : null)
        : _failureMessage(widget.failure!.kind);
    widget.controller.addListener(_onControllerProgress);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerProgress);
    _repositoryController.dispose();
    _branchController.dispose();
    super.dispose();
  }

  void _onControllerProgress() {
    if (!mounted) return;
    setState(() {
      _phase = widget.controller.progressPhase.isEmpty
          ? _phase
          : widget.controller.progressPhase;
      _completed = widget.controller.progressCompleted;
      _total = widget.controller.progressTotal;
    });
  }

  CatalogRepositorySource? _parseDraft() {
    try {
      return CatalogRepositorySource.parse(
        _repositoryController.text,
        branch: _branchController.text,
      );
    } on CatalogRepositorySourceException catch (error) {
      setState(() {
        _error = error.code == 'invalid_branch' ? '配置分支无效'.tl : '配置仓库无效'.tl;
      });
      return null;
    }
  }

  Future<void> _verifyAndSave() async {
    if (_busy) return;
    final source = _parseDraft();
    if (source == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
      _phase = '验证配置仓库';
    });
    final verification = await widget.controller.verifyAndSaveRepositorySource(
      source,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (verification.succeeded) {
        _status = '配置来源已验证并保存。';
        _phase = '可以重试准备漫画源配置';
      } else {
        _error = verification.failure == null
            ? '配置来源验证未完成'.tl
            : _failureMessage(verification.failure!.kind);
      }
    });
  }

  Future<void> _retry() async {
    if (_busy) return;
    final source = _parseDraft();
    if (source == null) return;
    CatalogRepositorySource savedSource;
    try {
      savedSource = widget.controller.repositorySource;
    } on CatalogRepositorySourceException {
      setState(() => _error = '请先验证并保存有效的配置来源'.tl);
      return;
    }
    if (source != savedSource) {
      setState(() {
        _error = '来源有未保存修改，请先验证并保存。'.tl;
        _phase = '等待保存配置来源';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
      _phase = '准备漫画源配置';
    });
    final result = widget.recovery
        ? await widget.controller.recoverRepository(savedSource)
        : await widget.controller.initializeRepository(savedSource);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result is CatalogNeedsInitialization) {
        _error = result.failure == null
            ? null
            : _failureMessage(result.failure!.kind);
        _phase = result.failure == null ? '准备已取消' : '初始化未完成，请检查来源后重试';
      } else if (result is CatalogNeedsRecovery) {
        _error = result.failure == null
            ? _recoveryMessage
            : _failureMessage(result.failure!.kind);
        _phase = '恢复未完成';
      } else {
        _status = '漫画源配置已准备完成。';
        _phase = '漫画源配置已就绪';
      }
    });
    if (result is CatalogReady) widget.onReady(result);
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total > 0 ? '（$_completed/$_total）' : '';
    final preparing =
        _busy &&
        widget.controller.currentAttempt?.phase ==
            CatalogAttemptPhase.preparing;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.recovery ? '恢复漫画源配置' : '初始化漫画源配置',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Text('${_phase.tl}$progress'),
                  if (widget.hasLegacy) ...[
                    const SizedBox(height: 8),
                    Text('检测到旧版源文件；初始化会保留账号、历史和下载数据。'.tl),
                  ],
                  const SizedBox(height: 20),
                  TextField(
                    controller: _repositoryController,
                    enabled: !_busy,
                    keyboardType: TextInputType.url,
                    onChanged: (_) => setState(() {
                      _status = null;
                      _error = null;
                    }),
                    decoration: InputDecoration(
                      labelText: 'GitHub 配置仓库'.tl,
                      hintText: 'https://github.com/owner/repo',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _branchController,
                    enabled: !_busy,
                    onChanged: (_) => setState(() {
                      _status = null;
                      _error = null;
                    }),
                    decoration: InputDecoration(
                      labelText: '分支'.tl,
                      hintText: CatalogRepositorySource.defaultBranch,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (_status != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _status!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  OutlinedButton(
                    onPressed: _busy ? null : _verifyAndSave,
                    child: Text('验证并保存来源'.tl),
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed: _busy
                        ? preparing
                              ? widget.controller.cancelCurrentAttempt
                              : null
                        : _retry,
                    child: Text(
                      _busy
                          ? preparing
                                ? '取消准备'.tl
                                : '正在处理…'.tl
                          : widget.recovery
                          ? '重试恢复'.tl
                          : '重试准备'.tl,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String get _recoveryMessage => '${'无法保存或读取本地漫画源配置'.tl}\n${'请检查本地存储后重试'.tl}';

String _failureMessage(CatalogSetupFailureKind kind) {
  final (title, guidance) = switch (kind) {
    CatalogSetupFailureKind.invalidRepositorySource => (
      '配置来源无效',
      '请输入公开 GitHub 仓库地址和有效分支',
    ),
    CatalogSetupFailureKind.repositoryHeadUnavailable => (
      '无法获取配置分支的最新版本',
      '请检查仓库、分支和网络后重试',
    ),
    CatalogSetupFailureKind.invalidRepositoryHead => (
      '配置仓库返回的分支信息无效',
      '请确认仓库和分支属于公开 GitHub 仓库',
    ),
    CatalogSetupFailureKind.connectionFailed => ('无法连接配置仓库', '请检查网络或代理设置后重试'),
    CatalogSetupFailureKind.storageUnavailable => ('无法保存或读取本地配置', '请检查本地存储后重试'),
    CatalogSetupFailureKind.contentPreparationFailed => (
      '漫画源配置准备失败',
      '索引、脚本或本地迁移数据未通过验证',
    ),
    CatalogSetupFailureKind.operationInProgress => ('另一个配置操作正在进行', '请等待当前操作完成'),
    CatalogSetupFailureKind.cancelled => ('配置操作已取消', '可以根据需要重试'),
  };
  return '${title.tl}\n${guidance.tl}';
}
