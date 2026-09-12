import 'execution_guard.dart';
import 'models.dart';

class ScanScopeHandle {
  const ScanScopeHandle({
    required this.sourceKey,
    required this.producer,
    required this.scopeKey,
    required this.scopeAttemptId,
    required this.attemptOrdinal,
    required this.definitionRevision,
    this.accessContextKey,
    required this.dbInstanceId,
  });

  final String sourceKey;
  final ScanProducer producer;
  final String scopeKey;
  final String scopeAttemptId;
  final int attemptOrdinal;
  final String definitionRevision;
  final String? accessContextKey;
  final String dbInstanceId;
}

class ScanIngestionContext {
  const ScanIngestionContext({required this.scope, this.guard});

  final ScanScopeHandle scope;
  final ScanExecutionGuard? guard;
}

enum ScanItemWriteDisposition { written, duplicate, stale }

class ScanItemWriteResult {
  const ScanItemWriteResult(this.disposition);

  final ScanItemWriteDisposition disposition;

  bool get written => disposition == ScanItemWriteDisposition.written;
}

enum ScanScopeWriteDisposition { finished, duplicate, stale }

class ScanScopeWriteResult {
  const ScanScopeWriteResult(this.disposition);

  final ScanScopeWriteDisposition disposition;

  bool get finished => disposition == ScanScopeWriteDisposition.finished;
}

class ScanStoredItem {
  const ScanStoredItem({
    required this.result,
    required this.attemptOrdinal,
    required this.observedAtMs,
    required this.committedAtMs,
  });

  final ScanItemResult result;
  final int attemptOrdinal;
  final int observedAtMs;
  final int committedAtMs;
}

class ScanStoredScope {
  const ScanStoredScope({
    required this.sourceKey,
    required this.producer,
    required this.scopeKey,
    required this.scopeAttemptId,
    required this.attemptOrdinal,
    required this.accessContextKey,
    required this.definitionRevision,
    required this.startedAtMs,
    required this.finishedAtMs,
    required this.status,
    required this.itemCount,
    required this.failure,
  });

  final String sourceKey;
  final ScanProducer producer;
  final String scopeKey;
  final String scopeAttemptId;
  final int attemptOrdinal;
  final String? accessContextKey;
  final String definitionRevision;
  final int startedAtMs;
  final int? finishedAtMs;
  final ScanScopeStatus status;
  final int itemCount;
  final ScanFailure? failure;
}

class ScanRepositoryEvent {
  const ScanRepositoryEvent({this.item, this.scope});

  final ScanStoredItem? item;
  final ScanStoredScope? scope;
}

abstract class ScanResultRepository {
  Future<void> ensureOpen();

  String get dbInstanceId;

  Stream<ScanRepositoryEvent> get events;

  Future<ScanScopeHandle> beginScope({
    required String sourceKey,
    required ScanProducer producer,
    required String scopeKey,
    required String definitionRevision,
    String? scopeAttemptId,
    String? accessContextKey,
    ScanExecutionGuard? guard,
  });

  Future<ScanItemWriteResult> saveItem(
    ScanIngestionContext context,
    ScanItemResult item, {
    DateTime? committedAt,
  });

  Future<ScanScopeWriteResult> finishScope(
    ScanIngestionContext context,
    ScanScopeStatus status, {
    ScanFailure? failure,
    bool allowCanceledAfterControl = false,
    DateTime? finishedAt,
  });

  Future<ScanStoredItem?> readLatestItem(String sourceKey, String comicId);

  /// Enumerates every stored item.
  ///
  /// This is the only method that can answer "which (sourceKey, comicId)
  /// exist".  The four read methods above are all point lookups: they require
  /// the comic or scope identity up front.  The `events` broadcast cannot
  /// substitute — it has no replay, lives only in memory and is empty after a
  /// restart.
  Future<List<ScanStoredItem>> readAllItems();

  Future<ScanStoredScope?> readMatchingScope(
    String sourceKey,
    ScanProducer producer,
    String scopeKey,
    String scopeAttemptId,
  );

  /// Reads the scope which produced an item.  Collection scopes have a
  /// provider-defined key, so callers cannot reconstruct it from the comic
  /// id alone.
  Future<ScanStoredScope?> readScopeByAttemptId(
    String sourceKey,
    ScanProducer producer,
    String scopeAttemptId,
  );

  Future<ScanStoredScope?> readLatestScope(
    String sourceKey,
    ScanProducer producer,
    String scopeKey,
  );

  Future<void> close();
}
