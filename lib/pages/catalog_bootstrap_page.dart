import 'package:flutter/material.dart';

import 'package:venera/foundation/catalog/controller.dart';
import 'package:venera/foundation/catalog/http_client.dart';
import 'package:venera/utils/translations.dart';

class CatalogBootstrapPage extends StatefulWidget {
  const CatalogBootstrapPage({
    super.key,
    required this.controller,
    required this.serverDraft,
    this.hasLegacy = false,
    this.recovery = false,
    this.failure,
    required this.onReady,
  });

  final CatalogController controller;
  final String serverDraft;
  final bool hasLegacy;
  final bool recovery;
  final CatalogSetupFailure? failure;
  final void Function(CatalogReady result) onReady;

  @override
  State<CatalogBootstrapPage> createState() => _CatalogBootstrapPageState();
}

class _CatalogBootstrapPageState extends State<CatalogBootstrapPage> {
  late final TextEditingController _serverController;
  bool _busy = false;
  String? _error;
  String _phase = '请输入 Venera Server 基础地址';
  int _completed = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _serverController = TextEditingController(text: widget.serverDraft);
    _error = widget.failure == null
        ? (widget.recovery ? _recoveryMessage : null)
        : _failureMessage(widget.failure!.kind);
    widget.controller.addListener(_onControllerProgress);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerProgress);
    _serverController.dispose();
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

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _phase = '正在连接并获取漫画源配置';
    });
    final result = widget.recovery
        ? await widget.controller.recover(_serverController.text)
        : await widget.controller.initialize(_serverController.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result is CatalogNeedsInitialization) {
        _error = result.failure == null
            ? null
            : _failureMessage(result.failure!.kind);
        _phase = '请输入 Venera Server 基础地址';
      } else if (result is CatalogNeedsRecovery) {
        _error = _recoveryMessage;
      } else {
        _phase = '漫画源配置已准备完成';
      }
    });
    if (result is CatalogReady) widget.onReady(result);
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total > 0 ? '（$_completed/$_total）' : '';
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.recovery ? '恢复漫画源配置' : '初始化漫画源配置',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text(_phase + progress),
                if (widget.hasLegacy) ...[
                  const SizedBox(height: 8),
                  const Text('检测到旧版源文件；初始化会保留账号、历史和下载数据。'),
                ],
                const SizedBox(height: 20),
                TextField(
                  controller: _serverController,
                  enabled: !_busy,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Venera Server 基础地址',
                    hintText: '例如 https://server.example/',
                    border: OutlineInputBorder(),
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
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy
                      ? widget.controller.currentAttempt?.phase ==
                                CatalogAttemptPhase.preparing
                            ? widget.controller.cancelCurrentAttempt
                            : null
                      : _submit,
                  child: Text(
                    _busy
                        ? widget.controller.currentAttempt?.phase ==
                                  CatalogAttemptPhase.committing
                              ? '正在提交…'
                              : '取消准备'
                        : '连接并初始化',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String get _recoveryMessage =>
    '${'Unable to save or read the local comic source configuration'.tl}\n${'Check local storage and try again'.tl}';

String _failureMessage(CatalogSetupFailureKind kind) {
  final (title, guidance) = switch (kind) {
    CatalogSetupFailureKind.invalidServerAddress => (
      'Invalid server address',
      'Enter a valid Venera Server base address',
    ),
    CatalogSetupFailureKind.connectionFailed => (
      'Unable to connect to the server',
      'Check your network or server status and try again',
    ),
    CatalogSetupFailureKind.incompatibleServer => (
      'Not a compatible Venera Server',
      'This address does not provide a compatible comic source service',
    ),
    CatalogSetupFailureKind.catalogNotActivated => (
      'The server has not published a comic source catalog',
      'Activate a catalog in the server admin page, then try again',
    ),
    CatalogSetupFailureKind.contentPreparationFailed => (
      'Unable to prepare the comic source catalog',
      'The retrieved catalog could not be loaded. Try again later',
    ),
  };
  return '${title.tl}\n${guidance.tl}';
}
