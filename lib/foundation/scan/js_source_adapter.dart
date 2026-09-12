import 'dart:async';

import '../catalog/runtime_context.dart';
import 'failure_sanitizer.dart';
import 'models.dart';
import 'scan_call_lease.dart';
import 'scan_limits.dart';
import 'source_adapter.dart';

/// Adapter for a parsed managed Source. It is the only layer that turns
/// ordinary JavaScript/transport errors into the source-facing failure map.
class JsScanSourceAdapter implements ScanSourceAdapter {
  JsScanSourceAdapter({
    required this.sourceKey,
    required this.definitionRevision,
    required this.capabilities,
    required this.requestFactory,
    this.runtimeContext,
    this.limits = const ScanLimits(),
  });

  @override
  final String sourceKey;

  @override
  final String definitionRevision;

  @override
  String? get evidenceSchema => capabilities.selectedEvidenceSchema;

  @override
  final ManagedSourceContext? runtimeContext;

  @override
  final ScanCapabilities capabilities;

  final ScanHostRequestFactory requestFactory;
  final ScanLimits limits;

  @override
  Future<Object?> loadComic(String comicId, ScanCallLease lease) async {
    try {
      if (capabilities.primary != ScanProducer.comic ||
          capabilities.comic == null) {
        return _failure({'message': 'Comic scan capability is unavailable'});
      }
      lease.checkOpen();
      final operation = capabilities.comic!.comicLoad(
        comicId,
        requestFactory(lease),
      );
      return await _awaitLoad(operation, lease);
    } catch (error) {
      return _handleError(error, lease);
    } finally {
      _closeNormally(lease);
    }
  }

  @override
  Future<Object?> loadCollection(
    String collectionKey,
    Object? cursor,
    ScanCallLease lease,
  ) async {
    try {
      if (capabilities.primary != ScanProducer.collection ||
          capabilities.collection == null) {
        return _failure({
          'message': 'Collection scan capability is unavailable',
        });
      }
      lease.checkOpen();
      final operation = capabilities.collection!.collectionLoad(
        collectionKey,
        cursor,
        requestFactory(lease),
      );
      return await _awaitLoad(operation, lease);
    } catch (error) {
      return _handleError(error, lease);
    } finally {
      _closeNormally(lease);
    }
  }

  Future<Object?> _awaitLoad(
    Future<Object?> operation,
    ScanCallLease lease,
  ) async {
    final deadlineCompleter = Completer<void>();
    final deadlineTimer = Timer(
      limits.jsCallTimeout,
      () => deadlineCompleter.complete(),
    );
    final closed = lease.closed.then<Object?>((_) {
      if (lease.isDeadline) {
        throw const ScanLeaseException(ScanLeaseCloseReason.deadline);
      }
      throw ScanControlException(
        lease.controlReason ?? ScanControlReason.userCanceled,
      );
    });
    try {
      return await Future.any<Object?>([
        operation,
        deadlineCompleter.future.then<Object?>(
          (_) => throw const ScanLeaseException(ScanLeaseCloseReason.deadline),
        ),
        closed,
      ]);
    } on ScanLeaseException {
      lease.close(reason: ScanLeaseCloseReason.deadline);
      rethrow;
    } finally {
      deadlineTimer.cancel();
    }
  }

  Object? _handleError(Object error, ScanCallLease lease) {
    // A Work guard has priority over both a load deadline and an arbitrary JS
    // error. The executor will close the scope as canceled and create no
    // failure item in this case.
    try {
      lease.guard.check();
    } on ScanControlException {
      rethrow;
    }
    if (error is ScanControlException) throw error;
    if (error is ScanLeaseException &&
        error.reason == ScanLeaseCloseReason.deadline) {
      return _failure({
        'exceptionType': 'ScanCallTimeout',
        'message': 'Scan call exceeded its deadline',
      });
    }
    if (lease.isDeadline) {
      return _failure({
        'exceptionType': 'ScanCallTimeout',
        'message': 'Scan call exceeded its deadline',
      });
    }
    if (error is ScanHostRequestException) {
      return _failure(error.failure.toJson());
    }
    return _failure({
      'exceptionType': error.runtimeType.toString(),
      'message': 'Scan source operation failed',
    });
  }

  Map<String, dynamic> _failure(Object value) => {
    'failure': FailureSanitizer.sanitize(value, limits: limits).toJson(),
  };

  void _closeNormally(ScanCallLease lease) {
    if (lease.isClosed) return;
    lease.close(reason: ScanLeaseCloseReason.completed);
  }
}
