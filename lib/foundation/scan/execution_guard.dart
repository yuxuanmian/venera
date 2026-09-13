import '../catalog/runtime_context.dart';
import 'models.dart';

/// Captures the identity of a Source and the local cache/account generation
/// at the moment a Work starts. It is intentionally independent of a Source's
/// version string.
class ScanExecutionGuard {
  ScanExecutionGuard({
    required this.sourceKey,
    required this.sourceInstance,
    this.runtimeContext,
    Iterable<String>? accountSnapshot,
    required this.cacheGeneration,
    bool Function()? sourceIsCurrent,
    bool Function()? sourceIsEnabled,
    Iterable<String> Function()? currentAccount,
    int Function()? currentCacheGeneration,
  }) : accountSnapshot = List.unmodifiable(accountSnapshot ?? const []),
       _sourceIsCurrent = sourceIsCurrent,
       _sourceIsEnabled = sourceIsEnabled,
       _currentAccount = currentAccount,
       _currentCacheGeneration = currentCacheGeneration;

  final String sourceKey;
  final Object sourceInstance;
  final ManagedSourceContext? runtimeContext;
  final List<String> accountSnapshot;
  final int cacheGeneration;
  final bool Function()? _sourceIsCurrent;
  final bool Function()? _sourceIsEnabled;
  final Iterable<String> Function()? _currentAccount;
  final int Function()? _currentCacheGeneration;

  ScanControlException? _control;

  bool get isCanceled => _control != null;
  ScanControlException? get controlException => _control;

  void cancel(ScanControlReason reason, [String? detail]) {
    _control ??= ScanControlException(reason, detail);
  }

  bool get isValid {
    if (_control != null) return false;
    final context = runtimeContext;
    if (context != null && context.phase != ManagedSourcePhase.published) {
      return false;
    }
    if (_sourceIsCurrent != null && !_sourceIsCurrent()) {
      return false;
    }
    if (_sourceIsEnabled != null && !_sourceIsEnabled()) {
      return false;
    }
    if (_currentCacheGeneration != null &&
        _currentCacheGeneration() != cacheGeneration) {
      return false;
    }
    if (_currentAccount != null &&
        !_sameAccount(_currentAccount(), accountSnapshot)) {
      return false;
    }
    return true;
  }

  void check() {
    if (_control != null) throw _control!;
    if (runtimeContext != null &&
        runtimeContext!.phase != ManagedSourcePhase.published) {
      throw const ScanControlException(ScanControlReason.sourceInvalidated);
    }
    if (_sourceIsCurrent != null && !_sourceIsCurrent()) {
      throw const ScanControlException(ScanControlReason.sourceInvalidated);
    }
    if (_sourceIsEnabled != null && !_sourceIsEnabled()) {
      throw const ScanControlException(ScanControlReason.sourceInvalidated);
    }
    if (_currentCacheGeneration != null &&
        _currentCacheGeneration() != cacheGeneration) {
      throw const ScanControlException(ScanControlReason.cacheInvalidated);
    }
    if (_currentAccount != null &&
        !_sameAccount(_currentAccount(), accountSnapshot)) {
      throw const ScanControlException(ScanControlReason.accountChanged);
    }
  }

  static bool _sameAccount(Iterable<String> a, Iterable<String> b) {
    final left = a.toList(growable: false);
    final right = b.toList(growable: false);
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}
