import 'dart:async';

import 'package:dio/dio.dart';

/// Host-only ownership scope for exactly one semantic query attempt.
///
/// The scope owns the Dio [CancelToken]s that the attempt's JavaScript requests
/// created. It is deliberately Host-private: a source config can neither see it
/// nor receive it as a callback argument, and the JavaScript signatures are
/// unchanged.
///
/// **How the scope reaches `_http`.** Ownership is structural, not propagated.
/// Each attempt owns a disposable QuickJS execution lane, and the lane's
/// `sendMessage` host closure captures this scope when the runtime is created,
/// so every request that can possibly be made from that lane is attributed
/// unambiguously (see `SemanticExecutionLane` and ADR-0017 Amendment 1).
///
/// [run] still exists, and `_http` still falls back to
/// [current] when no lane binding is present, but that ambient-Zone path only
/// covers requests created inside the synchronous `evaluate` entry: a Zone does
/// not survive the `flutter_qjs` job pump, which is exactly why the lane
/// exists. Do not build new guarantees on `run`/`current`.
class SemanticSearchRequestScope {
  static const String defaultCancelReason = 'Semantic search canceled';

  static final Object _zoneKey = Object();

  final Set<CancelToken> _tokens = <CancelToken>{};

  bool _canceled = false;

  String? _cancelReason;

  /// Whether [cancel] has been called. A canceled scope cancels every token
  /// registered afterwards instead of owning it.
  bool get isCanceled => _canceled;

  String? get cancelReason => _cancelReason;

  /// Number of currently owned, not yet unregistered tokens. Exposed for
  /// focused tests and evidence collection only.
  int get ownedTokenCount => _tokens.length;

  /// The scope of the invocation currently running on this [Zone], if any.
  static SemanticSearchRequestScope? get current =>
      Zone.current[_zoneKey] as SemanticSearchRequestScope?;

  /// Runs [body] with this scope visible to [current], including every
  /// asynchronous continuation [body] creates.
  T run<T>(T Function() body) {
    return runZoned<T>(body, zoneValues: <Object, Object>{_zoneKey: this});
  }

  /// Adopts [token] into this invocation.
  ///
  /// Registering on an already canceled scope cancels the token immediately,
  /// so a request created after cancellation can never reach the network.
  void register(CancelToken token) {
    if (_canceled) {
      if (!token.isCancelled) {
        token.cancel(_cancelReason ?? defaultCancelReason);
      }
      return;
    }
    _tokens.add(token);
  }

  /// Releases [token] once its request settled. Unregistering an unknown token
  /// is a no-op.
  void unregister(CancelToken token) {
    _tokens.remove(token);
  }

  /// Cancels every owned token. Repeated calls are no-ops and never cancel a
  /// token twice.
  void cancel([String reason = defaultCancelReason]) {
    if (_canceled) return;
    _canceled = true;
    _cancelReason = reason;
    final pending = List<CancelToken>.from(_tokens);
    _tokens.clear();
    for (final token in pending) {
      if (!token.isCancelled) {
        token.cancel(reason);
      }
    }
  }
}
