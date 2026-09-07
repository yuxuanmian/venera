import 'package:flutter/material.dart';

import 'package:venera/foundation/catalog/controller.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/http_client.dart';
import 'package:venera/pages/auth_page.dart';
import 'package:venera/pages/catalog_bootstrap_page.dart';

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

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _boot();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _boot() async {
    final result = await widget.controller.boot();
    if (!mounted) return;
    if (result is CatalogReady) {
      setState(() => _phase = '正在启动应用服务');
      await widget.onReady?.call();
      if (!mounted) return;
    }
    setState(() {
      _result = result;
      _phase = result is CatalogReady ? '漫画源配置已就绪' : '需要完成漫画源配置';
    });
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    if (result is CatalogReady) return widget.ready(context);
    if (result is CatalogNeedsInitialization) {
      return CatalogBootstrapPage(
        controller: widget.controller,
        serverDraft: result.serverDraft,
        hasLegacy: result.hasLegacy,
        failure: result.failure,
        onReady: (ready) => _finishReady(ready),
      );
    }
    if (result is CatalogNeedsRecovery) {
      return CatalogBootstrapPage(
        controller: widget.controller,
        serverDraft:
            widget.controller.appdata.settings['serverUrl'] as String? ?? '',
        recovery: true,
        onReady: (ready) => _finishReady(ready),
      );
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
    setState(() => _phase = '正在启动应用服务');
    await widget.onReady?.call();
    if (mounted) setState(() => _result = ready);
  }
}
