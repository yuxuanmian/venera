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

class CatalogReady extends CatalogStartupResult {
  const CatalogReady({
    required this.snapshot,
    this.usedLocalFallback = false,
    this.notice,
  });

  final CatalogSnapshot snapshot;
  final bool usedLocalFallback;
  final String? notice;
}

class CatalogNeedsInitialization extends CatalogStartupResult {
  const CatalogNeedsInitialization({
    required this.serverDraft,
    this.hasLegacy = false,
    this.failure,
  });

  final String serverDraft;
  final bool hasLegacy;
  final CatalogSetupFailure? failure;
}

class CatalogNeedsRecovery extends CatalogStartupResult {
  const CatalogNeedsRecovery(this.error);

  final String error;
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
  PreparedRuntime? _publishedRuntime;
  bool _busy = false;
  CatalogAttempt? _currentAttempt;
  bool _preferLocal = false;
  String progressPhase = '';
  int progressCompleted = 0;
  int progressTotal = 0;
  AppCatalogState? _sessionState;
  bool _repairScheduled = false;

  /// The state of the Runtime actually serving this process. This can differ
  /// from the on-disk pointer while a healthy local fallback is in use.
  AppCatalogState? get sessionState => _sessionState;

  CatalogAttempt? get currentAttempt => _currentAttempt;

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

  /// Stops the in-flight Authority attempt and lets boot continue through
  /// the already-known local choices.
  void useLocalVersion() {
    if (!canUseLocalVersion) return;
    _preferLocal = true;
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

  Future<CatalogStartupResult> boot() async {
    if (_busy) return const CatalogNeedsRecovery('Catalog 启动正在进行');
    _busy = true;
    try {
      if (appdata.loadError != null) {
        return _remember(CatalogNeedsRecovery('用户数据无法读取：${appdata.loadError}'));
      }
      AppCatalogState? state;
      try {
        state = appdata.readCatalogState();
      } catch (error) {
        return _remember(CatalogNeedsRecovery('Catalog 状态无法读取：$error'));
      }
      final serverUrl = _savedServerUrl;
      if (state == null || (state.active == null && state.lkg == null)) {
        final inventory = await migration.discover();
        return _remember(
          CatalogNeedsInitialization(
            serverDraft: serverUrl,
            hasLegacy:
                inventory.matched.isNotEmpty || inventory.summary.isNotEmpty,
          ),
        );
      }

      CatalogPointer? authority;
      final authorityAttempt = CatalogAttempt(
        id: 'authority-${DateTime.now().microsecondsSinceEpoch}',
        deadline: DateTime.now().add(catalogAuthorityTimeout),
        allowLocalFallback: true,
      );
      _currentAttempt = authorityAttempt;
      if (serverUrl.isNotEmpty && !_preferLocal) {
        try {
          _reportProgress('查询漫画源配置', 0, 0);
          authority = await httpClient.getAuthority(
            serverUrl,
            attempt: authorityAttempt,
          );
          lastDiagnostic = 'Authority ${authority.identity}';
        } catch (error) {
          lastDiagnostic = 'Authority 查询失败：$error';
        }
      }
      if (authorityAttempt.phase == CatalogAttemptPhase.preparing) {
        if (authority != null || serverUrl.isEmpty || _preferLocal) {
          authorityAttempt.finish();
        } else {
          authorityAttempt.close();
        }
      }
      if (identical(_currentAttempt, authorityAttempt)) {
        _currentAttempt = null;
      }
      final choices = <_CatalogChoice>[];
      if (!_preferLocal && authority != null) {
        choices.add(_CatalogChoice(authority, false));
      }
      final local = <String>{};
      for (final pointer in [state.active, state.lkg]) {
        if (pointer != null && local.add(pointer.identity)) {
          choices.add(_CatalogChoice(pointer, true));
        }
      }
      var index = 0;
      for (final choice in choices) {
        index++;
        final result = await _tryChoice(
          choice,
          state,
          serverUrl: serverUrl,
          budget: normalPrepareBudget,
        );
        if (result != null) return _remember(result);
        _reportProgress('尝试本地可用版本', index, choices.length);
      }
      return _remember(
        CatalogNeedsRecovery(
          state.active == null && state.lkg == null
              ? '没有可用的漫画源配置'
              : '没有可用的本地漫画源版本',
        ),
      );
    } finally {
      _preferLocal = false;
      _busy = false;
    }
  }

  Future<CatalogStartupResult> initialize(String serverUrl) async {
    return _initializeOrRecover(serverUrl.trim(), bootstrap: true);
  }

  Future<CatalogStartupResult> recover(String serverUrl) async {
    return _initializeOrRecover(serverUrl.trim(), bootstrap: true);
  }

  Future<CatalogStartupResult> _initializeOrRecover(
    String serverUrl, {
    required bool bootstrap,
  }) async {
    if (_busy) return const CatalogNeedsRecovery('Catalog 初始化正在进行');
    if (appdata.loadError != null) {
      return _remember(CatalogNeedsRecovery('用户数据无法读取：${appdata.loadError}'));
    }
    _busy = true;
    final attempt = CatalogAttempt(
      id: 'bootstrap-${DateTime.now().microsecondsSinceEpoch}',
      deadline: DateTime.now().add(
        bootstrap ? catalogBootstrapPrepareBudget : catalogNormalPrepareBudget,
      ),
    );
    _currentAttempt = attempt;
    CatalogCandidate? candidate;
    PreparedRuntime? runtime;
    PreparedAppDataCommit? handle;
    var published = false;
    var copyApplied = false;
    LegacyCopyEffect? copyEffect;
    var stage = CatalogSetupStage.authority;
    try {
      final base = CatalogServerUrl.parse(serverUrl);
      final isLegacyMigration = appdata.catalogRuntime == null;
      _reportProgress('连接并获取漫画源配置', 0, 0);
      final pointer = await attempt.waitFor(
        () => httpClient.getAuthority(base.normalized, attempt: attempt),
      );
      stage = CatalogSetupStage.snapshot;
      final existingEnabled =
          preferences.enabledSources ?? _readEnabledFromSettings();
      var inventory = await attempt.waitFor(() => migration.discover());
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
      // Identify the legacy variant before either probe or final preparation.
      // The multi-account source intentionally shares the old data filename,
      // so its in-memory copy must already be present when its JS definition
      // reads settings during construction.
      inventory = await attempt.waitFor(
        () => migration.discover(catalog: downloaded.index),
      );
      final copy = await attempt.waitFor(
        () => migration.prepareCopyEffect(inventory: inventory),
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
      // Data-copy effects are prepared and persisted before the Catalog
      // commit. A failed copy keeps the old executable set for retry.
      // Persist the non-overwriting copy after both preparations succeeded but
      // before the single appdata commit. A failure leaves the old executable
      // set in place and the in-memory Runtime is discarded by the outer path.
      if (copy != null) {
        copyApplied = await attempt.waitFor(
          () => migration.applyCopyEffect(copy),
        );
      }
      final selected = List<String>.from(
        existingEnabled ??
            inventory.matched.keys.where(promoted.index.keys.contains),
      )..sort();
      final nextState = AppCatalogState(active: pointer, lkg: null);
      stage = CatalogSetupStage.commit;
      final preparedHandle = await attempt.waitFor(
        () => appdata.prepareCatalogCommit(
          nextState: nextState,
          nextEnabled: selected,
          nextServerUrl: base.normalized,
          attempt: attempt,
          migrateSourcePages: isLegacyMigration
              ? (settings) {
                  for (final source
                      in preparedRuntime.sources
                          .map((source) => source.value)
                          .whereType<ComicSource>()) {
                    if (selected.contains(source.key) &&
                        inventory.matched.containsKey(source.key)) {
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
            serverDraft: base.normalized,
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
        lastDiagnostic = 'Catalog commit: $error';
        return _remember(CatalogNeedsRecovery('本地漫画源配置无法保存'));
      }
      // The commit linearization point is followed by a synchronous memory
      // install and Runtime publication; no await is inserted between them.
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
      // Cleanup is post-publication best effort. It must never turn a
      // successfully committed and installed Runtime back into initialization.
      try {
        final remaining = await migration.cleanupAfterSuccess(inventory);
        if (remaining.isNotEmpty) lastDiagnostic = '仍有旧执行文件未清理';
      } catch (error) {
        lastDiagnostic = '旧执行文件清理失败：$error';
      }
      return _remember(CatalogReady(snapshot: promoted));
    } catch (error) {
      attempt.close();
      if (candidate != null) await candidate.discard();
      if (handle != null && !handle.isReleased) await handle.discard();
      if (!published) {
        runtime?.dispose();
        // A newly created multi-account data file is part of the same
        // migration attempt. If the Catalog commit did not publish, remove
        // only that file so a retry observes the original legacy state.
        if (copyApplied && copyEffect != null) {
          try {
            if (await copyEffect.target.exists()) {
              await copyEffect.target.delete();
            }
          } catch (cleanupError) {
            lastDiagnostic = '旧多账号数据回滚失败：$cleanupError';
          }
        }
      }
      final failure = CatalogSetupFailure.fromError(error, stage);
      lastDiagnostic = failure?.diagnostic;
      if (failure != null &&
          (stage == CatalogSetupStage.commit || error is FileSystemException)) {
        return _remember(CatalogNeedsRecovery('本地漫画源配置无法保存或读取'));
      }
      return _remember(
        CatalogNeedsInitialization(
          serverDraft: serverUrl,
          hasLegacy: false,
          failure: failure,
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
    required String serverUrl,
    required Duration budget,
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
    try {
      CatalogSnapshot? snapshot;
      var invalidCachedSnapshot = false;
      try {
        snapshot = await attempt.waitFor(
          () => store.readSnapshot(choice.pointer),
        );
      } on CatalogStorageException catch (error) {
        invalidCachedSnapshot = true;
        lastDiagnostic = '本地快照损坏（${choice.pointer.identity}）：$error';
      }
      if (snapshot == null && !choice.localOnly && serverUrl.isNotEmpty) {
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
        );
      }
      // Once this Runtime is fully prepared, an Authority equal to the
      // persisted LKG must remain publishable even when any subsequent
      // commit-preparation step is cancelled, times out, or fails. Keep that
      // ownership through the complete read/prepare/replace interval; the
      // outer catch is only for failures before Runtime completion.
      final reusePreparedLkg = state.lkg?.sameIdentity(choice.pointer) == true;
      try {
        final oldActive = state.active;
        CatalogSnapshot? oldSnapshot;
        if (oldActive != null) {
          try {
            oldSnapshot = await attempt.waitFor(
              () => store.readSnapshot(oldActive),
            );
          } on CatalogStorageException catch (error) {
            lastDiagnostic = '旧 active 快照不可用：$error';
          }
        }
        final healthyLkg = oldSnapshot == null
            ? await _healthyPointer(
                state.lkg,
                excluding: choice.pointer,
                attempt: attempt,
              )
            : null;
        final nextEnabled = SourcePreferences.afterCatalogTransition(
          enabled: preferences.enabledSources ?? _readEnabledFromSettings(),
          oldIndex: oldSnapshot?.index,
          newIndex: availableSnapshot.index,
          isAuthorityTransition: true,
        );
        final nextState = AppCatalogState(
          active: choice.pointer,
          lkg: oldSnapshot == null ? healthyLkg : oldActive,
          lastAuthority: CatalogLastAuthority(
            catalog: choice.pointer,
            serverUrl: serverUrl,
            checkedAt: DateTime.now().toUtc(),
          ),
        );
        final preparedHandle = await attempt.waitFor(
          () => appdata.prepareCatalogCommit(
            nextState: nextState,
            nextEnabled: nextEnabled,
            attempt: attempt,
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
        preferences.installSilently(nextEnabled);
        preparedRuntime.publish();
        _setPublished(preparedRuntime, state: nextState);
        published = true;
        preparedHandle.release();
        appdata.notifyMemoryChanged();
        preferences.notifyChanged();
        handle = null;
        runtime = null;
        attempt.finish();
        return CatalogReady(snapshot: availableSnapshot);
      } catch (error) {
        attempt.close();
        if (handle != null && !handle.isReleased) {
          await _rollbackCommitHandle(handle);
          handle = null;
        }
        if (reusePreparedLkg && !preparedRuntime.isDisposed) {
          final fallback = _publishPreparedLkg(
            preparedRuntime,
            snapshot: availableSnapshot,
            previous: state,
            attempt: attempt,
          );
          published = true;
          runtime = null;
          return fallback;
        }
        rethrow;
      }
    } catch (error) {
      attempt.close();
      if (handle != null && !handle.isReleased) {
        await _rollbackCommitHandle(handle);
      }
      if (!published) runtime?.dispose();
      lastDiagnostic ??= 'Catalog 启动尝试失败：$error';
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
      lastDiagnostic = 'Catalog 提交回滚失败：$rollbackError';
      if (!handle.isReleased) {
        try {
          await handle.discard();
        } catch (discardError) {
          lastDiagnostic = 'Catalog 提交清理失败：$discardError';
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
    } on CatalogStorageException catch (error) {
      lastDiagnostic = 'LKG 快照不可用：$error';
      return null;
    }
  }

  CatalogReady _publishPreparedLkg(
    PreparedRuntime runtime, {
    required CatalogSnapshot snapshot,
    required AppCatalogState previous,
    required CatalogAttempt attempt,
  }) {
    final state = AppCatalogState(
      active: snapshot.manifest.pointer,
      lkg: null,
      lastAuthority: previous.lastAuthority,
    );
    runtime.publish();
    _setPublished(runtime, state: state);
    attempt.finish();
    _schedulePointerRepair(snapshot.manifest.pointer);
    return CatalogReady(snapshot: snapshot, usedLocalFallback: true);
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

  String get _savedServerUrl {
    final current = appdata.settings['serverUrl'];
    if (current is String && current.trim().isNotEmpty) return current.trim();
    final legacy = appdata.settings['cloudTrackingServerUrl'];
    return legacy is String ? legacy.trim() : '';
  }
}

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
