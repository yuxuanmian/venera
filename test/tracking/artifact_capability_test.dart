import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tracking/cloud_interest_sync.dart';
import 'package:venera/foundation/tracking/cloud_tracking_client.dart';
import 'package:venera/foundation/tracking/mode_controller.dart';
import 'package:venera/foundation/tracking/source_revision_store.dart';
import 'package:venera/foundation/tracking/runtime_generation.dart';
import 'package:venera/foundation/tracking/trusted_catalog.dart';

void main() {
  const revision = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const manwa = TrustedArtifact(sourceKey: 'manwa', fileName: 'manwa.js');
  const copyManga = TrustedArtifact(
    sourceKey: 'copy_manga',
    fileName: 'copy_manga.js',
  );
  const copyMangaMulti = TrustedArtifact(
    sourceKey: 'copy_manga',
    fileName: 'copy_manga_multi_accounts.js',
  );

  ActiveArtifact active(TrustedArtifact artifact) => ActiveArtifact(
    sourceKey: artifact.sourceKey,
    fileName: artifact.fileName,
    revision: revision,
    relativePath: '.managed/$revision/${artifact.fileName}',
    origin: ArtifactOrigin.managedCatalog,
    sha256: '0000000000000000000000000000000000000000000000000000000000000000',
  );

  test('classifies capability by exact sourceKey and fileName pair', () {
    final interests = const CloudInterestSync().buildInterests(
      const [
        TrackingFavoriteRef(
          sourceKey: 'copy_manga',
          fileName: 'copy_manga.js',
          comicId: '1',
        ),
        TrackingFavoriteRef(
          sourceKey: 'copy_manga',
          fileName: 'copy_manga_multi_accounts.js',
          comicId: '2',
        ),
        TrackingFavoriteRef(
          sourceKey: 'manwa',
          fileName: 'manwa.js',
          comicId: '3',
        ),
      ],
      registry: ActiveArtifactRegistry(
        artifacts: [active(manwa), active(copyManga), active(copyMangaMulti)],
      ),
      capableArtifacts: const [manwa],
    );

    expect(interests, [const TrackingInterest(artifact: manwa, comicId: '3')]);
  });

  test('does not inherit capability across duplicate source-key variants', () {
    final controller = TrackingModeController(
      followUpdatesEnabled: true,
      cloudEnabled: true,
    );
    controller.setCapability(copyManga, true);
    controller.setRevisionAligned(copyManga, true);

    expect(controller.strategyFor(copyManga), TrackingStrategy.cloud);
    expect(
      controller.strategyFor(copyMangaMulti),
      TrackingStrategy.pausedCloud,
    );
  });
}
