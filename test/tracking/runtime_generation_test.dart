import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tracking/runtime_generation.dart';
import 'package:venera/foundation/tracking/trusted_catalog.dart';

void main() {
  const artifact = TrustedArtifact(sourceKey: 'manwa', fileName: 'manwa.js');

  test('rejects a late return after artifact generation changes', () {
    final controller = RuntimeGenerationController();
    final oldGeneration = controller.activate(
      artifact: artifact,
      revision: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      strategy: TrackingStrategy.cloud,
    );
    expect(controller.canCommit(oldGeneration), isTrue);

    final newGeneration = controller.activate(
      artifact: artifact,
      revision: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      strategy: TrackingStrategy.pausedCloud,
    );
    expect(newGeneration.generation, 2);
    expect(controller.canCommit(oldGeneration), isFalse);
    expect(controller.canCommit(newGeneration), isTrue);
  });

  test('captures all write-boundary identity fields', () {
    final controller = RuntimeGenerationController(initialGeneration: 4);
    final captured = controller.activate(
      artifact: artifact,
      revision: 'cccccccccccccccccccccccccccccccccccccccc',
      strategy: TrackingStrategy.local,
    );
    expect(captured.toJson(), {
      'generation': 5,
      'sourceKey': 'manwa',
      'fileName': 'manwa.js',
      'revision': 'cccccccccccccccccccccccccccccccccccccccc',
      'strategy': 'local',
    });
  });

  test('periodic refresh reuses an unchanged artifact generation', () {
    final controller = RuntimeGenerationController();
    final first = controller.activate(
      artifact: artifact,
      revision: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      strategy: TrackingStrategy.cloud,
    );
    final same = controller.activateIfChanged(
      artifact: artifact,
      revision: first.revision,
      strategy: TrackingStrategy.cloud,
    );
    expect(identical(same, first), isTrue);
    expect(same.generation, first.generation);

    final changed = controller.activateIfChanged(
      artifact: artifact,
      revision: first.revision,
      strategy: TrackingStrategy.pausedCloud,
    );
    expect(changed.generation, greaterThan(first.generation));
    expect(controller.canCommit(first), isFalse);
  });
}
