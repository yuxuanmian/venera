import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tracking/apply_service.dart';
import 'package:venera/foundation/tracking/comparator.dart';
import 'package:venera/foundation/tracking/observation.dart';
import 'package:venera/foundation/tracking/update_state.dart';

class _Store implements TrackingApplyStore {
  TrackingBaseline? value;

  @override
  TrackingApplyTransaction beginTrackingTransaction() => _Transaction(this);
}

class _Transaction implements TrackingApplyTransaction {
  _Transaction(this.owner) : staged = owner.value;

  final _Store owner;
  TrackingBaseline? staged;

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
  void commit() => owner.value = staged;

  @override
  void rollback() {}
}

TrackingObservation _observation(bool? sourceUnread) => TrackingObservation(
  origin: TrackingObservationOrigin.localOptimized,
  revision: 'local',
  artifact: const TrackingArtifactIdentity(
    sourceKey: 'source',
    fileName: 'source.js',
  ),
  comicId: 'comic',
  observedAt: DateTime.utc(2026, 9, 2),
  validUntil: DateTime.utc(2026, 9, 3),
  state: const UpdateState(latestChapterId: 'chapter-1'),
  sourceUnread: sourceUnread,
);

void main() {
  test(
    'first baseline keeps absent, true, and false unread semantics independent',
    () {
      for (final unread in <bool?>[null, true, false]) {
        final store = _Store();
        final result = TrackingApplyService(store).apply(_observation(unread));
        expect(result.decision.contentChange, ContentChange.rebaseline);
        expect(result.baselinePersisted, isTrue);
        expect(store.value?.hasNewUpdate, unread == true);
        expect(store.value?.state?.latestChapterId, 'chapter-1');
      }
    },
  );
}
