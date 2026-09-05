import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tracking/apply_service.dart';
import 'package:venera/foundation/tracking/observation.dart';
import 'package:venera/foundation/tracking/update_state.dart';

class _MemoryStore implements TrackingApplyStore {
  final values = <String, TrackingBaseline>{};
  int commits = 0;
  int rollbacks = 0;
  String? failOnComicId;

  @override
  TrackingApplyTransaction beginTrackingTransaction() {
    return _MemoryTransaction(this);
  }
}

class _MemoryTransaction implements TrackingApplyTransaction {
  _MemoryTransaction(this.owner) : staged = Map.of(owner.values);

  final _MemoryStore owner;
  Map<String, TrackingBaseline> staged;
  bool closed = false;

  String _key(String sourceKey, String comicId) => '$sourceKey\u0000$comicId';

  @override
  TrackingBaseline? readBaseline(String sourceKey, String comicId) =>
      staged[_key(sourceKey, comicId)];

  @override
  void writeBaseline(
    String sourceKey,
    String comicId,
    TrackingBaseline baseline,
  ) {
    if (owner.failOnComicId == comicId) {
      throw StateError('injected snapshot item failure');
    }
    staged[_key(sourceKey, comicId)] = baseline;
  }

  @override
  void commit() {
    if (closed) throw StateError('transaction already closed');
    owner.values
      ..clear()
      ..addAll(staged);
    owner.commits++;
    closed = true;
  }

  @override
  void rollback() {
    if (closed) return;
    owner.rollbacks++;
    closed = true;
  }
}

TrackingObservation _observation({
  String comicId = 'comic-1',
  UpdateState? state,
  bool? sourceUnread,
  String? marker,
  Map<String, dynamic>? metadata,
}) => TrackingObservation(
  origin: TrackingObservationOrigin.localOptimized,
  revision: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  artifact: const TrackingArtifactIdentity(
    sourceKey: 'test-source',
    fileName: 'test-source.js',
  ),
  comicId: comicId,
  observedAt: DateTime.utc(2026, 9, 2, 8),
  validUntil: DateTime.utc(2026, 9, 2, 9),
  state: state,
  sourceUnread: sourceUnread,
  marker: marker,
  metadata: metadata,
);

void main() {
  test(
    'applies changed, unchanged, rebaseline, and unknown transactionally',
    () {
      final store = _MemoryStore();
      final service = TrackingApplyService(store);
      final initial = TrackingBaseline(
        state: UpdateState(latestChapterId: 'chapter-1'),
        marker: 'marker-1',
        hasNewUpdate: false,
      );
      store.values['test-source\u0000comic-1'] = initial;

      final changed = service.apply(
        _observation(
          state: UpdateState(latestChapterId: 'chapter-2'),
          marker: 'marker-2',
        ),
      );
      expect(changed.decision.contentChange.name, 'changed');
      expect(changed.hasNewUpdate, isTrue);
      expect(changed.baselinePersisted, isTrue);
      expect(store.commits, 1);

      final unchanged = service.apply(
        _observation(
          state: UpdateState(latestChapterId: 'chapter-2'),
          marker: 'marker-other',
          metadata: {'diagnostic': 'changed'},
        ),
      );
      expect(unchanged.decision.contentChange.name, 'unchanged');
      expect(unchanged.decision.selectedEvidence?.name, 'latestChapterId');
      expect(unchanged.hasNewUpdate, isTrue);
      expect(store.values['test-source\u0000comic-1']!.metadata, {
        'diagnostic': 'changed',
      });

      final unknown = service.apply(_observation());
      expect(unknown.decision.contentChange.name, 'unknown');
      expect(unknown.baselinePersisted, isFalse);
      expect(
        store.values['test-source\u0000comic-1']!.state?.latestChapterId,
        'chapter-2',
      );

      final first = _MemoryStore();
      final firstResult = TrackingApplyService(
        first,
      ).apply(_observation(state: UpdateState(latestChapterId: 'chapter-1')));
      expect(firstResult.decision.contentChange.name, 'rebaseline');
      expect(firstResult.hasNewUpdate, isFalse);
    },
  );

  test('complete snapshots roll back every staged item on partial failure', () {
    final store = _MemoryStore();
    final previous = TrackingBaseline(
      state: UpdateState(latestChapterId: 'chapter-old'),
      hasNewUpdate: false,
    );
    store.values['test-source\u0000comic-1'] = previous;
    store.failOnComicId = 'comic-2';

    expect(
      () => TrackingApplyService(store).applySnapshot([
        _observation(state: UpdateState(latestChapterId: 'chapter-new')),
        _observation(
          comicId: 'comic-2',
          state: UpdateState(latestChapterId: 'chapter-2'),
        ),
      ]),
      throwsStateError,
    );
    expect(store.commits, 0);
    expect(store.rollbacks, 1);
    expect(
      store.values['test-source\u0000comic-1']?.state?.latestChapterId,
      previous.state?.latestChapterId,
    );
    expect(store.values['test-source\u0000comic-1']?.hasNewUpdate, isFalse);
    expect(store.values.containsKey('test-source\u0000comic-2'), isFalse);
  });

  test('generation fence is checked again immediately before one commit', () {
    final store = _MemoryStore();
    var checks = 0;
    expect(
      () => TrackingApplyService(store).applySnapshot([
        _observation(state: UpdateState(latestChapterId: 'chapter-1')),
        _observation(
          comicId: 'comic-2',
          state: UpdateState(latestChapterId: 'chapter-2'),
        ),
      ], canCommit: () => ++checks < 6),
      throwsStateError,
    );
    expect(store.commits, 0);
    expect(store.rollbacks, 1);
    expect(checks, 6);
  });

  test(
    'sourceUnread=false clears qualification but persists changed baseline',
    () {
      final store = _MemoryStore();
      store.values['test-source\u0000comic-1'] = TrackingBaseline(
        state: UpdateState(latestChapterId: 'chapter-1'),
        hasNewUpdate: true,
      );

      final result = TrackingApplyService(store).apply(
        _observation(
          state: UpdateState(latestChapterId: 'chapter-2'),
          sourceUnread: false,
        ),
      );
      expect(result.decision.contentChange.name, 'changed');
      expect(result.hasNewUpdate, isFalse);
      expect(
        store.values['test-source\u0000comic-1']!.state?.latestChapterId,
        'chapter-2',
      );
    },
  );
}
