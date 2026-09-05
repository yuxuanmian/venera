import 'comparator.dart';
import 'diagnostics.dart';
import 'observation.dart';
import 'presentation.dart';

/// Minimal transaction boundary needed by the shared tracking apply service.
/// The SQLite manager implements this boundary; pure tests can use an
/// in-memory implementation without importing persistence code.
abstract interface class TrackingApplyStore {
  TrackingApplyTransaction beginTrackingTransaction();
}

abstract interface class TrackingApplyTransaction {
  TrackingBaseline? readBaseline(String sourceKey, String comicId);

  void writeBaseline(
    String sourceKey,
    String comicId,
    TrackingBaseline baseline,
  );

  void commit();

  void rollback();
}

class TrackingApplyResult {
  const TrackingApplyResult({
    required this.decision,
    required this.hasNewUpdate,
    required this.baselinePersisted,
  });

  final ComparisonDecision decision;
  final bool hasNewUpdate;
  final bool baselinePersisted;
}

/// Applies every local or Cloud observation through one comparison and
/// presentation policy.
class TrackingApplyService {
  const TrackingApplyService(this.store, {this.diagnostics});

  final TrackingApplyStore store;
  final TrackingDiagnostics? diagnostics;

  TrackingApplyResult apply(
    TrackingObservation observation, {
    bool Function()? canCommit,
  }) {
    _checkCommitPermission(canCommit);
    final transaction = store.beginTrackingTransaction();
    try {
      final result = applyInTransaction(
        transaction,
        observation,
        canCommit: canCommit,
      );
      _checkCommitPermission(canCommit);
      transaction.commit();
      return result;
    } catch (error) {
      transaction.rollback();
      diagnostics?.recordRejection(
        sourceKey: observation.artifact.sourceKey,
        fileName: observation.artifact.fileName,
        comicId: observation.comicId,
        reason: 'apply: $error',
        runtime: {
          'origin': observation.origin.name,
          'revision': observation.revision,
        },
      );
      rethrow;
    }
  }

  /// Applies a complete artifact snapshot in one transaction.
  ///
  /// Cloud responses are complete replacement snapshots at the artifact
  /// boundary. Keeping the transaction open across every observation is what
  /// prevents a malformed item or a generation change from leaving a partial
  /// snapshot visible to the Updates list.
  List<TrackingApplyResult> applySnapshot(
    Iterable<TrackingObservation> observations, {
    bool Function()? canCommit,
  }) {
    _checkCommitPermission(canCommit);
    final transaction = store.beginTrackingTransaction();
    final results = <TrackingApplyResult>[];
    TrackingObservation? current;
    try {
      for (final observation in observations) {
        current = observation;
        results.add(
          applyInTransaction(transaction, observation, canCommit: canCommit),
        );
      }
      // This is deliberately immediately before the sole commit. A source
      // revision switch can happen while the comparison loop is running.
      _checkCommitPermission(canCommit);
      transaction.commit();
      return results;
    } catch (error) {
      transaction.rollback();
      final observation = current;
      if (observation != null) {
        diagnostics?.recordRejection(
          sourceKey: observation.artifact.sourceKey,
          fileName: observation.artifact.fileName,
          comicId: observation.comicId,
          reason: 'apply snapshot: $error',
          runtime: {
            'origin': observation.origin.name,
            'revision': observation.revision,
          },
        );
      }
      rethrow;
    }
  }

  /// Applies an observation to an already-open transaction. The caller owns
  /// commit/rollback and can combine tracking with cache or scheduling writes.
  TrackingApplyResult applyInTransaction(
    TrackingApplyTransaction transaction,
    TrackingObservation observation, {
    bool Function()? canCommit,
  }) {
    _checkCommitPermission(canCommit);
    final previous = transaction.readBaseline(
      observation.artifact.sourceKey,
      observation.comicId,
    );
    final decision = compareTrackingEvidence(
      previousState: previous?.state,
      previousMarker: previous?.marker,
      currentState: observation.state,
      currentMarker: observation.marker,
    );
    final nextHasNewUpdate = resolveHasNewUpdate(
      previousHasNewUpdate: previous?.hasNewUpdate ?? false,
      sourceUnread: observation.sourceUnread,
      contentChange: decision.contentChange,
    );
    final persistBaseline = decision.contentChange != ContentChange.unknown;
    final next = TrackingBaseline(
      state: persistBaseline ? observation.state : previous?.state,
      marker: persistBaseline ? observation.marker : previous?.marker,
      metadata: persistBaseline ? observation.metadata : previous?.metadata,
      hasNewUpdate: nextHasNewUpdate,
      baselineAt: persistBaseline
          ? previous?.baselineAt ?? observation.observedAt
          : previous?.baselineAt,
      sourceActivityAt: persistBaseline
          ? observation.state?.updatedAt ?? previous?.sourceActivityAt
          : previous?.sourceActivityAt,
    );
    transaction.writeBaseline(
      observation.artifact.sourceKey,
      observation.comicId,
      next,
    );
    diagnostics?.recordDecision(
      observation: observation,
      previous: previous,
      comparison: ComparisonDecisionView(
        contentChange: decision.contentChange.name,
        reason: decision.reason,
        selectedEvidence: decision.selectedEvidence?.name,
        currentValue: _diagnosticValue(decision.currentValue),
      ),
      hasNewUpdate: nextHasNewUpdate,
      baselinePersisted: persistBaseline,
    );
    _checkCommitPermission(canCommit);
    return TrackingApplyResult(
      decision: decision,
      hasNewUpdate: nextHasNewUpdate,
      baselinePersisted: persistBaseline,
    );
  }

  Object? _diagnosticValue(Object? value) {
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (value is Iterable) return value.toList(growable: false);
    return value;
  }

  void _checkCommitPermission(bool Function()? canCommit) {
    if (canCommit != null && !canCommit()) {
      throw StateError('tracking generation is no longer current');
    }
  }
}
