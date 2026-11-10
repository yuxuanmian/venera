import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../appdata.dart';
import '../app.dart';
import '../comic_source/comic_source.dart';
import 'http_client.dart';
import 'legacy_migration.dart';
import 'models.dart';
import 'runtime_loader.dart';
import 'setup_failure.dart';
import 'source_preferences.dart';
import 'source_pages.dart';
import 'store.dart';

export 'setup_failure.dart';

sealed class CatalogStartupResult {
  const CatalogStartupResult();
}

enum CatalogLocalFallbackReason {
  userSelected,
  repositoryCheckFailed,
  updatePreparationFailed,
}

enum CatalogRepositoryCheckStatus { success, failed, cancelled }

class CatalogRepositoryCheck {
  const CatalogRepositoryCheck({
    this.source,
    required this.checkedAt,
    required this.status,
    this.latest,
    this.failure,
  });

  final CatalogRepositorySource? source;
  final DateTime checkedAt;
  final CatalogRepositoryCheckStatus status;
  final CatalogPointer? latest;
  final CatalogSetupFailure? failure;

  bool get succeeded =>
      status == CatalogRepositoryCheckStatus.success && latest != null;
}

class CatalogRepositoryVerification {
  const CatalogRepositoryVerification({
    required this.source,
    required this.check,
    required this.saved,
    this.failure,
  });

  final CatalogRepositorySource source;
  final CatalogRepositoryCheck check;
  final bool saved;
  final CatalogSetupFailure? failure;

  bool get succeeded => saved && check.succeeded && failure == null;
}

class CatalogReady extends CatalogStartupResult {
  const CatalogReady({
    required this.snapshot,
    this.usedLocalFallback = false,
    this.localFallbackReason,
    this.needsSourceSelection = false,
    this.repositorySource,
    this.notice,
  });

  final CatalogSnapshot snapshot;
  final bool usedLocalFallback;
  final CatalogLocalFallbackReason? localFallbackReason;
  final bool needsSourceSelection;
  final CatalogRepositorySource? repositorySource;
  final String? notice;
}

class CatalogNeedsInitialization extends CatalogStartupResult {
  const CatalogNeedsInitialization({
    this.repositorySource = CatalogRepositorySource.defaults,
    this.hasLegacy = false,
    this.failure,
  });

  final CatalogRepositorySource repositorySource;
  final bool hasLegacy;
  final CatalogSetupFailure? failure;
}

class CatalogNeedsRecovery extends CatalogStartupResult {
  const CatalogNeedsRecovery(
    this.error, {
    this.repositorySource = CatalogRepositorySource.defaults,
    this.failure,
  });

  final String error;
  final CatalogRepositorySource repositorySource;
  final CatalogSetupFailure? failure;
}

class CatalogController extends ChangeNotifier {
  CatalogController({
    required this.store,
    CatalogHttpClient? httpClient,
    CatalogRuntimeLoader? runtimeLoader,
    SourcePreferences? preferences,
    LegacyMigration? migration,
    Appdata? appdata,
    Directory? legacyRoot,
    this.normalPrepareBudget = catalogNormalPrepareBudget,
    this.onProgress,
  }) : httpClient = httpClient ?? CatalogHttpClient(),
       runtimeLoader = runtimeLoader ?? CatalogRuntimeLoader(),
       preferences =
           preferences ??
           SourcePreferences(
             initial: SourcePreferences.normalizeOrPrevious(
               (appdata ?? globalsAppdata).settings['enabledSources'],
               null,
             ),
           ),
       migration =
           migration ??
           LegacyMigration(legacyRoot ?? _defaultLegacyRoot(store)),
       appdata = appdata ?? globalsAppdata;

  final CatalogStore store;
  final CatalogHttpClient httpClient;
  final CatalogRuntimeLoader runtimeLoader;
  final SourcePreferences preferences;
  final LegacyMigration migration;
  final Appdata appdata;
  final Duration normalPrepareBudget;
  final void Function(String phase, int completed, int total)? onProgress;

  CatalogStartupResult? lastResult;
  String? lastDiagnostic;
  CatalogRepositoryCheck? latestRepositoryCheck;
  PreparedRuntime? _publishedRuntime;
  bool _busy = false;
  CatalogAttempt? _currentAttempt;
  bool _preferLocal = false;
  CatalogLocalFallbackReason? _localFallbackReason;
  CatalogSetupFailure? _lastTryFailure;
  String progressPhase = '';
  int progressCompleted = 0;
  int progressTotal = 0;
  AppCatalogState? _sessionState;
  bool _repairScheduled = false;

  /// The state of the Runtime actually serving this process. This can differ
  /// from the on-disk pointer while a healthy local fallback is in use.
  AppCatalogState? get sessionState => _sessionState;

  CatalogAttempt? get currentAttempt => _currentAttempt;

  CatalogPointer? get runtimePointer {
    final state = _sessionState;
    if (state?.active != null) return state!.active;
    final result = lastResult;
    return result is CatalogReady ? result.snapshot.manifest.pointer : null;
  }

  bool get usingLocalFallback {
    final result = lastResult;
    return result is CatalogReady && result.usedLocalFallback;
  }

  CatalogLocalFallbackReason? get localFallbackReason {
    final result = lastResult;
    return result is CatalogReady ? result.localFallbackReason : null;
  }

  bool get hasRepositoryUpdate {
    final check = latestRepositoryCheck;
    final runtime = runtimePointer;
    if (check == null ||
        !check.succeeded ||
        check.latest == null ||
        runtime == null) {
      return false;
    }
    try {
      if (check.source != repositorySource) return false;
    } on CatalogRepositorySourceException {
      return false;
    }
    final latest = check.latest!;
    return latest.catalogId != runtime.catalogId ||
        latest.revision != runtime.revision;
  }

  CatalogRepositorySource get repositorySource {
    final rawUrl = appdata.settings['catalogRepositoryUrl'];
    final rawBranch = appdata.settings['catalogRepositoryBranch'];
    final repositoryUrl =
        rawUrl == null || rawUrl is String && rawUrl.trim().isEmpty
        ? CatalogRepositorySource.defaultRepositoryUrl
        : rawUrl is String
        ? rawUrl
        : throw const CatalogRepositorySourceException(
            'invalid_repository_url',
            '配置仓库地址无效',
          );
    final branch =
        rawBranch == null || rawBranch is String && rawBranch.trim().isEmpty
        ? CatalogRepositorySource.defaultBranch
        : rawBranch is String
        ? rawBranch
        : throw const CatalogRepositorySourceException(
            'invalid_branch',
            '配置分支无效',
          );
    return CatalogRepositorySource.parse(repositoryUrl, branch: branch);
  }

  bool get canUseLocalVersion =>
      _currentAttempt?.allowLocalFallback == true &&
      _currentAttempt?.phase == CatalogAttemptPhase.preparing;

  void cancelCurrentAttempt() {
    final attempt = _currentAttempt;
    if (attempt?.phase == CatalogAttemptPhase.preparing) {
      attempt!.close();
      notifyListeners();
    }
  }

  /// Stops the in-flight repository check and lets boot continue through the
  /// already-known local choices.
  void useLocalVersion() {
    if (!canUseLocalVersion) return;
    _preferLocal = true;
    _localFallbackReason = CatalogLocalFallbackReason.userSelected;
    final attempt = _currentAttempt;
    if (attempt?.isOpen == true) attempt!.close();
    notifyListeners();
  }

  void _reportProgress(String phase, int completed, int total) {
    progressPhase = phase;
    progressCompleted = completed;
    progressTotal = total;
    onProgress?.call(phase, completed, total);
    notifyListeners();
  }

  Future<CatalogRepositoryCheck> checkRepositoryUpdate({
    CatalogRepositorySource? source,
  }) async {
    final checkedAt = DateTime.now().toUtc();
    CatalogRepositorySource? selectedSource = source;
    CatalogSetupFailure? sourceFailure;
    if (selectedSource == null) {
      try {
        selectedSource = repositorySource;
      } catch (error) {
        sourceFailure = _failureFor(error, CatalogSetupStage.repositoryHead);
      }
    }
    if (selectedSource == null) {
      final check = CatalogRepositoryCheck(
        checkedAt: checkedAt,
        status: CatalogRepositoryCheckStatus.failed,
        failure: sourceFailure,
      );
      latestRepositoryCheck = check;
      lastDiagnostic = sourceFailure?.diagnostic;
      notifyListeners();
      return check;
    }
    if (_busy) {
      final check = CatalogRepositoryCheck(
        source: selectedSource,
        checkedAt: checkedAt,
        status: CatalogRepositoryCheckStatus.failed,
        failure: const CatalogSetupFailure(
          CatalogSetupFailureKind.operationInProgress,
          diagnostic: 'repositoryHead:operationInProgress',
        ),
      );
      latestRepositoryCheck = check;
      notifyListeners();
      return check;
    }
    _busy = true;
    final attempt = CatalogAttempt(
      id: 'repository-check-${DateTime.now().microsecondsSinceEpoch}',
      deadline: DateTime.now().add(catalogHeadTimeout),
    );
    _currentAttempt = attempt;
    try {
      _reportProgress('查询配置仓库', 0, 0);
      final pointer = await httpClient.resolveRepositoryHead(
        selectedSource,
        attempt: attempt,
      );
      final check = CatalogRepositoryCheck(
        source: selectedSource,
        checkedAt: checkedAt,
        status: CatalogRepositoryCheckStatus.success,
        latest: pointer,
      );
      latestRepositoryCheck = check;
      lastDiagnostic = 'Repository ${pointer.identity}';
      return check;
    } catch (error) {
      final cancelled =
          error is CatalogHttpException && error.code == 'cancelled';
      final failure = _failureFor(error, CatalogSetupStage.repositoryHead);
      final check = CatalogRepositoryCheck(
        source: selectedSource,
        checkedAt: checkedAt,
        status: cancelled
            ? CatalogRepositoryCheckStatus.cancelled
            : CatalogRepositoryCheckStatus.failed,
        failure: failure,
      );
      latestRepositoryCheck = check;
      lastDiagnostic = failure.diagnostic;
      return check;
    } finally {
      if (identical(_currentAttempt, attempt)) _currentAttempt = null;
      _busy = false;
      notifyListeners();
    }
  }

  /// Validates a repository HEAD and root index, then atomically saves the
  /// source. It never downloads scripts or replaces the active Runtime.
  Future<CatalogRepositoryVerification> verifyAndSaveRepositorySource(
    CatalogRepositorySource source,
  ) async {
    final checkedAt = DateTime.now().toUtc();
    if (_busy) {
      final check = CatalogRepositoryCheck(
        source: source,
        checkedAt: checkedAt,
        status: CatalogRepositoryCheckStatus.failed,
        failure: const CatalogSetupFailure(
          CatalogSetupFailureKind.operationInProgress,
          diagnostic: 'repositoryHead:operationInProgress',
        ),
      );
      latestRepositoryCheck = check;
      notifyListeners();
      return CatalogRepositoryVerification(
        source: source,
        check: check,
        saved: false,
        failure: check.failure,
      );
    }
    _busy = true;
    final attempt = CatalogAttempt(
      id: 'repository-verify-${DateTime.now().microsecondsSinceEpoch}',
      deadline: DateTime.now().add(catalogBootstrapPrepareBudget),
    );
    _currentAttempt = attempt;
    CatalogPointer? pointer;
    var stage = CatalogSetupStage.repositoryHead;
    try {
      _reportProgress('查询配置仓库', 0, 0);
      pointer = await httpClient.resolveRepositoryHead(
        source,
        attempt: attempt,
      );
      var check = CatalogRepositoryCheck(
        source: source,
        checkedAt: checkedAt,
        status: CatalogRepositoryCheckStatus.success,
        latest: pointer,
      );
      latestRepositoryCheck = check;
      stage = CatalogSetupStage.indexValidation;
      _reportProgress('验证漫画源配置索引', 0, 0);
      await httpClient.readIndex(pointer, attempt: attempt);
      await appdata.persistRepositorySource(source);
      check = CatalogRepositoryCheck(
        source: source,
        checkedAt: checkedAt,
        status: CatalogRepositoryCheckStatus.success,
        latest: pointer,
      );
      latestRepositoryCheck = check;
      lastDiagnostic = 'Repository ${pointer.identity} verified';
      notifyListeners();
      return CatalogRepositoryVerification(
        source: source,
        check: check,
        saved: true,
      );
    } catch (error) {
      final cancelled =
          error is CatalogHttpException && error.code == 'cancelled';
      final failure = _failureFor(error, stage);
      final check = CatalogRepositoryCheck(
        source: source,
        checkedAt: checkedAt,
        status: cancelled
            ? CatalogRepositoryCheckStatus.cancelled
            : CatalogRepositoryCheckStatus.failed,
        latest: pointer,
        failure: failure,
      );
      latestRepositoryCheck = check;
      lastDiagnostic = failure.diagnostic;
      notifyListeners();
      return CatalogRepositoryVerification(
        source: source,
        check: check,
        saved: false,
        failure: failure,
      );
    } finally {
      attempt.close();
      if (identical(_currentAttempt, attempt)) _currentAttempt = null;
      _busy = false;
      notifyListeners();
    }
  }

  Future<CatalogStartupResult> boot() async {
    final previousResult = lastResult;
    if (previousResult is CatalogReady) return previousResult;
    if (_busy) return const CatalogNeedsRecovery('Catalog 启动正在进行');
    _busy = true;
    try {
      if (appdata.loadError != null) {
        lastDiagnostic = 'commit:storageUnavailable';
        return _remember(
          const CatalogNeedsRecovery(
            '用户数据无法读取',
            failure: CatalogSetupFailure(
              CatalogSetupFailureKind.storageUnavailable,
              diagnostic: 'commit:storageUnavailable',
            ),
          ),
        );
      }
      AppCatalogState? state;
      try {
        state = appdata.readCatalogState();
      } catch (error) {
        lastDiagnostic = 'commit:storageUnavailable';
        return _remember(
          CatalogNeedsRecovery(
            'Catalog 状态无法读取',
            failure: const CatalogSetupFailure(
              CatalogSetupFailureKind.storageUnavailable,
              diagnostic: 'commit:storageUnavailable',
            ),
          ),
        );
      }
      CatalogRepositorySource? source;
      CatalogSetupFailure? sourceFailure;
      try {
        source = repositorySource;
      } catch (error) {
        sourceFailure = _failureFor(error, CatalogSetupStage.repositoryHead);
      }
      if (state == null || (state.active == null && state.lkg == null)) {
        if (source == null) {
          lastDiagnostic = sourceFailure?.diagnostic;
          return _remember(CatalogNeedsInitialization(failure: sourceFailure));
        }
        return _remember(await _initializeRepository(source, bootstrap: true));
      }

      CatalogPointer? latest;
      CatalogSetupFailure? headFailure = sourceFailure;
      final checkedAt = DateTime.now().toUtc();
      final repositoryAttempt = CatalogAttempt(
        id: 'repository-${DateTime.now().microsecondsSinceEpoch}',
        deadline: DateTime.now().add(catalogHeadTimeout),
        allowLocalFallback: true,
      );
      _currentAttempt = repositoryAttempt;
      if (source == null) {
        latestRepositoryCheck = CatalogRepositoryCheck(
          checkedAt: checkedAt,
          status: CatalogRepositoryCheckStatus.failed,
          failure: headFailure,
        );
        _localFallbackReason ??=
            CatalogLocalFallbackReason.repositoryCheckFailed;
        lastDiagnostic = headFailure?.diagnostic;
      } else if (!_preferLocal) {
        try {
          _reportProgress('查询漫画源配置', 0, 0);
          latest = await httpClient.resolveRepositoryHead(
            source,
            attempt: repositoryAttempt,
          );
          latestRepositoryCheck = CatalogRepositoryCheck(
            source: source,
            checkedAt: checkedAt,
            status: CatalogRepositoryCheckStatus.success,
            latest: latest,
          );
          lastDiagnostic = 'Repository ${latest.identity}';
        } catch (error) {
          headFailure = _failureFor(error, CatalogSetupStage.repositoryHead);
          latestRepositoryCheck = CatalogRepositoryCheck(
            source: source,
            checkedAt: checkedAt,
            status: error is CatalogHttpException && error.code == 'cancelled'
                ? CatalogRepositoryCheckStatus.cancelled
                : CatalogRepositoryCheckStatus.failed,
            failure: headFailure,
          );
          lastDiagnostic = headFailure.diagnostic;
          _localFallbackReason ??=
              CatalogLocalFallbackReason.repositoryCheckFailed;
        }
      } else {
        latestRepositoryCheck = CatalogRepositoryCheck(
          source: source,
          checkedAt: checkedAt,
          status: CatalogRepositoryCheckStatus.cancelled,
          failure: _cancelledFailure(CatalogSetupStage.repositoryHead),
        );
      }
      if (repositoryAttempt.phase == CatalogAttemptPhase.preparing) {
        if (latest != null || _preferLocal) {
          repositoryAttempt.finish();
        } else {
          repositoryAttempt.close();
        }
      }
      if (identical(_currentAttempt, repositoryAttempt)) {
        _currentAttempt = null;
      }
      final choices = <_CatalogChoice>[];
      if (!_preferLocal && latest != null) {
        choices.add(_CatalogChoice(latest, false));
      }
      final local = <String>{};
      for (final pointer in [state.active, state.lkg]) {
        if (pointer != null && local.add(pointer.identity)) {
          choices.add(_CatalogChoice(pointer, true));
        }
      }
      var index = 0;
      _lastTryFailure = null;
      for (final choice in choices) {
        index++;
        final result = await _tryChoice(
          choice,
          state,
          source: source,
          budget: normalPrepareBudget,
          localFallbackReason: choice.localOnly
              ? _localFallbackReason ??
                    CatalogLocalFallbackReason.repositoryCheckFailed
              : null,
        );
        if (result != null) return _remember(result);
        if (!choice.localOnly &&
            _localFallbackReason != CatalogLocalFallbackReason.userSelected) {
          _localFallbackReason =
              CatalogLocalFallbackReason.updatePreparationFailed;
        }
        _reportProgress('尝试本地可用版本', index, choices.length);
      }
      return _remember(
        CatalogNeedsRecovery(
          state.active == null && state.lkg == null
              ? '没有可用的漫画源配置'
              : '没有可用的本地漫画源版本',
          repositorySource: source ?? CatalogRepositorySource.defaults,
          failure:
              _lastTryFailure ??
              headFailure ??
              const CatalogSetupFailure(
                CatalogSetupFailureKind.contentPreparationFailed,
                diagnostic: 'runtime:noHealthySnapshot',
              ),
        ),
      );
    } finally {
      _preferLocal = false;
      _localFallbackReason = null;
      _busy = false;
    }
  }

  Future<CatalogStartupResult> initializeRepository(
    CatalogRepositorySource source,
  ) async {
    final previous = lastResult;
    if (previous is CatalogReady) return previous;
    if (_busy) {
      return _remember(
        CatalogNeedsRecovery(
          'Catalog 初始化正在进行',
          repositorySource: source,
          failure: const CatalogSetupFailure(
            CatalogSetupFailureKind.operationInProgress,
            diagnostic: 'repositoryHead:operationInProgress',
          ),
        ),
      );
    }
    return _initializeRepository(source, bootstrap: true);
  }

  Future<CatalogStartupResult> recoverRepository(
    CatalogRepositorySource source,
  ) async {
    final previous = lastResult;
    if (previous is CatalogReady) return previous;
    if (_busy) {
      return _remember(
        CatalogNeedsRecovery(
          'Catalog 初始化正在进行',
          repositorySource: source,
          failure: const CatalogSetupFailure(
            CatalogSetupFailureKind.operationInProgress,
            diagnostic: 'repositoryHead:operationInProgress',
          ),
        ),
      );
    }
    return _initializeRepository(source, bootstrap: true);
  }

  Future<CatalogStartupResult> _initializeRepository(
    CatalogRepositorySource source, {
    required bool bootstrap,
  }) async {
    if (appdata.loadError != null) {
      return _remember(
        CatalogNeedsRecovery(
          '用户数据无法读取',
          repositorySource: source,
          failure: const CatalogSetupFailure(
            CatalogSetupFailureKind.storageUnavailable,
            diagnostic: 'commit:storageUnavailable',
          ),
        ),
      );
    }
    _busy = true;
    final attempt = CatalogAttempt(
      id: 'repository-bootstrap-${DateTime.now().microsecondsSinceEpoch}',
      deadline: DateTime.now().add(
        bootstrap ? catalogBootstrapPrepareBudget : catalogNormalPrepareBudget,
      ),
    );
    _currentAttempt = attempt;
    final checkedAt = DateTime.now().toUtc();
    CatalogCandidate? candidate;
    PreparedRuntime? runtime;
    PreparedAppDataCommit? handle;
    CatalogPointer? resolvedPointer;
    LegacyInventory? inventory;
    LegacyCopyEffect? copyEffect;
    var published = false;
    var copyApplied = false;
    var stage = CatalogSetupStage.repositoryHead;
    try {
      final isFresh = appdata.catalogRuntime == null;
      final existingEnabled =
          preferences.enabledSources ?? _readEnabledFromSettings();
      _reportProgress('查询配置仓库', 0, 0);
      final pointer = await attempt.waitFor(
        () => httpClient.resolveRepositoryHead(source, attempt: attempt),
      );
      resolvedPointer = pointer;
      latestRepositoryCheck = CatalogRepositoryCheck(
        source: source,
        checkedAt: checkedAt,
        status: CatalogRepositoryCheckStatus.success,
        latest: pointer,
      );
      lastDiagnostic = 'Repository ${pointer.identity}';
      stage = CatalogSetupStage.snapshot;
      inventory = await attempt.waitFor(() => migration.discover());
      final downloaded = await attempt.waitFor(
        () => httpClient.downloadSnapshot(
          pointer,
          store: store,
          attempt: attempt,
          onProgress: (completed, total) =>
              _reportProgress('下载漫画源文件', completed, total),
        ),
        onLate: (lateCandidate) => lateCandidate.discard(),
      );
      candidate = downloaded;
      inventory = await attempt.waitFor(
        () => migration.discover(catalog: downloaded.index),
      );
      final copy = await attempt.waitFor(
        () => migration.prepareCopyEffect(inventory: inventory!),
      );
      copyEffect = copy;
      final downloadedData = _withLegacyCopyData(
        await attempt.waitFor(() => _readSourceData(downloaded.index)),
        copy,
      );
      stage = CatalogSetupStage.runtime;
      await attempt.waitFor(
        () => runtimeLoader.validateCandidate(
          downloaded.snapshot,
          sourceData: downloadedData,
        ),
      );
      final promoted = await attempt.waitFor(
        () => store.promoteCandidate(downloaded, replaceInvalid: true),
      );
      candidate = null;
      final sourceData = downloadedData;
      final preparedRuntime = await attempt.waitFor(
        () => runtimeLoader.prepare(
          promoted,
          sourceData: sourceData,
          onPublish: _installPreparedSources,
        ),
        onLate: (lateRuntime) => lateRuntime.dispose(),
      );
      runtime = preparedRuntime;
      if (copy != null) {
        copyApplied = await attempt.waitFor(
          () => migration.applyCopyEffect(copy),
        );
      }
      final migratedEnabled =
          inventory!.matched.keys
              .where(promoted.index.keys.contains)
              .toSet()
              .cast<String>()
              .toList()
            ..sort();
      final selected = List<String>.from(existingEnabled ?? migratedEnabled)
        ..sort();
      final nextState = AppCatalogState(active: pointer, lkg: null);
      stage = CatalogSetupStage.commit;
      final preparedHandle = await attempt.waitFor(
        () => appdata.prepareCatalogCommit(
          nextState: nextState,
          nextEnabled: selected,
          nextRepositorySource: source,
          attempt: attempt,
          migrateSourcePages: isFresh
              ? (settings) {
                  for (final source
                      in preparedRuntime.sources
                          .map((source) => source.value)
                          .whereType<ComicSource>()) {
                    if (selected.contains(source.key) &&
                        inventory!.matched.containsKey(source.key)) {
                      settings.addAll(defaultSourcePages(settings, source));
                    }
                  }
                }
              : null,
        ),
        onLate: (lateHandle) => lateHandle.discard(),
      );
      handle = preparedHandle;
      if (!attempt.beginCommit()) {
        await preparedHandle.discard();
        preparedRuntime.dispose();
        handle = null;
        runtime = null;
        return _remember(
          CatalogNeedsInitialization(
            repositorySource: source,
            hasLegacy: inventory.matched.isNotEmpty,
          ),
        );
      }
      _reportProgress('正在完成漫画源配置', 0, 0);
      try {
        await preparedHandle.replace();
      } catch (error) {
        await preparedHandle.discard();
        preparedRuntime.dispose();
        handle = null;
        runtime = null;
        final failure = _failureFor(error, CatalogSetupStage.commit);
        lastDiagnostic = failure.diagnostic;
        latestRepositoryCheck = CatalogRepositoryCheck(
          source: source,
          checkedAt: checkedAt,
          status: CatalogRepositoryCheckStatus.failed,
          latest: pointer,
          failure: failure,
        );
        return _remember(
          CatalogNeedsRecovery(
            '本地漫画源配置无法保存',
            repositorySource: source,
            failure: failure,
          ),
        );
      }
      preparedHandle.installMemorySilently();
      preferences.installSilently(selected);
      preparedRuntime.publish();
      _setPublished(preparedRuntime, state: nextState);
      published = true;
      preparedHandle.release();
      appdata.notifyMemoryChanged();
      preferences.notifyChanged();
      handle = null;
      runtime = null;
      attempt.finish();
      try {
        final remaining = await migration.cleanupAfterSuccess(inventory);
        if (remaining.isNotEmpty) lastDiagnostic = '仍有旧执行文件未清理';
      } catch (_) {
        lastDiagnostic = '旧执行文件清理失败';
      }
      return _remember(
        CatalogReady(
          snapshot: promoted,
          needsSourceSelection: isFresh && selected.isEmpty,
          repositorySource: source,
        ),
      );
    } catch (error) {
      attempt.close();
      if (candidate != null) await candidate.discard();
      if (handle != null && !handle.isReleased) await handle.discard();
      if (!published) {
        runtime?.dispose();
        if (copyApplied && copyEffect != null) {
          try {
            if (await copyEffect.target.exists()) {
              await copyEffect.target.delete();
            }
          } catch (_) {
            lastDiagnostic = '旧多账号数据回滚失败';
          }
        }
      }
      final cancelled =
          error is CatalogHttpException && error.code == 'cancelled';
      final failure = _failureFor(error, stage);
      latestRepositoryCheck = CatalogRepositoryCheck(
        source: source,
        checkedAt: checkedAt,
        status: cancelled
            ? CatalogRepositoryCheckStatus.cancelled
            : CatalogRepositoryCheckStatus.failed,
        latest: resolvedPointer,
        failure: failure,
      );
      lastDiagnostic = failure.diagnostic;
      if (stage == CatalogSetupStage.commit ||
          failure.kind == CatalogSetupFailureKind.storageUnavailable) {
        return _remember(
          CatalogNeedsRecovery(
            '本地漫画源配置无法保存或读取',
            repositorySource: source,
            failure: failure,
          ),
        );
      }
      return _remember(
        CatalogNeedsInitialization(
          repositorySource: source,
          hasLegacy: inventory?.matched.isNotEmpty == true,
          failure: cancelled ? null : failure,
        ),
      );
    } finally {
      if (identical(_currentAttempt, attempt)) _currentAttempt = null;
      _busy = false;
    }
  }

  Future<CatalogReady?> _tryChoice(
    _CatalogChoice choice,
    AppCatalogState state, {
    required CatalogRepositorySource? source,
    required Duration budget,
    required CatalogLocalFallbackReason? localFallbackReason,
  }) async {
    final attempt = CatalogAttempt(
      id: 'boot-${DateTime.now().microsecondsSinceEpoch}',
      deadline: DateTime.now().add(budget),
      allowLocalFallback: !choice.localOnly,
    );
    _currentAttempt = attempt;
    PreparedRuntime? runtime;
    PreparedAppDataCommit? handle;
    var published = false;
    var failureStage = CatalogSetupStage.snapshot;
    try {
      CatalogSnapshot? snapshot;
      var invalidCachedSnapshot = false;
      try {
        snapshot = await attempt.waitFor(
          () => store.readSnapshot(choice.pointer),
        );
      } on CatalogStorageException {
        invalidCachedSnapshot = true;
        lastDiagnostic = 'snapshot:invalid';
      }
      if (snapshot == null && !choice.localOnly) {
        final candidate = await attempt.waitFor(
          () => httpClient.downloadSnapshot(
            choice.pointer,
            store: store,
            attempt: attempt,
            onProgress: (completed, total) =>
                _reportProgress('下载漫画源文件', completed, total),
          ),
          onLate: (lateCandidate) => lateCandidate.discard(),
        );
        try {
          final probeData = await attempt.waitFor(
            () => _readSourceData(candidate.index),
          );
          await attempt.waitFor(
            () => runtimeLoader.validateCandidate(
              candidate.snapshot,
              sourceData: probeData,
            ),
          );
          snapshot = await attempt.waitFor(
            () => store.promoteCandidate(
              candidate,
              replaceInvalid: invalidCachedSnapshot,
            ),
          );
        } catch (_) {
          await candidate.discard();
          rethrow;
        }
      }
      final availableSnapshot = snapshot;
      if (availableSnapshot == null) return null;
      final sourceData = await attempt.waitFor(
        () => _readSourceData(availableSnapshot.index),
      );
      failureStage = CatalogSetupStage.runtime;
      final preparedRuntime = await attempt.waitFor(
        () => runtimeLoader.prepare(
          availableSnapshot,
          sourceData: sourceData,
          onPublish: _installPreparedSources,
        ),
        onLate: (lateRuntime) => lateRuntime.dispose(),
      );
      runtime = preparedRuntime;
      if (choice.localOnly ||
          state.active?.sameIdentity(choice.pointer) == true) {
        if (!attempt.beginCommit()) {
          preparedRuntime.dispose();
          runtime = null;
          return null;
        }
        final localState = AppCatalogState(
          active: choice.pointer,
          // Keeping a healthy active snapshot for offline startup must not
          // erase the existing fallback. Once the fallback itself is chosen,
          // it is no longer a valid backup for the session.
          lkg:
              choice.localOnly &&
                  state.lkg?.sameIdentity(choice.pointer) == true
              ? null
              : state.lkg,
          lastAuthority: state.lastAuthority,
        );
        preparedRuntime.publish();
        _setPublished(preparedRuntime, state: localState);
        published = true;
        attempt.finish();
        if (choice.localOnly &&
            state.active?.sameIdentity(choice.pointer) != true) {
          _schedulePointerRepair(choice.pointer);
        }
        return CatalogReady(
          snapshot: availableSnapshot,
          usedLocalFallback: choice.localOnly,
          localFallbackReason: localFallbackReason,
          repositorySource: source,
        );
      }
      try {
        final oldActive = state.active;
        CatalogSnapshot? oldSnapshot;
        if (oldActive != null) {
          try {
            oldSnapshot = await attempt.waitFor(
              () => store.readSnapshot(oldActive),
            );
          } on CatalogStorageException {
            lastDiagnostic = 'snapshot:oldActiveInvalid';
          }
        }
        final healthyLkg = oldSnapshot == null
            ? await _healthyPointer(
                state.lkg,
                excluding: choice.pointer,
                attempt: attempt,
              )
            : null;
        final nextState = AppCatalogState(
          active: choice.pointer,
          lkg: oldSnapshot == null ? healthyLkg : oldActive,
        );
        final preparedHandle = await attempt.waitFor(
          () => appdata.prepareCatalogCommit(
            nextState: nextState,
            nextEnabled: preferences.enabledSources,
            nextRepositorySource: source,
            attempt: attempt,
            mutateEnabled: (raw) {
              final current = SourcePreferences.normalizeOrPrevious(
                raw,
                preferences.enabledSources ?? _readEnabledFromSettings(),
              );
              return SourcePreferences.afterCatalogTransition(
                enabled: current,
                oldIndex: oldSnapshot?.index,
                newIndex: availableSnapshot.index,
                isCatalogTransition: true,
              );
            },
          ),
          onLate: (lateHandle) => lateHandle.discard(),
        );
        handle = preparedHandle;
        if (!attempt.beginCommit()) {
          await preparedHandle.discard();
          handle = null;
          throw const CatalogHttpException('cancelled', 'Catalog 提交已取消');
        }
        _reportProgress('正在完成漫画源配置', 0, 0);
        await preparedHandle.replace();
        preparedHandle.installMemorySilently();
        final committedSettings = preparedHandle.document['settings'];
        final committedEnabled = committedSettings is Map
            ? SourcePreferences.normalizeOrPrevious(
                committedSettings['enabledSources'],
                preferences.enabledSources,
              )
            : preferences.enabledSources;
        preferences.installSilently(committedEnabled);
        preparedRuntime.publish();
        _setPublished(preparedRuntime, state: nextState);
        published = true;
        preparedHandle.release();
        appdata.notifyMemoryChanged();
        preferences.notifyChanged();
        handle = null;
        runtime = null;
        attempt.finish();
        return CatalogReady(
          snapshot: availableSnapshot,
          repositorySource: source,
        );
      } catch (error) {
        attempt.close();
        if (handle != null && !handle.isReleased) {
          await _rollbackCommitHandle(handle);
          handle = null;
        }
        rethrow;
      }
    } catch (error) {
      attempt.close();
      if (handle != null && !handle.isReleased) {
        await _rollbackCommitHandle(handle);
      }
      if (!published) runtime?.dispose();
      _lastTryFailure = _failureFor(error, failureStage);
      lastDiagnostic = _lastTryFailure!.diagnostic;
      return null;
    } finally {
      if (attempt.phase == CatalogAttemptPhase.preparing) attempt.close();
      if (identical(_currentAttempt, attempt)) _currentAttempt = null;
    }
  }

  Future<void> _rollbackCommitHandle(PreparedAppDataCommit handle) async {
    if (handle.isReleased) return;
    try {
      await handle.rollback();
    } catch (rollbackError) {
      lastDiagnostic = 'commit:rollbackFailed';
      if (!handle.isReleased) {
        try {
          await handle.discard();
        } catch (discardError) {
          lastDiagnostic = 'commit:cleanupFailed';
        }
      }
    }
  }

  Future<CatalogPointer?> _healthyPointer(
    CatalogPointer? pointer, {
    CatalogPointer? excluding,
    CatalogAttempt? attempt,
  }) async {
    if (pointer == null ||
        excluding != null && pointer.sameIdentity(excluding)) {
      return null;
    }
    try {
      final snapshot = attempt == null
          ? await store.readSnapshot(pointer)
          : await attempt.waitFor(() => store.readSnapshot(pointer));
      return snapshot == null ? null : pointer;
    } on CatalogStorageException {
      lastDiagnostic = 'snapshot:lkgInvalid';
      return null;
    }
  }

  void _schedulePointerRepair(CatalogPointer pointer) {
    if (_repairScheduled) return;
    _repairScheduled = true;
    unawaited(() async {
      try {
        final handle = await appdata.prepareCatalogPointerRepair(pointer);
        try {
          await handle.replace();
          handle.installMemorySilently();
          handle.release();
          appdata.notifyMemoryChanged();
        } catch (error) {
          await handle.discard();
          lastDiagnostic = '本地指针修复失败：$error';
        }
      } catch (error) {
        lastDiagnostic = '本地指针修复失败：$error';
      } finally {
        _repairScheduled = false;
      }
    }());
  }

  CatalogStartupResult _remember(CatalogStartupResult result) {
    lastResult = result;
    return result;
  }

  void _setPublished(PreparedRuntime runtime, {AppCatalogState? state}) {
    _publishedRuntime?.dispose();
    _publishedRuntime = runtime;
    if (state != null) {
      _sessionState = state;
      appdata.sessionCatalogState = state;
    }
  }

  void _installPreparedSources(List<PreparedSource> sources) {
    final comics = sources
        .map((source) => source.value)
        .whereType<ComicSource>()
        .toList(growable: false);
    if (comics.length == sources.length) {
      for (var i = 0; i < comics.length; i++) {
        comics[i].data = Map<String, dynamic>.from(
          sources.elementAt(i).context.data,
        );
      }
      ComicSourceManager().installPreparedSources(comics);
    }
  }

  List<String>? _readEnabledFromSettings() {
    return SourcePreferences.normalizeOrPrevious(
      appdata.settings['enabledSources'],
      null,
    );
  }

  /// Reads only the existing user-owned source data needed to hydrate a
  /// prepared source. This is intentionally separate from Catalog storage:
  /// malformed data is ignored for this session, never rewritten, and never
  /// allowed to alter the active/lkg pointer.
  Future<Map<String, Map<String, dynamic>>> _readSourceData(
    CatalogIndex index,
  ) async {
    final result = <String, Map<String, dynamic>>{};
    for (final entry in index.entries) {
      // Legacy source data lives beside the legacy executable set. Keeping the
      // root on the migration object makes startup work before App's global
      // source manager is initialized and keeps tests on the same production
      // path.
      final file = File('${migration.root.path}/${entry.key}.data');
      try {
        if (!await file.exists()) continue;
        final value = jsonDecode(await file.readAsString());
        if (value is Map) {
          result[entry.key] = Map<String, dynamic>.from(value);
        }
      } catch (error) {
        lastDiagnostic = '源数据读取失败（${entry.key}）：$error';
      }
    }
    return result;
  }

  Map<String, Map<String, dynamic>> _withLegacyCopyData(
    Map<String, Map<String, dynamic>> sourceData,
    LegacyCopyEffect? copy,
  ) {
    if (copy == null || sourceData.containsKey(copy.targetKey)) {
      return sourceData;
    }
    try {
      final value = jsonDecode(utf8.decode(copy.bytes));
      if (value is! Map) return sourceData;
      return <String, Map<String, dynamic>>{
        ...sourceData,
        copy.targetKey: Map<String, dynamic>.from(value),
      };
    } catch (error) {
      lastDiagnostic = '旧多账号数据无法读取：$error';
      return sourceData;
    }
  }
}

CatalogSetupFailure _failureFor(Object error, CatalogSetupStage stage) =>
    CatalogSetupFailure.fromError(error, stage) ?? _cancelledFailure(stage);

CatalogSetupFailure _cancelledFailure(CatalogSetupStage stage) =>
    CatalogSetupFailure(
      CatalogSetupFailureKind.cancelled,
      diagnostic: '${stage.name}:cancelled',
    );

Directory _defaultLegacyRoot(CatalogStore store) {
  try {
    if (App.isInitialized) return Directory('${App.dataPath}/comic_source');
  } catch (_) {
    // App.dataPath is late-initialized in headless/unit-test entry points.
  }
  // The normal store is <app-data>/catalog_runtime. This fallback keeps the
  // legacy directory beside it without ever treating the Catalog store as a
  // source-executable directory.
  return Directory('${store.root.parent.path}/comic_source');
}

class _CatalogChoice {
  const _CatalogChoice(this.pointer, this.localOnly);

  final CatalogPointer pointer;
  final bool localOnly;
}

// Keep the constructor readable without exposing the singleton's historical
// name in the public controller API.
final globalsAppdata = appdata;
