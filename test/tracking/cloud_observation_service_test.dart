import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tracking/apply_service.dart';
import 'package:venera/foundation/tracking/cloud_observation_service.dart';
import 'package:venera/foundation/tracking/cloud_tracking_client.dart';
import 'package:venera/foundation/tracking/comparator.dart';
import 'package:venera/foundation/tracking/observation.dart';
import 'package:venera/foundation/tracking/runtime_generation.dart';
import 'package:venera/foundation/tracking/trusted_catalog.dart';

class _Store implements TrackingApplyStore, TrackingApplyTransaction {
  TrackingBaseline? baseline;
  bool committed = false;

  @override
  TrackingApplyTransaction beginTrackingTransaction() => this;

  @override
  TrackingBaseline? readBaseline(String sourceKey, String comicId) => baseline;

  @override
  void writeBaseline(String sourceKey, String comicId, TrackingBaseline value) {
    baseline = value;
  }

  @override
  void commit() => committed = true;

  @override
  void rollback() {}
}

Map<String, dynamic> _snapshot({
  String validUntil = '2099-09-02T08:45:30.000Z',
}) => {
  'authority': {
    'catalogId': 'yuxuanmian/venera-configs',
    'activeRevision': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'artifacts': [
      {'sourceKey': 'manwa', 'fileName': 'manwa.js'},
    ],
  },
  'generatedAt': '2026-09-02T08:45:30.000Z',
  'observations': [
    {
      'revision': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'artifact': {'sourceKey': 'manwa', 'fileName': 'manwa.js'},
      'comicId': '42',
      'observedAt': '2026-09-02T08:15:30.000Z',
      'validUntil': validUntil,
      'favoriteUpdate': {
        'state': {'latestChapterId': 'chapter-42'},
        'sourceUnread': true,
      },
    },
  ],
};

void main() {
  const artifact = TrustedArtifact(sourceKey: 'manwa', fileName: 'manwa.js');

  test('validates and routes Cloud observations through one apply service', () {
    final generations = RuntimeGenerationController();
    final captured = generations.activate(
      artifact: artifact,
      revision: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      strategy: TrackingStrategy.cloud,
    );
    final store = _Store();
    final service = CloudObservationService(
      catalog: const TrustedCatalog(),
      generations: generations,
      applyService: TrackingApplyService(store),
    );
    final snapshot = CloudObservationSnapshot.fromJson(_snapshot());
    final results = service.applySnapshot(
      snapshot,
      captured,
      now: DateTime.utc(2026, 9, 2),
    );
    expect(results.single.decision.contentChange, ContentChange.rebaseline);
    expect(store.committed, isTrue);
    expect(store.baseline?.hasNewUpdate, isTrue);
  });

  test(
    'rejects stale observations and late generations before persistence',
    () {
      final generations = RuntimeGenerationController();
      final captured = generations.activate(
        artifact: artifact,
        revision: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        strategy: TrackingStrategy.cloud,
      );
      final service = CloudObservationService(
        catalog: const TrustedCatalog(),
        generations: generations,
        applyService: TrackingApplyService(_Store()),
      );
      final stale = CloudObservationSnapshot.fromJson(
        _snapshot(validUntil: '2026-09-02T08:45:30.000Z'),
      );
      expect(
        () => service.applySnapshot(
          stale,
          captured,
          now: DateTime.utc(2026, 9, 2, 9),
        ),
        throwsA(isA<CloudObservationValidationException>()),
      );
      generations.activate(
        artifact: artifact,
        revision: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        strategy: TrackingStrategy.pausedCloud,
      );
      final old = CloudObservationSnapshot.fromJson(_snapshot());
      expect(
        () => service.applySnapshot(old, captured),
        throwsA(isA<CloudObservationValidationException>()),
      );
    },
  );

  test(
    'rejects a late snapshot when the exact artifact is no longer admitted',
    () {
      final generations = RuntimeGenerationController();
      final captured = generations.activate(
        artifact: artifact,
        revision: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        strategy: TrackingStrategy.cloud,
      );
      final store = _Store();
      final service = CloudObservationService(
        catalog: const TrustedCatalog(),
        generations: generations,
        applyService: TrackingApplyService(store),
        isArtifactAdmitted: (_) => false,
      );

      expect(
        () => service.applySnapshot(
          CloudObservationSnapshot.fromJson(_snapshot()),
          captured,
        ),
        throwsA(isA<CloudObservationValidationException>()),
      );
      expect(store.committed, isFalse);
    },
  );
}
