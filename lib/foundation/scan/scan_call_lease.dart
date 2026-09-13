import 'dart:async';

import 'package:dio/dio.dart';

import 'execution_guard.dart';
import 'models.dart';

enum ScanLeaseCloseReason { completed, controlCanceled, deadline }

class ScanCallLease {
  ScanCallLease({
    required this.guard,
    this.logLabel,
    Duration? timeout,
    this.onClosed,
  }) {
    if (timeout != null) {
      _timer = Timer(
        timeout,
        () => close(reason: ScanLeaseCloseReason.deadline),
      );
    }
  }

  final ScanExecutionGuard guard;

  /// This call's log identity: `sourceKey` plus a short name hint or page
  /// ordinal (007 Contract L4), or null when the caller has none.
  ///
  /// The lease is the natural carrier because it is already "this one call" —
  /// the executor creates it, the adapter uses it, and the request entry point
  /// already receives it — so adding the label needed **no call-signature
  /// change** anywhere.  Null means "no label": the request log keeps its
  /// original, unprefixed format (L8's backward-compatible half).
  final String? logLabel;

  final void Function(ScanCallLease lease)? onClosed;
  final CancelToken cancelToken = CancelToken();
  final Set<CancelToken> _requests = <CancelToken>{};
  final List<void Function()> _closeListeners = <void Function()>[];
  final Completer<void> _closedCompleter = Completer<void>();
  Timer? _timer;
  bool _closed = false;
  ScanLeaseCloseReason? _reason;
  ScanControlReason? _controlReason;

  bool get isClosed => _closed;
  ScanLeaseCloseReason? get closeReason => _reason;
  ScanControlReason? get controlReason => _controlReason;
  bool get isDeadline => _reason == ScanLeaseCloseReason.deadline;
  bool get isControlCanceled => _reason == ScanLeaseCloseReason.controlCanceled;

  /// Completes when this call is closed for any reason.  Adapters use it to
  /// unwind a source Future which is not itself backed by an HTTP request.
  Future<void> get closed => _closedCompleter.future;

  void addCloseListener(void Function() listener) {
    if (_closed) {
      listener();
    } else {
      _closeListeners.add(listener);
    }
  }

  bool registerRequest(CancelToken token) {
    if (_closed) {
      _cancelToken(token, _cancelMessage());
      return false;
    }
    _requests.add(token);
    return true;
  }

  void unregisterRequest(CancelToken token) => _requests.remove(token);

  void checkOpen() {
    guard.check();
    if (_closed) {
      if (_reason == ScanLeaseCloseReason.deadline) {
        throw const ScanLeaseException(ScanLeaseCloseReason.deadline);
      }
      throw ScanControlException(
        _controlReason ?? ScanControlReason.userCanceled,
      );
    }
  }

  void close({
    ScanLeaseCloseReason reason = ScanLeaseCloseReason.completed,
    ScanControlReason? controlReason,
  }) {
    if (_closed) return;
    _closed = true;
    _reason = reason;
    _controlReason = controlReason;
    _timer?.cancel();
    _timer = null;
    final message = _cancelMessage();
    for (final token in _requests.toList()) {
      _cancelToken(token, message);
    }
    _requests.clear();
    if (!cancelToken.isCancelled) _cancelToken(cancelToken, message);
    _closedCompleter.complete();
    for (final listener in _closeListeners.toList()) {
      listener();
    }
    _closeListeners.clear();
    onClosed?.call(this);
  }

  String _cancelMessage() => switch (_reason) {
    ScanLeaseCloseReason.deadline => 'Scan call deadline',
    ScanLeaseCloseReason.controlCanceled => 'Scan call canceled',
    _ => 'Scan call closed',
  };

  void _cancelToken(CancelToken token, String message) {
    if (!token.isCancelled) token.cancel(message);
  }
}

class ScanLeaseException implements Exception {
  const ScanLeaseException(this.reason);

  final ScanLeaseCloseReason reason;
}
