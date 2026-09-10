import 'dart:async';
import 'dart:collection';

/// A lease for one runnable work item.  The queue owns the global and
/// per-source permits until [release] is called.
class WorkLease<T> {
  WorkLease._(this.work, this.sourceKey, this._release);

  final T work;
  final String sourceKey;
  final void Function() _release;
  bool _released = false;

  bool get isReleased => _released;

  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

/// In-memory, bounded and source-fair work queue.
///
/// The queue deliberately has no persistence or retry behavior.  A caller
/// first feeds it with [add], calls [finishInput], and runs workers which
/// repeatedly await [acquireRunnable].  At most [capacity] items wait in the
/// queue; active work is accounted for by the global and per-source limits.
class BoundedWorkQueue<T> {
  BoundedWorkQueue({
    required this.sourceKeyOf,
    this.capacity = 32,
    this.maxWorkers = 4,
    this.maxWorksPerSource = 2,
  }) {
    if (capacity <= 0) throw ArgumentError.value(capacity, 'capacity');
    if (maxWorkers <= 0) throw ArgumentError.value(maxWorkers, 'maxWorkers');
    if (maxWorksPerSource <= 0) {
      throw ArgumentError.value(maxWorksPerSource, 'maxWorksPerSource');
    }
  }

  final String Function(T work) sourceKeyOf;
  final int capacity;
  final int maxWorkers;
  final int maxWorksPerSource;

  final Map<String, Queue<T>> _pending = <String, Queue<T>>{};
  final Map<String, int> _activeBySource = <String, int>{};
  final List<Completer<void>> _waiters = <Completer<void>>[];
  final List<Completer<void>> _spaceWaiters = <Completer<void>>[];
  int _pendingCount = 0;
  int _activeCount = 0;
  int _roundRobinIndex = 0;
  bool _inputFinished = false;
  bool _closed = false;

  int get pendingCount => _pendingCount;
  int get activeCount => _activeCount;
  bool get isClosed => _closed;
  bool get isInputFinished => _inputFinished;

  Future<void> add(T work) async {
    if (_closed || _inputFinished) {
      throw StateError('work queue is not accepting items');
    }
    while (_pendingCount >= capacity && !_closed) {
      final waiter = Completer<void>();
      _spaceWaiters.add(waiter);
      await waiter.future;
    }
    if (_closed) return;
    final sourceKey = sourceKeyOf(work);
    if (sourceKey.isEmpty) throw ArgumentError.value(sourceKey, 'sourceKey');
    (_pending[sourceKey] ??= Queue<T>()).add(work);
    _pendingCount++;
    _wakeOneWorker();
  }

  Future<void> addAll(Iterable<T> works) async {
    for (final work in works) {
      await add(work);
    }
  }

  void finishInput() {
    if (_inputFinished) return;
    _inputFinished = true;
    _wakeAllWorkers();
  }

  /// Cancels waiting and pending work.  A running [WorkLease] is not force
  /// released here; its owner must let the current bounded operation unwind.
  void cancel() {
    if (_closed) return;
    _closed = true;
    _inputFinished = true;
    _pending.clear();
    _pendingCount = 0;
    _completeAll(_waiters);
    _completeAll(_spaceWaiters);
  }

  /// Stops input without discarding already queued work.
  void closeInput() => finishInput();

  Future<WorkLease<T>?> acquireRunnable() async {
    while (true) {
      final lease = _takeRunnable();
      if (lease != null) return lease;
      if (_closed ||
          (_inputFinished && _pendingCount == 0 && _activeCount == 0)) {
        return null;
      }
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
  }

  WorkLease<T>? _takeRunnable() {
    if (_closed || _activeCount >= maxWorkers || _pendingCount == 0) {
      return null;
    }
    final keys = _pending.keys.toList(growable: false);
    if (keys.isEmpty) return null;
    for (var offset = 0; offset < keys.length; offset++) {
      final index = (_roundRobinIndex + offset) % keys.length;
      final sourceKey = keys[index];
      final active = _activeBySource[sourceKey] ?? 0;
      if (active >= maxWorksPerSource) continue;
      final queue = _pending[sourceKey]!;
      final work = queue.removeFirst();
      _pendingCount--;
      if (queue.isEmpty) _pending.remove(sourceKey);
      _roundRobinIndex = keys.isEmpty ? 0 : (index + 1) % keys.length;
      _activeCount++;
      _activeBySource[sourceKey] = active + 1;
      _completeOne(_spaceWaiters);
      return WorkLease._(work, sourceKey, () => _release(sourceKey));
    }
    return null;
  }

  void _release(String sourceKey) {
    if (_activeCount > 0) _activeCount--;
    final active = _activeBySource[sourceKey] ?? 0;
    if (active <= 1) {
      _activeBySource.remove(sourceKey);
    } else {
      _activeBySource[sourceKey] = active - 1;
    }
    _wakeAllWorkers();
  }

  void _wakeOneWorker() {
    _completeOne(_waiters);
  }

  void _wakeAllWorkers() {
    _completeAll(_waiters);
  }

  static void _completeOne(List<Completer<void>> waiters) {
    if (waiters.isEmpty) return;
    final waiter = waiters.removeAt(0);
    if (!waiter.isCompleted) waiter.complete();
  }

  static void _completeAll(List<Completer<void>> waiters) {
    final current = List<Completer<void>>.from(waiters);
    waiters.clear();
    for (final waiter in current) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }
}
