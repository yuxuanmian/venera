import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tracking/cloud_interest_sync.dart';
import 'package:venera/foundation/tracking/cloud_tracking_client.dart';
import 'package:venera/foundation/tracking/source_revision_store.dart';
import 'package:venera/foundation/tracking/trusted_catalog.dart';

void main() {
  const revision = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const manwa = TrustedArtifact(sourceKey: 'manwa', fileName: 'manwa.js');
  const copyA = TrustedArtifact(
    sourceKey: 'copy_manga',
    fileName: 'copy_manga.js',
  );
  const copyB = TrustedArtifact(
    sourceKey: 'copy_manga',
    fileName: 'copy_manga_multi_accounts.js',
  );
  ActiveArtifact active(TrustedArtifact artifact, {bool blocked = false}) =>
      ActiveArtifact(
        sourceKey: artifact.sourceKey,
        fileName: artifact.fileName,
        revision: revision,
        relativePath: '.managed/$revision/${artifact.fileName}',
        origin: ArtifactOrigin.managedCatalog,
        sha256:
            '0000000000000000000000000000000000000000000000000000000000000000',
        activationBlocked: blocked,
      );

  test('builds a canonical exact-artifact interest set', () {
    final sync = const CloudInterestSync();
    final interests = sync.buildInterests(
      const [
        TrackingFavoriteRef(
          sourceKey: 'copy_manga',
          fileName: 'copy_manga.js',
          comicId: '2',
        ),
        TrackingFavoriteRef(
          sourceKey: 'manwa',
          fileName: 'manwa.js',
          comicId: '42',
        ),
        TrackingFavoriteRef(
          sourceKey: 'manwa',
          fileName: 'manwa.js',
          comicId: '42',
        ),
        TrackingFavoriteRef(
          sourceKey: 'copy_manga',
          fileName: 'copy_manga_multi_accounts.js',
          comicId: '3',
        ),
      ],
      registry: ActiveArtifactRegistry(
        artifacts: [active(manwa), active(copyA), active(copyB)],
      ),
      capableArtifacts: const [manwa, copyA],
    );
    expect(interests, [
      const TrackingInterest(artifact: copyA, comicId: '2'),
      const TrackingInterest(artifact: manwa, comicId: '42'),
    ]);
  });

  test('does not guess between same-key variants', () {
    final interests = const CloudInterestSync().buildInterests(
      const [TrackingFavoriteRef(sourceKey: 'copy_manga', comicId: '2')],
      registry: ActiveArtifactRegistry(
        artifacts: [active(copyA), active(copyB)],
      ),
    );
    expect(interests, isEmpty);
  });

  test('does not synchronize blocked artifacts', () {
    final interests = const CloudInterestSync().buildInterests(
      const [
        TrackingFavoriteRef(
          sourceKey: 'manwa',
          fileName: 'manwa.js',
          comicId: '42',
        ),
      ],
      registry: ActiveArtifactRegistry(
        artifacts: [active(manwa, blocked: true)],
      ),
    );
    expect(interests, isEmpty);
  });
}
