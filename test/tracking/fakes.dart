import 'dart:convert';

import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_result_repository.dart';
import 'package:venera/foundation/tracking/judgment_repository.dart';
import 'package:venera/foundation/tracking/judgment_state.dart';

/// In-memory judgment store.
///
/// Judgment semantics are pure logic; only the storage layer needs SQLite, so
/// every other judgment test can run without a database.
class InMemoryJudgmentRepository implements JudgmentStateRepository {
  InMemoryJudgmentRepository({Map<String, JudgmentState>? initial})
    : rows = {...?initial};

  final Map<String, JudgmentState> rows;
  int applyBatchCalls = 0;
  int clearCalls = 0;
  bool opened = false;
  bool closed = false;

  /// When set, [applyBatch] throws before touching [rows], simulating a
  /// storage failure that must leave state consistent.
  Object? failNextBatch;

  @override
  Future<void> ensureOpen() async {
    opened = true;
  }

  @override
  Future<Map<String, JudgmentState>> readSnapshot() async => {...rows};

  @override
  Future<JudgmentState?> readFor(String sourceKey, String comicId) async =>
      rows['$sourceKey\u0000$comicId'];

  @override
  Future<int> applyBatch(List<JudgmentState> batch) async {
    // An empty batch is a no-op and must not count as a write attempt.
    if (batch.isEmpty) return 0;
    applyBatchCalls++;
    final failure = failNextBatch;
    if (failure != null) {
      failNextBatch = null;
      throw JudgmentStorageException('injected batch failure', failure);
    }
    for (final row in batch) {
      rows[row.identity] = row;
    }
    return batch.length;
  }

  @override
  Future<void> clear() async {
    clearCalls++;
    rows.clear();
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// An in-memory observation store matching [ScanResultRepository]'s item side.
///
/// Only the reads judgment performs are meaningful; the write path exists so
/// scans can be simulated.  It deliberately shares nothing with
/// [InMemoryJudgmentRepository], mirroring the two-database production split.
class InMemoryScanItemStore implements ScanResultRepository {
  InMemoryScanItemStore({Iterable<ScanStoredItem>? items}) {
    if (items != null) {
      for (final item in items) {
        this.items[_key(item.result.sourceKey, item.result.comicId)] = item;
      }
    }
  }

  final Map<String, ScanStoredItem> items = {};
  int readAllCalls = 0;
  bool opened = false;

  /// Invoked after each [readAllItems] result is materialized, so a test can
  /// land a new observation exactly between two reads.
  void Function()? onAfterReadAllItems;

  /// Replaces an item without going through [saveItem], used to simulate a
  /// scan landing between the read and write phases of a judgment run.
  void replace(ScanStoredItem item) {
    items[_key(item.result.sourceKey, item.result.comicId)] = item;
  }

  static String _key(String sourceKey, String comicId) =>
      '$sourceKey\u0000$comicId';

  @override
  Future<void> ensureOpen() async {
    opened = true;
  }

  @override
  String get dbInstanceId => 'in-memory-scan-store';

  @override
  Stream<ScanRepositoryEvent> get events => const Stream.empty();

  @override
  Future<List<ScanStoredItem>> readAllItems() async {
    readAllCalls++;
    final snapshot = List<ScanStoredItem>.unmodifiable(items.values);
    onAfterReadAllItems?.call();
    return snapshot;
  }

  @override
  Future<ScanStoredItem?> readLatestItem(
    String sourceKey,
    String comicId,
  ) async => items[_key(sourceKey, comicId)];

  @override
  Future<ScanStoredScope?> readMatchingScope(
    String sourceKey,
    ScanProducer producer,
    String scopeKey,
    String scopeAttemptId,
  ) async => null;

  @override
  Future<ScanStoredScope?> readScopeByAttemptId(
    String sourceKey,
    ScanProducer producer,
    String scopeAttemptId,
  ) async => null;

  @override
  Future<ScanStoredScope?> readLatestScope(
    String sourceKey,
    ScanProducer producer,
    String scopeKey,
  ) async => null;

  @override
  Future<ScanScopeHandle> beginScope({
    required String sourceKey,
    required ScanProducer producer,
    required String scopeKey,
    required String definitionRevision,
    String? scopeAttemptId,
    String? accessContextKey,
    dynamic guard,
  }) async => throw UnsupportedError('not needed for judgment tests');

  @override
  Future<ScanItemWriteResult> saveItem(
    ScanIngestionContext context,
    ScanItemResult item, {
    DateTime? committedAt,
  }) async => throw UnsupportedError('not needed for judgment tests');

  @override
  Future<ScanScopeWriteResult> finishScope(
    ScanIngestionContext context,
    ScanScopeStatus status, {
    ScanFailure? failure,
    bool allowCanceledAfterControl = false,
    DateTime? finishedAt,
  }) async => throw UnsupportedError('not needed for judgment tests');

  @override
  Future<void> close() async {}
}

/// A controllable clock.  Judgment never reads the system clock itself.
class FixedClock {
  FixedClock(this.now);

  DateTime now;

  DateTime call() => now;

  void advance(Duration duration) {
    now = now.add(duration);
  }
}

/// One synthetic observation definition, kept declarative so tests can state
/// an observation and its expected conclusion on adjacent lines.
class ObservationSpec {
  const ObservationSpec({
    this.updatedAt,
    this.latestChapterId,
    this.chapterCount,
    this.recentChapterIds = const [],
    this.sourceUnread,
  });

  final String? updatedAt;
  final String? latestChapterId;
  final int? chapterCount;
  final List<String> recentChapterIds;
  final bool? sourceUnread;

  UpdateDescriptor? get update {
    final descriptor = UpdateDescriptor(
      updatedAt: updatedAt,
      latestChapterId: latestChapterId,
      chapterCount: chapterCount,
      recentChapterIds: recentChapterIds,
    );
    return descriptor.isEmpty ? null : descriptor;
  }

  ScanObservation get observation =>
      ScanObservation(update: update, sourceUnread: sourceUnread);

  /// The canonical observation JSON judgment receives.
  String get json => jsonEncode(observation.toJson());

  /// A stored item carrying this observation.
  ScanStoredItem toStoredItem({
    required String sourceKey,
    required String comicId,
    String? attemptId,
    String? evidenceSchema,
    int observedAtMs = 1757000000000,
    ScanProducer producer = ScanProducer.comic,
  }) => ScanStoredItem(
    result: ScanItemResult.observed(
      attemptId: attemptId ?? '$sourceKey\u0000$comicId\u00000',
      scopeAttemptId: 'scope-$comicId',
      sourceKey: sourceKey,
      comicId: comicId,
      producer: producer,
      definitionRevision: 'rev-1',
      observedAt: DateTime.fromMillisecondsSinceEpoch(
        observedAtMs,
        isUtc: true,
      ).toIso8601String(),
      evidenceSchema: evidenceSchema,
      observation: observation,
    ),
    attemptOrdinal: 1,
    observedAtMs: observedAtMs,
    committedAtMs: observedAtMs,
  );

  /// A stored item whose payload is a failure, not an observation.
  static ScanStoredItem failureItem({
    required String sourceKey,
    required String comicId,
    String message = 'forbidden',
    int observedAtMs = 1757000000000,
    ScanProducer producer = ScanProducer.comic,
  }) => ScanStoredItem(
    result: ScanItemResult.failed(
      attemptId: '$sourceKey\u0000$comicId\u0000fail',
      scopeAttemptId: 'scope-$comicId',
      sourceKey: sourceKey,
      comicId: comicId,
      producer: producer,
      definitionRevision: 'rev-1',
      observedAt: DateTime.fromMillisecondsSinceEpoch(
        observedAtMs,
        isUtc: true,
      ).toIso8601String(),
      failure: ScanFailure(message: message),
    ),
    attemptOrdinal: 1,
    observedAtMs: observedAtMs,
    committedAtMs: observedAtMs,
  );
}

/// The two label strings used across the judgment tests.
const String labelA = '{"latestchapterid":"last_chapter.id"}';
const String labelB = '{"updatedat":"updated_at@day"}';

/// Builds a state as it would exist after one recorded decision.
JudgmentState stateOf({
  required String sourceKey,
  required String comicId,
  required JudgmentOutcome outcome,
  String? processedAttemptId,
}) => JudgmentState(
  sourceKey: sourceKey,
  comicId: comicId,
  factJson: outcome.factJson,
  factObservedAtMs: outcome.factObservedAtMs,
  evidenceSchema: outcome.evidenceSchema,
  lastDecision: outcome.conclusion,
  lastEvidence: outcome.selectedEvidence,
  lastPreviousValue: outcome.previousValue,
  lastCurrentValue: outcome.currentValue,
  lastReason: outcome.reason,
  decidedAtMs: outcome.decidedAtMs,
  noCommonStreak: outcome.noCommonStreak,
  hasNewUpdate: outcome.hasNewUpdate,
  processedAttemptId: processedAttemptId,
);
