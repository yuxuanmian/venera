import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/follow_update_availability.dart';
import 'package:venera/foundation/favorites.dart';

import 'scan_retirement/fixtures.dart';

void main() {
  late RetirementFixture fixture;

  setUp(() async {
    fixture = await createRetirementFixture();
  });

  tearDown(() async {
    await fixture.dispose();
  });

  test(
    'only-update-check sources emit one unavailable full-cache frame',
    () async {
      final source = RetirementFakeSource(failOptimized: true);
      final folder = const NetworkFavoriteFolderRef(
        sourceKey: RetirementFakeSource.key,
        folderId: retirementFolderOne,
      );
      final before = snapshotRetirementState(fixture.databasePath);

      final frames = await fixture.cache
          .cacheAllPages(
            source.updateCheckOnlyData(),
            folder,
            isCanceled: () => false,
          )
          .toList();

      expect(frames, hasLength(1));
      expect(frames.single.errorMessage, followUpdateScannerUnavailableMessage);
      expect(frames.single.isComplete, isFalse);
      expect(source.counters.updateCheckCalls, 0);
      expect(source.counters.optimizedCalls, 0);
      expect(snapshotRetirementState(fixture.databasePath), before);
      expect(fixture.cache.tryAcquireFullCacheLock(folder), isTrue);
      fixture.cache.releaseFullCacheLock(folder);
    },
  );
}
