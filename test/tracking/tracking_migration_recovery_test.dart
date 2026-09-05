import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tracking/apply_service.dart';
import 'package:venera/foundation/tracking/comparator.dart';
import 'package:venera/foundation/tracking/observation.dart';
import 'package:venera/foundation/tracking/update_state.dart';

class _RecoveryStore implements TrackingApplyStore {
  TrackingBaseline? value;
  bool failCommit = false;

  @override
  TrackingApplyTransaction beginTrackingTransaction() =>
      _RecoveryTransaction(this);
}

class _RecoveryTransaction implements TrackingApplyTransaction {
  _RecoveryTransaction(this.owner) : staged = owner.value;

  final _RecoveryStore owner;
  TrackingBaseline? staged;
  bool closed = false;

  @override
  TrackingBaseline? readBaseline(String sourceKey, String comicId) => staged;

  @override
  void writeBaseline(
    String sourceKey,
    String comicId,
    TrackingBaseline baseline,
  ) {
    staged = baseline;
  }

  @override
  void commit() {
    if (owner.failCommit) {
      closed = true;
      throw StateError('injected commit interruption');
    }
    owner.value = staged;
    closed = true;
  }

  @override
  void rollback() => closed = true;
}

TrackingObservation _observation(String id) => TrackingObservation(
  origin: TrackingObservationOrigin.localOptimized,
  revision: 'local',
  artifact: const TrackingArtifactIdentity(
    sourceKey: 'source',
    fileName: 'source.js',
  ),
  comicId: id,
  observedAt: DateTime.utc(2026, 9, 2),
  validUntil: DateTime.utc(2026, 9, 3),
  state: const UpdateState(latestChapterId: 'chapter-1'),
);

void main() {
  test(
    'failed commit does not publish a partial baseline and retry is safe',
    () {
      final store = _RecoveryStore()..failCommit = true;
      expect(
        () => TrackingApplyService(store).apply(_observation('comic')),
        throwsStateError,
      );
      expect(store.value, isNull);

      store.failCommit = false;
      final result = TrackingApplyService(store).apply(_observation('comic'));
      expect(result.baselinePersisted, isTrue);
      expect(store.value?.state?.latestChapterId, 'chapter-1');
    },
  );

  test('a repeated apply is idempotent after recovery', () {
    final store = _RecoveryStore();
    TrackingApplyService(store).apply(_observation('comic'));
    final second = TrackingApplyService(store).apply(_observation('comic'));
    expect(second.decision.contentChange, ContentChange.unchanged);
    expect(store.value?.state?.latestChapterId, 'chapter-1');
  });
}
