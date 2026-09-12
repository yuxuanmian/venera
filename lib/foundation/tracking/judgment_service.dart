import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../scan/models.dart';
import '../scan/scan_debug_service.dart';
import '../scan/scan_result_repository.dart';
import '../scan/sqlite_scan_result_repository.dart';
import 'judgment.dart';
import 'judgment_repository.dart';
import 'judgment_state.dart';
import 'sqlite_judgment_repository.dart';

/// Runtime summary of one judgment run.
///
/// A runtime value only: it is never persisted (data-model section 1).
class JudgmentSummary {
  const JudgmentSummary({
    required this.processed,
    required this.changed,
    required this.failed,
    required this.writtenRows,
    required this.skippedStale,
    this.rejectedAsRunning = false,
    this.errorMessage,
  });

  const JudgmentSummary.rejected()
    : processed = 0,
      changed = 0,
      failed = 0,
      writtenRows = 0,
      skippedStale = 0,
      rejectedAsRunning = true,
      errorMessage = null;

  /// Observations handled in this run.
  final int processed;

  /// Observations whose conclusion was `changed`.
  final int changed;

  /// Observations that were failures and therefore skipped.
  final int failed;

  /// Rows actually written; zero when nothing was pending (FR-024).
  final int writtenRows;

  /// Identities skipped because a newer observation landed mid-run.
  final int skippedStale;

  /// True when the call was refused because a run was already in flight.
  final bool rejectedAsRunning;

  final String? errorMessage;

  bool get isEmptyRun => writtenRows == 0;

  @override
  String toString() =>
      'processed=$processed changed=$changed failed=$failed '
      'written=$writtenRows skipped=$skippedStale';
}

/// Batch coordinator for the judgment domain.
///
/// Contract: `specs/005-tracking-reconnect/contracts/judgment-v1.md` and
/// `specs/005-tracking-reconnect/data-model.md` section 4.
///
/// Judgment reads the scan result store and writes its own store; the two
/// share no transaction, so a consistent snapshot is guaranteed by freezing
/// the observation set during the read phase and re-checking each identity
/// immediately before its write.
class JudgmentService {
  JudgmentService({
    JudgmentStateRepository? repository,
    ScanResultRepository? scanRepository,
    Future<void> Function()? cancelInFlightScan,
    DateTime Function()? clock,
    void Function(String operation)? operationHook,
  }) : repository = repository ?? judgmentStateRepository,
       scanRepository = scanRepository ?? scanResultRepository,
       _cancelInFlightScan = cancelInFlightScan,
       _clock = clock ?? DateTime.now,
       _operationHook = operationHook;

  final JudgmentStateRepository repository;
  final ScanResultRepository scanRepository;
  final Future<void> Function()? _cancelInFlightScan;
  final DateTime Function() _clock;
  final void Function(String operation)? _operationHook;

  bool _running = false;
  JudgmentSummary? _lastSummary;

  /// Whether a run is currently in flight.  Debug reads this to report
  /// "already running" instead of silently starting a second run.
  bool get isRunning => _running;

  /// Summary of the previous completed run, or null when none has run.
  JudgmentSummary? get lastSummary => _lastSummary;

  /// Whether this instance was given a scan-cancellation callback.
  ///
  /// FR-035 and Contract U4.1 make "cancel the in-flight scan first" a required
  /// step of [clear], but that step is a silent no-op when the callback is
  /// null.  The callback is easy to forget precisely because every
  /// cancellation test injects its own, so the product singleton's wiring is
  /// exposed here for a regression test to assert on.
  @visibleForTesting
  bool get cancelInFlightScanIsWired => _cancelInFlightScan != null;

  /// Processes every not-yet-processed observation.
  ///
  /// Idempotent: the already-processed mark decides what to skip, so a second
  /// run over the same evidence writes zero rows and leaves state untouched.
  /// There is deliberately no `replay()` — a full rerun is `clear()` followed
  /// by this method (data-model section 5).
  Future<JudgmentSummary> run() async {
    // Re-entry is refused outright rather than queued (FR-042).
    if (_running) return const JudgmentSummary.rejected();
    _running = true;
    try {
      final summary = await _runOnce();
      _lastSummary = summary;
      return summary;
    } finally {
      _running = false;
    }
  }

  Future<JudgmentSummary> _runOnce() async {
    await repository.ensureOpen();
    final snapshot = await repository.readSnapshot();
    // Freeze the observation set for this run.  Anything landing after this
    // point belongs to the next run (FR-023).
    final items = await scanRepository.readAllItems();
    final decidedAtMs = _nowMs();

    final pending = <_PendingJudgment>[];
    var processed = 0;
    var changed = 0;
    var failed = 0;

    for (final stored in items) {
      final result = stored.result;
      // A failure carries no observation and produces no judgment at all.
      if (!result.isSuccess) {
        failed++;
        continue;
      }
      final identity = '${result.sourceKey}\u0000${result.comicId}';
      final previous = snapshot[identity];
      // Skip only when this exact observation was already handled **by the
      // current rules**.  Two separate conditions, because they answer two
      // different questions:
      //
      //  * `processedAttemptId` answers "has this observation been handled?" —
      //    it must be used for that and not the fact timestamp, because
      //    `unknown` does not advance the fact (research R-01).
      //  * `algorithmVersion` answers "was it handled by rules that still
      //    apply?" — a row written by different rules is stale and must be
      //    recomputed even though its observation is unchanged (US2-AC2).
      //
      // A NULL stored version (a row predating the column) is therefore also
      // recomputed, which is what makes the column migration self-healing.
      if (previous != null &&
          previous.processedAttemptId == result.attemptId &&
          previous.isCurrentAlgorithm) {
        continue;
      }
      processed++;
      final outcome = decide(
        previousFactJson: previous?.factJson,
        recordedLabel: previous?.evidenceSchema,
        // The fact keeps the observation's canonical JSON verbatim, so the
        // `updatedAt` string survives storage and display unrewritten (J9).
        currentObservationJson: jsonEncode(result.observation!.toJson()),
        currentLabel: result.evidenceSchema ?? '',
        currentObservedAtMs: stored.observedAtMs,
        decidedAtMs: decidedAtMs,
        previousHasNewUpdate: previous?.hasNewUpdate ?? false,
        previousNoCommonStreak: previous?.noCommonStreak ?? 0,
      );
      if (outcome.conclusion == JudgmentConclusion.changed) changed++;
      pending.add(
        _PendingJudgment(
          state: _toState(result, stored, outcome),
          attemptId: result.attemptId,
        ),
      );
    }

    // Write phase: one transaction, and each identity is re-checked against
    // the frozen snapshot first so a mid-run scan cannot be half-absorbed.
    final verified = <JudgmentState>[];
    var skippedStale = 0;
    if (pending.isNotEmpty) {
      final current = await scanRepository.readAllItems();
      final currentAttempts = <String, String>{
        for (final item in current)
          '${item.result.sourceKey}\u0000${item.result.comicId}':
              item.result.attemptId,
      };
      for (final entry in pending) {
        if (currentAttempts[entry.state.identity] != entry.attemptId) {
          skippedStale++;
          continue;
        }
        verified.add(entry.state);
      }
    }

    final written = await repository.applyBatch(verified);
    return JudgmentSummary(
      processed: processed,
      changed: changed,
      failed: failed,
      writtenRows: written,
      skippedStale: skippedStale,
    );
  }

  /// Clears every judgment state row.
  ///
  /// Contract U4.1 order is mandatory: cancel an in-flight scan first, then
  /// clear.  Scan evidence is preserved, which is what makes this a debugging
  /// tool rather than a reset button.
  Future<void> clear() async {
    final cancel = _cancelInFlightScan;
    if (cancel != null) await cancel();
    await repository.clear();
    _lastSummary = null;
  }

  /// Clears the visible flag of every comic of one source (FR-027).
  ///
  /// Touches `has_new_update` only: the content fact and decision columns are
  /// account independent and must survive an account switch.  Returns the
  /// number of affected rows.
  Future<int> clearUnreadForSource(String sourceKey) async {
    await repository.ensureOpen();
    final snapshot = await repository.readSnapshot();
    final rows = <JudgmentState>[];
    for (final state in snapshot.values) {
      if (state.sourceKey != sourceKey) continue;
      if (!state.hasNewUpdate) continue;
      rows.add(state.copyWith(hasNewUpdate: false));
    }
    return repository.applyBatch(rows);
  }

  /// Reads one state for display.  Read-only: no write capability is exposed.
  Future<JudgmentState?> readFor(String sourceKey, String comicId) async {
    await repository.ensureOpen();
    return repository.readFor(sourceKey, comicId);
  }

  Future<void> close() => repository.close();

  JudgmentState _toState(
    ScanItemResult result,
    ScanStoredItem stored,
    JudgmentOutcome outcome,
  ) {
    _operationHook?.call('judgment.decide');
    return JudgmentState(
      sourceKey: result.sourceKey,
      comicId: result.comicId,
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
      // Always advances for a handled observation, otherwise the same evidence
      // would be judged again on the next run (research R-01).
      processedAttemptId: result.attemptId,
      // Stamp the rules that produced this row, so a later rule change is
      // detectable instead of being masked by the processed mark.
      algorithmVersion: judgmentAlgorithmVersion,
    );
  }

  int _nowMs() => _clock().millisecondsSinceEpoch;
}

class _PendingJudgment {
  const _PendingJudgment({required this.state, required this.attemptId});

  final JudgmentState state;
  final String attemptId;
}

/// The product-owned judgment coordinator.
///
/// `cancelInFlightScan` is wired here rather than left at its null default:
/// FR-035 and Contract U4.1 require the clear entry point to request
/// cancellation of an in-flight scan *before* it deletes anything, and a
/// callback that is only supplied by tests satisfies the letter of that
/// contract without doing anything on a device.
///
/// The reference sits inside the closure body so the scan coordinator is
/// constructed when a clear actually runs, not while this library's globals are
/// being initialised.
JudgmentService judgmentService = JudgmentService(
  cancelInFlightScan: () async =>
      scanDebugService.cancel(ScanControlReason.userCanceled),
);
