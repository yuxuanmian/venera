import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/utils/translations.dart';

import 'models.dart';
import 'request_scope.dart';

/// Pure-Dart state machine for one semantic result page.
///
/// It owns the intent gate, the pending buffer, the continuation, the
/// generation and the active Host request scope. It never holds a Widget, a
/// `ScrollController` or a reference to the JavaScript source object, so every
/// transition is testable with a fake [SemanticResolver].
class SemanticSearchController extends ChangeNotifier {
  SemanticSearchController({
    required SemanticQuery query,
    required SemanticResolver resolver,
    int initialGeneration = 1,
  }) : _query = query,
       _resolver = resolver,
       _generation = initialGeneration,
       _revision = resolver.revision {
    _resolver.lifecycle?.addListener(_onSourceLifecycleChanged);
  }

  final SemanticResolver _resolver;

  SemanticQuery _query;

  SemanticQuery get query => _query;

  SemanticCapabilityMode get mode => _resolver.mode;

  final List<Comic> _visible = <Comic>[];

  final List<Comic> _pending = <Comic>[];

  final Set<ComicIdentity> _seen = <ComicIdentity>{};

  SemanticContinuation? _continuation;

  SemanticSearchStatus _status = SemanticSearchStatus.initial;

  /// The Host cancellation group of the current query attempt. Every
  /// invocation of this attempt runs on the execution lane bound to it, so a
  /// leftover promise or timer job from an earlier invocation can never be
  /// attributed to a newer attempt.
  SemanticSearchRequestScope _scope = SemanticSearchRequestScope();

  SemanticSearchRequestScope? _runningScope;

  SemanticFailedInvocation? _failedInvocation;

  String? _errorMessage;

  int _generation;

  int _revision;

  int _emptyRetriesRemaining = 1;

  /// Identity of the cycle that currently owns the intent gate.
  ///
  /// A token rather than a bool: an abandoned cycle must not clear the gate of
  /// the replacement cycle that already took over after a reset.
  Object? _runningCycle;

  bool _disposed = false;

  /// The already-presented, stably ordered results.
  List<Comic> get visible => List<Comic>.unmodifiable(_visible);

  /// Successfully received, de-duplicated results that have not been shown yet.
  List<Comic> get pending => List<Comic>.unmodifiable(_pending);

  SemanticSearchStatus get status => _status;

  SemanticContinuation? get continuation => _continuation;

  /// Whether the source still has a range the user can ask for.
  bool get hasMore => _continuation != null;

  bool get isCanceled => _disposed || _status == SemanticSearchStatus.disposed;

  /// The failed logical input a Retry must replay exactly.
  SemanticFailedInvocation? get failedInvocation => _failedInvocation;

  String? get errorMessage => _errorMessage;

  int get generation => _generation;

  /// Whether a cycle currently owns the intent gate.
  bool get isLoading => _status == SemanticSearchStatus.loading;

  /// Whether an invocation is in flight (test/evidence observation point).
  @visibleForTesting
  SemanticSearchRequestScope? get activeRequestScope => _runningScope;

  /// The cancellation group the next invocation will use.
  @visibleForTesting
  SemanticSearchRequestScope get queryScope => _scope;

  @visibleForTesting
  int get emptyRetriesRemaining => _emptyRetriesRemaining;

  /// Starts the single automatic initial cycle.
  Future<void> start() async {
    if (_disposed) return;
    if (_status != SemanticSearchStatus.initial) return;
    if (_resolver.mode == SemanticCapabilityMode.unsupported) {
      _setStatus(SemanticSearchStatus.unsupported);
      return;
    }
    await _beginCycle();
  }

  /// A new user gesture epoch asked for more content.
  ///
  /// Near-end or short-content status alone never reaches this method; the page
  /// calls it at most once per gesture epoch.
  Future<void> continueWithUserIntent() async {
    if (_disposed) return;
    switch (_status) {
      case SemanticSearchStatus.finished:
      case SemanticSearchStatus.unsupported:
      case SemanticSearchStatus.disposed:
      case SemanticSearchStatus.error:
      case SemanticSearchStatus.loading:
        return;
      case SemanticSearchStatus.initial:
      case SemanticSearchStatus.idle:
      case SemanticSearchStatus.waitingForContinue:
        await _beginCycle();
    }
  }

  /// Replays the exact failed logical input.
  Future<void> retry() async {
    if (_disposed) return;
    if (_status != SemanticSearchStatus.error) return;
    final failed = _failedInvocation;
    if (failed == null) return;
    // A Retry after the generation moved on would replay stale input.
    if (failed.generation != _generation) return;
    await _beginCycle(replay: failed.toSnapshot());
  }

  /// Pull-to-refresh: keep the fixed query and the current options, drop every
  /// result and run one fresh initial cycle.
  Future<void> refresh() async {
    if (_disposed) return;
    await _reset(keepQuery: true);
  }

  /// Sorting/option change: replace the options snapshot and restart.
  Future<void> updateOptions(List<String> options) async {
    if (_disposed) return;
    final next = _query.withOptions(List<String>.from(options));
    if (next == _query) return;
    await _reset(keepQuery: false, query: next);
  }

  Future<void> _reset({required bool keepQuery, SemanticQuery? query}) async {
    // Fixed order: cancel -> invalidate generation -> reset.
    _retireScope();
    _generation++;
    _revision = _resolver.revision;
    if (!keepQuery && query != null) {
      _query = query;
    }
    _visible.clear();
    _pending.clear();
    _seen.clear();
    _continuation = null;
    _failedInvocation = null;
    _errorMessage = null;
    _emptyRetriesRemaining = 1;
    // The abandoned cycle must not clear the replacement cycle's gate.
    _runningCycle = null;
    if (_resolver.mode == SemanticCapabilityMode.unsupported) {
      _setStatus(SemanticSearchStatus.unsupported);
      return;
    }
    _setStatus(SemanticSearchStatus.initial);
    await _beginCycle();
  }

  Future<void> _beginCycle({SemanticInvocationSnapshot? replay}) async {
    if (_disposed) return;
    if (_runningCycle != null) return;
    if (_resolver.mode == SemanticCapabilityMode.unsupported) {
      _setStatus(SemanticSearchStatus.unsupported);
      return;
    }
    final cycle = Object();
    _runningCycle = cycle;
    // A cycle always starts from a full empty-window budget.
    _emptyRetriesRemaining = 1;
    _errorMessage = null;
    _setStatus(SemanticSearchStatus.loading);
    try {
      if (replay == null && _pending.isNotEmpty) {
        // Pending is consumed without a source call and without touching the
        // continuation.
        _appendFromPending();
        _settleAfterAppend();
        return;
      }

      final query = _query;
      var input = replay?.inputContinuation ?? _continuation;
      final scope = _scope;

      while (true) {
        final snapshot = SemanticInvocationSnapshot(
          query: query,
          inputContinuation: input,
          generation: _generation,
        );
        _runningScope = scope;
        final res = await _resolver.load(snapshot, scope);
        _runningScope = null;

        if (_disposed) return;
        // Cancellation and generation are two independent gates; both are
        // required. A canceled scope never becomes an error or an empty window.
        if (scope.isCanceled ||
            snapshot.generation != _generation ||
            _revision != _resolver.revision) {
          return;
        }

        if (res.error) {
          _failedInvocation = SemanticFailedInvocation(
            query: query,
            inputContinuation: input,
            generation: _generation,
          );
          _errorMessage = res.errorMessage ?? 'Semantic search failed'.tl;
          _setStatus(SemanticSearchStatus.error);
          return;
        }

        final result = res.data;
        final next = result.next;
        if (next != null && input != null && next.sameAs(input)) {
          // A non-null cursor that did not advance would loop forever.
          _failedInvocation = SemanticFailedInvocation(
            query: query,
            inputContinuation: input,
            generation: _generation,
          );
          _errorMessage = 'Semantic source cursor did not advance'.tl;
          _setStatus(SemanticSearchStatus.error);
          return;
        }

        final fresh = _filterUnseen(result.comics);
        // Comics and the continuation are committed together, only after the
        // whole invocation succeeded.
        _continuation = next;
        input = next;

        if (fresh.isNotEmpty) {
          _pending.addAll(fresh);
          _appendFromPending();
          _settleAfterAppend();
          return;
        }

        // Duplicates-only counts as an empty window.
        if (next == null) {
          _finish();
          return;
        }
        if (_emptyRetriesRemaining == 0) {
          _setStatus(SemanticSearchStatus.waitingForContinue);
          return;
        }
        _emptyRetriesRemaining--;
      }
    } finally {
      _runningScope = null;
      if (identical(_runningCycle, cycle)) {
        _runningCycle = null;
      }
    }
  }

  List<Comic> _filterUnseen(List<Comic> comics) {
    final fresh = <Comic>[];
    for (final comic in comics) {
      final identity = ComicIdentity.of(comic);
      // First appearance wins; a later duplicate never moves a position.
      if (_seen.add(identity)) {
        fresh.add(comic);
      }
    }
    return fresh;
  }

  void _appendFromPending() {
    final take = _pending.length > semanticSearchAppendLimit
        ? semanticSearchAppendLimit
        : _pending.length;
    if (take == 0) return;
    _visible.addAll(_pending.take(take));
    _pending.removeRange(0, take);
  }

  void _settleAfterAppend() {
    if (_pending.isEmpty && _continuation == null) {
      _finish();
    } else {
      _setStatus(SemanticSearchStatus.idle);
    }
  }

  void _finish() {
    _failedInvocation = null;
    _errorMessage = null;
    _setStatus(SemanticSearchStatus.finished);
  }

  /// Retires the current query attempt: cancel every Dio token the lane owns,
  /// then destroy the lane's runtime. The next invocation runs on a fresh
  /// attempt with a scope nothing can already be registered in.
  void _retireScope() {
    final retired = _scope;
    _scope = SemanticSearchRequestScope();
    retired.cancel();
    unawaited(_resolver.releaseLane(retired));
  }

  void _onSourceLifecycleChanged() {
    if (_disposed) return;
    final revision = _resolver.revision;
    if (revision == _revision) return;
    // Cancel the callbacks created by the old assembly and invalidate their
    // generation before the replacement can contribute a result.
    _revision = revision;
    _retireScope();
    _generation++;
    _failedInvocation = null;
    _runningCycle = null;
  }

  void _setStatus(SemanticSearchStatus status) {
    _status = status;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _resolver.lifecycle?.removeListener(_onSourceLifecycleChanged);
    _retireScope();
    _generation++;
    _status = SemanticSearchStatus.disposed;
    super.dispose();
  }
}
