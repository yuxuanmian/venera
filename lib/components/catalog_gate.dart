import 'package:flutter/material.dart';

import 'package:venera/foundation/catalog/controller.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/http_client.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/auth_page.dart';
import 'package:venera/pages/catalog_bootstrap_page.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/utils/translations.dart';

import 'startup_logo.dart';

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
  static const _servicesTimeout = Duration(seconds: 15);
  static const _storageGrace = Duration(seconds: 5);

  CatalogStartupResult? _result;
  bool _startingServices = false;
  bool _startupFailed = false;
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
    final controller = widget.controller;
    // Preserve the normal remote -> active -> last known good fallback.
    // Allow those attempts their own budgets before limiting the UI's wait
    // for operations such as final storage commits, which cannot be cancelled.
    final budget = _showInitialPreparation
        ? catalogBootstrapPrepareBudget
        : catalogHeadTimeout + controller.normalPrepareBudget * 3;
    CatalogStartupResult result;
    try {
      result = await controller.boot().timeout(budget + _storageGrace);
    } catch (error, stack) {
      _failStartup('Catalog', error, stack);
      return;
    }
    if (!mounted) return;
    if (result is CatalogReady) {
      await _finishReady(result);
    } else {
      setState(() => _result = result);
    }
  }

  void _failStartup(String stage, Object error, StackTrace stack) {
    if (mounted) setState(() => _startupFailed = true);
    Log.error('Startup', '$stage: ${error.runtimeType}', stack);
  }

  @override
  Widget build(BuildContext context) {
    if (_startupFailed) {
      // A timed-out write or initialization can still be draining. Do not
      // let an in-process retry race it or expose a half-initialized home.
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Could not start. Please close and reopen the app.'.tl,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }
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
      return _showInitialPreparation
          ? widget.ready(context)
          : StartupLogo(child: Builder(builder: widget.ready));
    }
    if (!_startingServices && result is CatalogNeedsInitialization) {
      return CatalogBootstrapPage(
        controller: widget.controller,
        repositorySource: result.repositorySource,
        hasLegacy: result.hasLegacy,
        failure: result.failure,
        onReady: (ready) => _finishReady(ready),
      );
    }
    if (!_startingServices && result is CatalogNeedsRecovery) {
      return CatalogBootstrapPage(
        controller: widget.controller,
        repositorySource: result.repositorySource,
        recovery: true,
        failure: result.failure,
        onReady: (ready) => _finishReady(ready),
      );
    }
    if (!_showInitialPreparation || _startingServices) {
      return const StartupLogo();
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
                  ? '正在检查漫画源配置'
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
    if (!mounted || _startingServices) return;
    setState(() => _startingServices = true);
    try {
      await widget.onReady?.call().timeout(_servicesTimeout);
    } catch (error, stack) {
      _failStartup('Local services', error, stack);
      return;
    }
    if (!mounted) return;
    setState(() {
      _startingServices = false;
      _result = ready;
    });
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
