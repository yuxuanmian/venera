import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tracking/mode_controller.dart';
import 'package:venera/foundation/tracking/runtime_generation.dart';
import 'package:venera/foundation/tracking/trusted_catalog.dart';

void main() {
  const capable = TrustedArtifact(sourceKey: 'manwa', fileName: 'manwa.js');
  const localOnly = TrustedArtifact(
    sourceKey: 'copy_manga',
    fileName: 'copy_manga.js',
  );

  test(
    'resolves off, local, cloud, and pausedCloud without per-source switches',
    () {
      final controller = TrackingModeController();
      expect(controller.strategyFor(capable), TrackingStrategy.off);

      controller.followUpdatesEnabled = true;
      expect(controller.strategyFor(capable), TrackingStrategy.local);
      controller.cloudEnabled = true;
      expect(controller.strategyFor(capable), TrackingStrategy.pausedCloud);

      controller.setCapability(capable, true);
      expect(controller.strategyFor(capable), TrackingStrategy.pausedCloud);
      controller.setRevisionAligned(capable, true);
      expect(controller.strategyFor(capable), TrackingStrategy.cloud);

      controller.setCapability(localOnly, false);
      expect(controller.strategyFor(localOnly), TrackingStrategy.pausedCloud);
      controller.cloudEnabled = false;
      expect(controller.strategyFor(capable), TrackingStrategy.local);
    },
  );

  test('exposes effective artifact status, revision, and alignment reason', () {
    final controller = TrackingModeController(
      followUpdatesEnabled: true,
      cloudEnabled: true,
    )..setCapability(capable, true);

    final paused = controller.statusFor(capable, revision: 'revision-a');
    expect(paused.strategy, TrackingStrategy.pausedCloud);
    expect(paused.revision, 'revision-a');
    expect(paused.reason, 'Waiting for Server revision alignment.');

    controller.setRevisionAligned(capable, true);
    expect(
      controller.statusFor(capable, revision: 'revision-a').reason,
      'Cloud artifact is aligned.',
    );
  });

  test(
    'keeps blocked artifacts paused and preserves alignment when capability changes',
    () {
      final controller = TrackingModeController(
        followUpdatesEnabled: true,
        cloudEnabled: true,
      );
      controller
        ..setCapability(capable, true)
        ..setRevisionAligned(capable, true);
      expect(controller.strategyFor(capable), TrackingStrategy.cloud);

      controller.setActivationBlocked(capable, true);
      expect(controller.strategyFor(capable), TrackingStrategy.pausedCloud);
      expect(controller.statusFor(capable).activationBlocked, isTrue);

      controller.setActivationBlocked(capable, false);
      controller.setRevisionAligned(capable, true);
      controller.setCapability(capable, false);
      expect(controller.strategyFor(capable), TrackingStrategy.local);
      expect(
        controller.statusFor(capable).reason,
        'Artifact is Local-only and uses the pinned runtime.',
      );
    },
  );
}
