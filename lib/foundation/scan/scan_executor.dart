import 'dart:async';

import 'execution_guard.dart';
import 'failure_sanitizer.dart';
import 'models.dart';
import 'observation_codec.dart';
import 'scan_call_lease.dart';
import 'scan_emission.dart';
import 'scan_limits.dart';
import 'scan_result_repository.dart';
import 'full_scan_planner.dart';

typedef ScanEmissionSink =
    Future<void> Function(ScanEmission emission, ScanIngestionContext context);

enum ScanWorkOutcomeStatus { completed, failed, canceled }

class ScanWorkOutcome {
  const ScanWorkOutcome({
    required this.status,
    this.persistedItems = 0,
    this.failure,
  });

  final ScanWorkOutcomeStatus status;
  final int persistedItems;
  final ScanFailure? failure;
}

/// Executes one frozen Work.  It contains no retry, evaluator or business
/// update logic; all durable writes are made by the supplied ack consumer.
class ScanExecutor {
  ScanExecutor({
    required this.repository,
    this.limits = const ScanLimits(),
    ObservationCodec? codec,
    DateTime Function()? clock,
    void Function(ScanCallLease lease)? onLeaseCreated,
    void Function(ScanCallLease lease)? onLeaseClosed,
  }) : codec = codec ?? ObservationCodec(limits: limits),
       _clock = clock ?? DateTime.now,
       _onLeaseCreated = onLeaseCreated,
       _onLeaseClosed = onLeaseClosed {
    limits.validate();
  }

  final ScanResultRepository repository;
  final ScanLimits limits;
  final ObservationCodec codec;
  final DateTime Function() _clock;
  final void Function(ScanCallLease lease)? _onLeaseCreated;
  final void Function(ScanCallLease lease)? _onLeaseClosed;

  Future<ScanWorkOutcome> execute(
    ScanWork work, {
    required ScanEmissionSink emit,
  }) async {
    work.guard.check();
    final scope = await repository.beginScope(
      sourceKey: work.sourceKey,
      producer: work.producer,
      scopeKey: work.scopeKey,
      definitionRevision: work.definitionRevision,
      guard: work.guard,
    );
    final context = ScanIngestionContext(scope: scope, guard: work.guard);
    return switch (work.producer) {
      ScanProducer.comic => _executeComic(work, context, emit),
      ScanProducer.collection => _executeCollection(work, context, emit),
    };
  }

  Future<ScanWorkOutcome> _executeComic(
    ScanWork work,
    ScanIngestionContext context,
    ScanEmissionSink emit,
  ) async {
    final comicId = work.comicId;
    if (comicId == null || comicId.isEmpty) {
      return _failScope(
        context,
        emit,
        FailureSanitizer.sanitize({
          'message': 'Comic identity is invalid',
        }, limits: limits),
      );
    }
    try {
      final raw = await _loadComic(work);
      work.guard.check();
      late final ComicScanEnvelope envelope;
      try {
        envelope = codec.decodeComicEnvelope(raw);
      } on ScanCodecException catch (error) {
        envelope = ComicScanEnvelope.failure(
          FailureSanitizer.sanitize({
            'exceptionType': 'ScanCodecException',
            'message': error.code,
          }, limits: limits),
        );
      }
      final attemptId = scanUuidV5(
        context.scope.scopeAttemptId,
        '${work.sourceKey}\u0000$comicId',
      );
      final observedAt = _observedAt();
      final item = envelope.isSuccess
          ? ScanItemResult.observed(
              attemptId: attemptId,
              scopeAttemptId: context.scope.scopeAttemptId,
              sourceKey: work.sourceKey,
              comicId: comicId,
              producer: ScanProducer.comic,
              definitionRevision: work.definitionRevision,
              observedAt: observedAt,
              evidenceSchema: work.evidenceSchema,
              observation: envelope.value!,
            )
          : ScanItemResult.failed(
              attemptId: attemptId,
              scopeAttemptId: context.scope.scopeAttemptId,
              sourceKey: work.sourceKey,
              comicId: comicId,
              producer: ScanProducer.comic,
              definitionRevision: work.definitionRevision,
              observedAt: observedAt,
              evidenceSchema: work.evidenceSchema,
              failure: envelope.failure!,
            );
      await emit(ScanEmission(ScanItemEvent(item)), context);
      work.guard.check();
      if (envelope.isSuccess) {
        await emit(ScanEmission(const ScanScopeCompletedEvent()), context);
        return const ScanWorkOutcome(
          status: ScanWorkOutcomeStatus.completed,
          persistedItems: 1,
        );
      }
      await emit(
        ScanEmission(ScanScopeFailedEvent(envelope.failure!)),
        context,
      );
      return ScanWorkOutcome(
        status: ScanWorkOutcomeStatus.failed,
        persistedItems: 1,
        failure: envelope.failure,
      );
    } on ScanControlException catch (error) {
      await _finishCanceled(context, emit, error);
      return const ScanWorkOutcome(status: ScanWorkOutcomeStatus.canceled);
    } on ScanStorageException {
      rethrow;
    } on ScanResultConflictException {
      rethrow;
    } catch (error) {
      final failure = FailureSanitizer.fromException(error, limits: limits);
      await emit(ScanEmission(ScanScopeFailedEvent(failure)), context);
      return ScanWorkOutcome(
        status: ScanWorkOutcomeStatus.failed,
        failure: failure,
      );
    }
  }

  Future<ScanWorkOutcome> _executeCollection(
    ScanWork work,
    ScanIngestionContext context,
    ScanEmissionSink emit,
  ) async {
    Object? cursor;
    final seenComicIds = <String>{};
    final seenCursors = <String>{'null'};
    var pageCount = 0;
    var persistedItems = 0;
    try {
      while (true) {
        work.guard.check();
        if (pageCount >= limits.maxPagesPerScope) {
          final failure = _limitFailure('maxPagesPerScope');
          await emit(ScanEmission(ScanScopeFailedEvent(failure)), context);
          return ScanWorkOutcome(
            status: ScanWorkOutcomeStatus.failed,
            persistedItems: persistedItems,
            failure: failure,
          );
        }
        pageCount++;
        final raw = await _loadCollection(work, cursor);
        work.guard.check();
        try {
          final sourceFailure = codec.decodeCollectionFailure(raw);
          if (sourceFailure != null) {
            await emit(
              ScanEmission(ScanScopeFailedEvent(sourceFailure)),
              context,
            );
            return ScanWorkOutcome(
              status: ScanWorkOutcomeStatus.failed,
              persistedItems: persistedItems,
              failure: sourceFailure,
            );
          }
        } on ScanCodecException catch (error) {
          final failure = FailureSanitizer.sanitize({
            'exceptionType': 'ScanCodecException',
            'message': error.code,
          }, limits: limits);
          await emit(ScanEmission(ScanScopeFailedEvent(failure)), context);
          return ScanWorkOutcome(
            status: ScanWorkOutcomeStatus.failed,
            persistedItems: persistedItems,
            failure: failure,
          );
        }
        late final ScanCollectionPage page;
        try {
          page = codec.decodeCollectionPage(raw, seenComicIds: seenComicIds);
        } on ScanCodecException catch (error) {
          final failure = FailureSanitizer.sanitize({
            'exceptionType': 'ScanCodecException',
            'message': error.code,
          }, limits: limits);
          await emit(ScanEmission(ScanScopeFailedEvent(failure)), context);
          return ScanWorkOutcome(
            status: ScanWorkOutcomeStatus.failed,
            persistedItems: persistedItems,
            failure: failure,
          );
        }
        if (seenComicIds.length + page.items.length > limits.maxItemsPerScope) {
          final failure = _limitFailure('maxItemsPerScope');
          await emit(ScanEmission(ScanScopeFailedEvent(failure)), context);
          return ScanWorkOutcome(
            status: ScanWorkOutcomeStatus.failed,
            persistedItems: persistedItems,
            failure: failure,
          );
        }

        final observedAt = _observedAt();
        // Only mutate the cross-page identity set after the entire page and
        // its next cursor have passed validation.
        final pageIds = page.items.map((item) => item.comicId).toList();
        Object? next = page.next;
        String? nextFingerprint;
        if (next != null) {
          try {
            nextFingerprint = codec.canonicalJson(next);
          } on ScanCodecException catch (error) {
            final failure = FailureSanitizer.sanitize({
              'exceptionType': 'ScanCodecException',
              'message': error.code,
            }, limits: limits);
            await emit(ScanEmission(ScanScopeFailedEvent(failure)), context);
            return ScanWorkOutcome(
              status: ScanWorkOutcomeStatus.failed,
              persistedItems: persistedItems,
              failure: failure,
            );
          }
          if (!seenCursors.add(nextFingerprint)) {
            final failure = _limitFailure('cursorCycle');
            await emit(ScanEmission(ScanScopeFailedEvent(failure)), context);
            return ScanWorkOutcome(
              status: ScanWorkOutcomeStatus.failed,
              persistedItems: persistedItems,
              failure: failure,
            );
          }
        }
        seenComicIds.addAll(pageIds);

        for (final pageItem in page.items) {
          work.guard.check();
          final attemptId = scanUuidV5(
            context.scope.scopeAttemptId,
            '${work.sourceKey}\u0000${pageItem.comicId}',
          );
          final item = ScanItemResult.observed(
            attemptId: attemptId,
            scopeAttemptId: context.scope.scopeAttemptId,
            sourceKey: work.sourceKey,
            comicId: pageItem.comicId,
            producer: ScanProducer.collection,
            definitionRevision: work.definitionRevision,
            observedAt: observedAt,
            evidenceSchema: work.evidenceSchema,
            observation: pageItem.observation,
          );
          await emit(ScanEmission(ScanItemEvent(item)), context);
          persistedItems++;
        }

        if (next == null) {
          work.guard.check();
          await emit(ScanEmission(const ScanScopeCompletedEvent()), context);
          return ScanWorkOutcome(
            status: ScanWorkOutcomeStatus.completed,
            persistedItems: persistedItems,
          );
        }
        cursor = next;
      }
    } on ScanControlException catch (error) {
      await _finishCanceled(context, emit, error);
      return ScanWorkOutcome(
        status: ScanWorkOutcomeStatus.canceled,
        persistedItems: persistedItems,
      );
    } on ScanStorageException {
      rethrow;
    } on ScanResultConflictException {
      rethrow;
    } catch (error) {
      final failure = FailureSanitizer.fromException(error, limits: limits);
      await emit(ScanEmission(ScanScopeFailedEvent(failure)), context);
      return ScanWorkOutcome(
        status: ScanWorkOutcomeStatus.failed,
        persistedItems: persistedItems,
        failure: failure,
      );
    }
  }

  Future<Object?> _loadComic(ScanWork work) async {
    final lease = _newLease(work.guard);
    var enteredAdapter = false;
    try {
      work.guard.check();
      enteredAdapter = true;
      final result = await work.adapter.loadComic(work.comicId!, lease);
      // A source future may resolve after the request deadline or after the
      // control path closed its lease. Never let that late value cross into
      // codec or persistence processing.
      _checkLeaseAfterResult(lease, result);
      return result;
    } finally {
      _closeLease(lease, work.guard, enteredAdapter);
    }
  }

  Future<Object?> _loadCollection(ScanWork work, Object? cursor) async {
    final lease = _newLease(work.guard);
    var enteredAdapter = false;
    try {
      work.guard.check();
      enteredAdapter = true;
      final result = await work.adapter.loadCollection(
        work.scopeKey,
        cursor,
        lease,
      );
      _checkLeaseAfterResult(lease, result);
      return result;
    } finally {
      _closeLease(lease, work.guard, enteredAdapter);
    }
  }

  ScanCallLease _newLease(ScanExecutionGuard guard) {
    final lease = ScanCallLease(guard: guard, timeout: limits.jsCallTimeout);
    _onLeaseCreated?.call(lease);
    return lease;
  }

  void _checkLeaseAfterResult(ScanCallLease lease, Object? result) {
    if (!lease.isClosed) {
      lease.checkOpen();
      return;
    }
    if (lease.isDeadline) {
      // A managed adapter converts a source-call deadline into a bounded
      // failure envelope. That envelope is the trusted acquisition failure
      // allowed to cross the lease boundary; a success (or a mixed shape)
      // resolving after the deadline remains a discarded late value.
      if (_isDeadlineFailureEnvelope(result)) return;
      throw const ScanLeaseException(ScanLeaseCloseReason.deadline);
    }
    if (lease.isControlCanceled) {
      throw ScanControlException(
        lease.controlReason ?? ScanControlReason.userCanceled,
      );
    }
    // Adapters are allowed to close a normally completed lease in their own
    // finally block. That close is not a cancellation and is accepted; the
    // work guard is checked by the caller immediately after this return.
  }

  bool _isDeadlineFailureEnvelope(Object? result) {
    if (result is! Map ||
        result.length != 1 ||
        !result.containsKey('failure')) {
      return false;
    }
    return result['failure'] is Map;
  }

  void _closeLease(
    ScanCallLease lease,
    ScanExecutionGuard guard,
    bool enteredAdapter,
  ) {
    if (!lease.isClosed) {
      try {
        guard.check();
        lease.close(reason: ScanLeaseCloseReason.completed);
      } on ScanControlException catch (error) {
        lease.close(
          reason: ScanLeaseCloseReason.controlCanceled,
          controlReason: error.reason,
        );
      }
    }
    _onLeaseClosed?.call(lease);
  }

  Future<ScanWorkOutcome> _failScope(
    ScanIngestionContext context,
    ScanEmissionSink emit,
    ScanFailure failure,
  ) async {
    await emit(ScanEmission(ScanScopeFailedEvent(failure)), context);
    return ScanWorkOutcome(
      status: ScanWorkOutcomeStatus.failed,
      failure: failure,
    );
  }

  Future<void> _finishCanceled(
    ScanIngestionContext context,
    ScanEmissionSink emit,
    ScanControlException error,
  ) async {
    // Cancellation is the one terminal write allowed after the guard has
    // become invalid.  It carries no source failure and no item.
    await repository.finishScope(
      context,
      ScanScopeStatus.canceled,
      allowCanceledAfterControl: true,
    );
  }

  ScanFailure _limitFailure(String name) => FailureSanitizer.sanitize({
    'exceptionType': 'ScanLimitExceeded',
    'message': name,
  }, limits: limits);

  String _observedAt() {
    final value = _clock().toUtc();
    final millis = value.millisecondsSinceEpoch;
    return DateTime.fromMillisecondsSinceEpoch(
      millis,
      isUtc: true,
    ).toIso8601String();
  }
}
