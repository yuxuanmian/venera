import 'package:flutter/material.dart';

import 'package:venera/foundation/catalog/controller.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/http_client.dart';
import 'package:venera/pages/auth_page.dart';
import 'package:venera/pages/catalog_bootstrap_page.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/utils/translations.dart';

/// Keeps all personal Catalog state behind the existing local unlock. The
/// child is not even built until authentication succeeds, so migration and
/// recovery summaries cannot leak before the unlock boundary.
class CatalogAuthorizationGate extends StatefulWidget {
  const CatalogAuthorizationGate({super.key, required this.child});

  final Widget child;

  @override
  State<CatalogAuthorizationGate> createState() =>
      _CatalogAuthorizationGateState();
}

class _CatalogAuthorizationGateState extends State<CatalogAuthorizationGate> {
  bool _authorized = appdata.settings['authorizationRequired'] != true;

  @override
  Widget build(BuildContext context) {
    if (_authorized) return widget.child;
    return AuthPage(
      onSuccessfulAuth: () {
        if (mounted) setState(() => _authorized = true);
      },
    );
  }
}

/// Single startup boundary for both fresh/legacy initialization and normal
/// updates. Business pages are built only after Catalog Runtime publication.
class CatalogGate extends StatefulWidget {
  const CatalogGate({
    super.key,
    required this.controller,
    required this.ready,
    this.onReady,
  });

  final CatalogController controller;
  final WidgetBuilder ready;
  final Future<void> Function()? onReady;

  @override
  State<CatalogGate> createState() => _CatalogGateState();
}

class _CatalogGateState extends State<CatalogGate> {
  CatalogStartupResult? _result;
  String _phase = '正在检查漫画源配置';
  bool _sourceSelectionHandled = false;
  late final bool _showInitialPreparation;

  @override
  void initState() {
    super.initState();
    _showInitialPreparation = _needsInitialPreparation();
    if (_showInitialPreparation) {
      widget.controller.addListener(_onControllerChanged);
    }
    _boot();
  }

  @override
  void dispose() {
    if (_showInitialPreparation) {
      widget.controller.removeListener(_onControllerChanged);
    }
    super.dispose();
  }

  bool _needsInitialPreparation() {
    final data = widget.controller.appdata;
    if (data.loadError != null) return false;
    try {
      final state = data.readCatalogState();
      return state?.active == null && state?.lkg == null;
    } catch (_) {
      // The controller will show recovery for an unreadable pointer.
      return false;
    }
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _boot() async {
    final result = await widget.controller.boot();
    if (!mounted) return;
    if (result is CatalogReady) {
      setState(
        () => _phase = result.usedLocalFallback ? '正在使用本地版本' : '正在启动应用服务',
      );
      await widget.onReady?.call();
      if (!mounted) return;
    }
    setState(() {
      _result = result;
      _phase = result is CatalogReady ? '漫画源配置已就绪' : '需要完成漫画源配置';
    });
    if (result is CatalogReady && result.usedLocalFallback) {
      _showLocalFallback(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    if (result is CatalogReady) {
      if (result.needsSourceSelection && !_sourceSelectionHandled) {
        return ComicSourceSelectionPage(
          preferences: widget.controller.preferences,
          firstRun: true,
          onComplete: _finishSourceSelection,
          onCancel: _finishSourceSelection,
        );
      }
      return widget.ready(context);
    }
    if (result is CatalogNeedsInitialization) {
      return CatalogBootstrapPage(
        controller: widget.controller,
        repositorySource: result.repositorySource,
        hasLegacy: result.hasLegacy,
        failure: result.failure,
        onReady: (ready) => _finishReady(ready),
      );
    }
    if (result is CatalogNeedsRecovery) {
      return CatalogBootstrapPage(
        controller: widget.controller,
        repositorySource: result.repositorySource,
        recovery: true,
        failure: result.failure,
        onReady: (ready) => _finishReady(ready),
      );
    }
    // Keep the runtime gate on returning launches without showing the setup
    // page. A missing or corrupt snapshot still leads to recovery if needed.
    if (!_showInitialPreparation) {
      return ColoredBox(color: Theme.of(context).scaffoldBackgroundColor);
    }
    final canUseLocal = widget.controller.canUseLocalVersion;
    final attempt = widget.controller.currentAttempt;
    final progressTotal = widget.controller.progressTotal;
    final progressValue = progressTotal > 0
        ? (widget.controller.progressCompleted / progressTotal).clamp(0.0, 1.0)
        : null;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.controller.progressPhase.isEmpty
                  ? _phase
                  : widget.controller.progressPhase,
            ),
            if (progressValue != null) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: 260,
                child: LinearProgressIndicator(value: progressValue),
              ),
            ],
            if (attempt?.phase == CatalogAttemptPhase.preparing) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: widget.controller.cancelCurrentAttempt,
                child: const Text('取消'),
              ),
            ],
            if (canUseLocal) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: widget.controller.useLocalVersion,
                child: const Text('使用本地版本'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _finishReady(CatalogReady ready) async {
    if (!mounted) return;
    setState(() => _phase = ready.usedLocalFallback ? '正在使用本地版本' : '正在启动应用服务');
    await widget.onReady?.call();
    if (!mounted) return;
    setState(() => _result = ready);
    if (ready.usedLocalFallback) _showLocalFallback(ready);
  }

  void _finishSourceSelection() {
    if (mounted) setState(() => _sourceSelectionHandled = true);
  }

  void _showLocalFallback(CatalogReady ready) {
    final reason = switch (ready.localFallbackReason) {
      CatalogLocalFallbackReason.userSelected => '你选择了使用本地版本',
      CatalogLocalFallbackReason.repositoryCheckFailed => '配置仓库检查失败',
      CatalogLocalFallbackReason.updatePreparationFailed => '新版本准备失败',
      null => '当前使用已保存的版本',
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${'正在使用本地版本'.tl}：${reason.tl}')));
    });
  }
}
