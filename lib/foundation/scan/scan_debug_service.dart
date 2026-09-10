import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../comic_source/comic_source.dart';
import '../catalog/source_preferences.dart';
import 'bounded_work_queue.dart';
import 'execution_guard.dart';
import 'failure_sanitizer.dart';
import 'full_scan_planner.dart';
import 'models.dart';
import 'scan_call_lease.dart';
import 'scan_emission.dart';
import 'scan_executor.dart';
import 'scan_limits.dart';
import 'scan_result_repository.dart';
import 'sqlite_scan_result_repository.dart';
import 'target_provider.dart';

/// The single product-facing coordinator for the Debug full scan.
///
/// It owns the one-run lock, the bounded queue and the only persistent event
/// consumer.  Nothing in this service is registered with startup, timers,
/// foreground callbacks or the retired follow-up scanner.
class ScanDebugService {
  ScanDebugService({
    ScanResultRepository? repository,
    ScanTargetProvider? targetProvider,
    FullScanPlanner? planner,
    this.limits = const ScanLimits(),
  }) : repository = repository ?? scanResultRepository,
       targetProvider = targetProvider ?? ScanTargetProvider(),
       planner = planner ?? const FullScanPlanner(),
       _progress = ValueNotifier<ScanProgress>(ScanProgress()) {
    limits.validate();
  }

  final ScanResultRepository repository;
  final ScanTargetProvider targetProvider;
  final FullScanPlanner planner;
  final ScanLimits limits;
  final ValueNotifier<ScanProgress> _progress;

  BoundedWorkQueue<ScanWorkSpec>? _queue;
  final Set<ScanCallLease> _leases = <ScanCallLease>{};
  final Set<ScanExecutionGuard> _guards = <ScanExecutionGuard>{};
  final Queue<_PendingEmission> _emissions = Queue<_PendingEmission>();
  bool _consumerRunning = false;
  bool _consumerStopped = false;
  ScanStorageException? _storageError;
  ScanControlReason? _cancelReason;
  bool _running = false;

  ValueListenable<ScanProgress> get progress => _progress;
  bool get isRunning => _running;

  /// Returns immediately with [FullScanDisposition.alreadyRunning] on
  /// re-entry.  The running operation's progress and targets are untouched.
  Future<FullScanSummary> startFullScan() {
    if (_running) {
      return Future<FullScanSummary>.value(
        FullScanSummary(
          disposition: FullScanDisposition.alreadyRunning,
          progress: _progress.value,
        ),
      );
    }
    _running = true;
    _cancelReason = null;
    _storageError = null;
    return _runFullScan();
  }

  /// Synchronously invalidates all current Work guards and call leases.
  /// The returned Future is intentionally not required by callers; the
  /// active [startFullScan] completes after bounded operations have unwound.
  void cancel([ScanControlReason reason = ScanControlReason.userCanceled]) {
    if (!_running || _cancelReason != null) return;
    _cancelReason = reason;
    _setProgress(_progress.value.copyWith(phase: ScanProgressPhase.canceling));
    for (final guard in _guards.toList()) {
      guard.cancel(reason);
    }
    _queue?.cancel();
    for (final lease in _leases.toList()) {
      lease.close(
        reason: ScanLeaseCloseReason.controlCanceled,
        controlReason: reason,
      );
    }
    _rejectQueuedEmissions(ScanControlException(reason));
  }

  Future<FullScanSummary> _runFullScan() async {
    ScanProgress current = ScanProgress(phase: ScanProgressPhase.discovering);
    _setProgress(current);
    FullScanDisposition disposition = FullScanDisposition.completed;
    String? errorMessage;
    try {
      await repository.ensureOpen();
      if (_cancelReason != null) {
        disposition = FullScanDisposition.canceled;
        return _finish(disposition);
      }
      final snapshot = await targetProvider.snapshot();
      final snapshotCacheGeneration = snapshot.cacheGeneration;
      if (_cancelReason != null) {
        disposition = FullScanDisposition.canceled;
        return _finish(disposition);
      }
      final planned = planner.plan(snapshot);
      current = current.copyWith(
        phase: planned.isEmpty
            ? ScanProgressPhase.running
            : ScanProgressPhase.running,
        discoveredWorks: planned.length,
        skippedSources: snapshot.skippedSources,
      );
      _setProgress(current);

      _queue = BoundedWorkQueue<ScanWorkSpec>(
        capacity: limits.workQueueCapacity,
        maxWorkers: limits.maxWorkers,
        maxWorksPerSource: limits.maxWorksPerSource,
        sourceKeyOf: (work) => work.sourceKey,
      );
      _consumerStopped = false;
      _storageError = null;
      final executor = ScanExecutor(
        repository: repository,
        limits: limits,
        onLeaseCreated: (lease) => _leases.add(lease),
        onLeaseClosed: (lease) => _leases.remove(lease),
      );

      final feeder = _feed(planned);
      final workers = [
        for (var index = 0; index < limits.maxWorkers; index++)
          _worker(executor, snapshotCacheGeneration),
      ];
      await Future.wait([feeder, ...workers]);
      await _drainEmissions();
      if (_storageError != null) {
        disposition = FullScanDisposition.failed;
        errorMessage = _safeError(_storageError!);
      } else if (_cancelReason != null) {
        disposition = FullScanDisposition.canceled;
      }
    } on ScanStorageException catch (error) {
      _storageError ??= error;
      disposition = FullScanDisposition.failed;
      errorMessage = _safeError(error);
    } on ScanControlException {
      disposition = FullScanDisposition.canceled;
    } catch (error) {
      disposition = FullScanDisposition.failed;
      errorMessage = _safeError(error);
    } finally {
      _queue?.cancel();
      _rejectQueuedEmissions(
        _storageError ??
            (_cancelReason == null
                ? const ScanStorageException('scan consumer stopped')
                : ScanControlException(_cancelReason!)),
      );
      await _drainEmissions();
      for (final lease in _leases.toList()) {
        lease.close(
          reason: _cancelReason == null
              ? ScanLeaseCloseReason.completed
              : ScanLeaseCloseReason.controlCanceled,
          controlReason: _cancelReason,
        );
      }
      _leases.clear();
      _guards.clear();
      _queue = null;
      _consumerStopped = false;
      _consumerRunning = false;
      _running = false;
      final finished = _progress.value.copyWith(
        phase: ScanProgressPhase.finished,
        activeWorks: 0,
      );
      _setProgress(finished);
    }
    return FullScanSummary(
      disposition: disposition,
      progress: _progress.value,
      errorMessage: errorMessage,
    );
  }

  Future<void> _feed(List<ScanWorkSpec> works) async {
    final queue = _queue!;
    try {
      for (final work in works) {
        if (_cancelReason != null || _storageError != null) break;
        await queue.add(work);
      }
    } finally {
      queue.finishInput();
    }
  }

  Future<void> _worker(
    ScanExecutor executor,
    int snapshotCacheGeneration,
  ) async {
    final queue = _queue!;
    while (true) {
      final lease = await queue.acquireRunnable();
      if (lease == null) return;
      final spec = lease.work;
      final guard = _makeGuard(spec, snapshotCacheGeneration);
      _guards.add(guard);
      _setProgress(
        _progress.value.copyWith(activeWorks: _progress.value.activeWorks + 1),
      );
      try {
        final work = spec.toWork(guard);
        final outcome = await executor.execute(work, emit: _emit);
        _recordOutcome(outcome);
      } on ScanControlException {
        _recordOutcome(
          const ScanWorkOutcome(status: ScanWorkOutcomeStatus.canceled),
        );
      } on ScanStorageException catch (error) {
        _storageError ??= error;
        _consumerStopped = true;
        _cancelWorkersForStorageFailure();
        return;
      } catch (error) {
        // A source/codec implementation bug is isolated to this Work.  The
        // executor normally turns acquisition errors into a failure envelope;
        // this final boundary prevents one malformed adapter from taking the
        // process down without a durable scope result.
        _recordOutcome(
          const ScanWorkOutcome(status: ScanWorkOutcomeStatus.failed),
        );
      } finally {
        _guards.remove(guard);
        final remainingActive = _progress.value.activeWorks - 1;
        _setProgress(
          _progress.value.copyWith(
            activeWorks: remainingActive < 0 ? 0 : remainingActive,
          ),
        );
        lease.release();
      }
    }
  }

  ScanExecutionGuard _makeGuard(
    ScanWorkSpec spec,
    int snapshotCacheGeneration,
  ) {
    final source = spec.source;
    // Production target providers attach this metadata while discovering the
    // frozen work list. Keep the fallback only for older synthetic test specs
    // that predate the snapshot field.
    final sourceSnapshot =
        spec.sourceSnapshot ??
        ScanSourceSnapshot(
          managed: ComicSource.find(spec.sourceKey) != null,
          accountIdentity: _accountSnapshot(source),
        );
    final account = sourceSnapshot.accountIdentity;
    return ScanExecutionGuard(
      sourceKey: spec.sourceKey,
      sourceInstance: source,
      runtimeContext: source.runtimeContext,
      accountSnapshot: account,
      cacheGeneration: snapshotCacheGeneration,
      sourceIsCurrent: () {
        final current = ComicSource.find(spec.sourceKey);
        if (sourceSnapshot.managed) {
          return identical(current, source);
        }
        // Explicitly injected/synthetic sources are allowed to live outside
        // the global manager, while a later same-key replacement is still
        // rejected if one appears during the run.
        return current == null || identical(current, source);
      },
      sourceIsEnabled: () {
        if (!sourceSnapshot.managed) {
          final current = ComicSource.find(spec.sourceKey);
          return current == null || identical(current, source);
        }
        return isSourceEnabled(spec.sourceKey);
      },
      currentAccount: () => _accountSnapshot(source),
      currentCacheGeneration: () => targetProvider.cache.cacheGeneration,
    );
  }

  static List<String> _accountSnapshot(ComicSource source) {
    final raw = source.data['account'];
    if (raw is! Iterable) return const [];
    // ComicSource stores the login pair as [account, secret].  A scan guard
    // must freeze only the account identity: a token/password refresh for the
    // same account is expected and must not cancel an in-flight scan.  The
    // secret is also deliberately never copied into the guard snapshot.
    for (final value in raw) {
      if (value is String && value.isNotEmpty) return [value];
    }
    return const [];
  }

  Future<void> _emit(ScanEmission emission, ScanIngestionContext context) {
    if (_consumerStopped) {
      final error =
          _storageError ??
          (_cancelReason == null
              ? const ScanStorageException('scan consumer stopped')
              : ScanControlException(_cancelReason!));
      emission.reject(error);
      return emission.completion;
    }
    final pending = _PendingEmission(emission, context);
    _emissions.add(pending);
    _startConsumer();
    return emission.completion;
  }

  void _startConsumer() {
    if (_consumerRunning) return;
    _consumerRunning = true;
    unawaited(_pumpConsumer());
  }

  Future<void> _pumpConsumer() async {
    try {
      while (_emissions.isNotEmpty) {
        final pending = _emissions.removeFirst();
        if (_consumerStopped) {
          final error =
              _storageError ??
              const ScanStorageException('scan consumer stopped');
          pending.emission.reject(error);
          continue;
        }
        try {
          final event = pending.emission.event;
          if (event is ScanItemEvent) {
            final result = await repository.saveItem(
              pending.context,
              event.item,
            );
            if (result.written) {
              _setProgress(
                _progress.value.copyWith(
                  persistedItems: _progress.value.persistedItems + 1,
                ),
              );
            }
          } else if (event is ScanScopeCompletedEvent) {
            await repository.finishScope(
              pending.context,
              ScanScopeStatus.completed,
            );
          } else if (event is ScanScopeFailedEvent) {
            await repository.finishScope(
              pending.context,
              ScanScopeStatus.failed,
              failure: event.failure,
            );
          } else {
            throw const ScanStorageException('unknown scan event');
          }
          pending.emission.acknowledge();
        } on ScanStorageException catch (error, stack) {
          _storageError ??= error;
          _consumerStopped = true;
          pending.emission.reject(error, stack);
          _cancelWorkersForStorageFailure();
          _rejectQueuedEmissions(error);
        } catch (error, stack) {
          pending.emission.reject(error, stack);
        }
      }
    } finally {
      _consumerRunning = false;
      if (_emissions.isNotEmpty && !_consumerStopped) _startConsumer();
    }
  }

  Future<void> _drainEmissions() async {
    while (_consumerRunning || _emissions.isNotEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void _rejectQueuedEmissions(Object error) {
    while (_emissions.isNotEmpty) {
      final pending = _emissions.removeFirst();
      pending.emission.reject(error);
    }
  }

  void _cancelWorkersForStorageFailure() {
    _queue?.cancel();
    for (final guard in _guards.toList()) {
      guard.cancel(ScanControlReason.sourceInvalidated, 'storage failure');
    }
    for (final lease in _leases.toList()) {
      lease.close(
        reason: ScanLeaseCloseReason.controlCanceled,
        controlReason: ScanControlReason.sourceInvalidated,
      );
    }
  }

  void _recordOutcome(ScanWorkOutcome outcome) {
    final progress = _progress.value;
    _setProgress(
      progress.copyWith(
        succeededWorks:
            progress.succeededWorks +
            (outcome.status == ScanWorkOutcomeStatus.completed ? 1 : 0),
        failedWorks:
            progress.failedWorks +
            (outcome.status == ScanWorkOutcomeStatus.failed ? 1 : 0),
        canceledWorks:
            progress.canceledWorks +
            (outcome.status == ScanWorkOutcomeStatus.canceled ? 1 : 0),
      ),
    );
  }

  FullScanSummary _finish(FullScanDisposition disposition) {
    final progress = _progress.value.copyWith(
      phase: ScanProgressPhase.finished,
    );
    _setProgress(progress);
    return FullScanSummary(disposition: disposition, progress: progress);
  }

  void _setProgress(ScanProgress value) {
    _progress.value = value;
  }

  String _safeError(Object error) {
    final message = error is ScanStorageException
        ? error.message
        : error.runtimeType.toString();
    return FailureSanitizer.sanitize({
          'message': message,
        }, limits: limits).message ??
        'Scan failed';
  }
}

class _PendingEmission {
  _PendingEmission(this.emission, this.context);

  final ScanEmission emission;
  final ScanIngestionContext context;
}

/// The product-owned Debug scan coordinator.  Tests may replace this single
/// entry point to exercise the real menu wiring with an isolated repository;
/// production code never installs a second coordinator.
ScanDebugService scanDebugService = ScanDebugService();
