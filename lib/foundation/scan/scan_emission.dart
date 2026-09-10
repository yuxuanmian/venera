import 'dart:async';

import 'models.dart';
import 'scan_result_repository.dart';

sealed class ScanEvent {
  const ScanEvent();
}

class ScanItemEvent extends ScanEvent {
  const ScanItemEvent(this.item);

  final ScanItemResult item;
}

class ScanScopeCompletedEvent extends ScanEvent {
  const ScanScopeCompletedEvent();
}

class ScanScopeFailedEvent extends ScanEvent {
  const ScanScopeFailedEvent(this.failure);

  final ScanFailure failure;
}

/// One in-process event with an explicit persistence acknowledgement.
///
/// The acknowledgement is intentionally not serializable and is never passed
/// into JavaScript.  Producers await it, so a slow repository applies back
/// pressure before another item or page is generated.
class ScanEmission {
  ScanEmission(this.event);

  final ScanEvent event;
  final Completer<void> _completion = Completer<void>();
  bool _settled = false;

  Future<void> get completion => _completion.future;
  bool get isSettled => _settled;

  void acknowledge() {
    if (_settled) return;
    _settled = true;
    _completion.complete();
  }

  void reject(Object error, [StackTrace? stackTrace]) {
    if (_settled) return;
    _settled = true;
    _completion.completeError(error, stackTrace ?? StackTrace.current);
  }

  Future<void> emitAndWaitAck(
    Future<void> Function(ScanEmission emission) consume,
  ) async {
    if (_settled) throw StateError('scan emission was already settled');
    try {
      await consume(this);
    } catch (error, stack) {
      reject(error, stack);
    }
    await completion;
  }
}

/// The small coordinator helper used by tests and the debug service.
class ScanEmissionConsumer {
  ScanEmissionConsumer({required this.repository});

  final ScanResultRepository repository;

  Future<void> consume(
    ScanEmission emission,
    ScanIngestionContext context, {
    void Function(ScanItemWriteResult result)? onItem,
    void Function(ScanScopeWriteResult result)? onScope,
  }) async {
    try {
      final event = emission.event;
      if (event is ScanItemEvent) {
        final result = await repository.saveItem(context, event.item);
        onItem?.call(result);
      } else if (event is ScanScopeCompletedEvent) {
        final result = await repository.finishScope(
          context,
          ScanScopeStatus.completed,
        );
        onScope?.call(result);
      } else if (event is ScanScopeFailedEvent) {
        final result = await repository.finishScope(
          context,
          ScanScopeStatus.failed,
          failure: event.failure,
        );
        onScope?.call(result);
      } else {
        throw StateError('unknown scan event');
      }
      emission.acknowledge();
    } catch (error, stack) {
      emission.reject(error, stack);
      rethrow;
    }
  }
}
