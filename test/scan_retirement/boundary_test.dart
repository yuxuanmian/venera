import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('retirement boundary has no executable legacy scanner surface', () {
    expect(
      File('lib/foundation/follow_update_marker.dart').existsSync(),
      isFalse,
    );

    final followUpdates = _read('lib/foundation/follow_updates.dart');
    final favorites = _read('lib/foundation/favorites.dart');
    final page = _read('lib/pages/follow_updates_page.dart');
    final headless = _read('lib/headless.dart');
    final details = _read('lib/pages/comic_details_page/comic_page.dart');
    final reader = _read('lib/pages/reader/loading.dart');
    final windowFrame = _read('lib/components/window_frame.dart');

    for (final source in [followUpdates, favorites, page, headless]) {
      expect(source, isNot(contains('scanFollowUpdates')));
      expect(source, isNot(contains('recordComicCheckEverywhere')));
      expect(source, isNot(contains('applySuccessfulComicCheck')));
      expect(source, isNot(contains('markComicSuspectGoneEverywhere')));
      expect(source, isNot(contains('FollowUpdateRequestLimiter')));
    }
    expect(followUpdates, isNot(contains('classifyNotFoundError')));
    expect(favorites, isNot(contains('_cacheAllListSnapshot')));
    expect(favorites, isNot(contains('applyCompleteFavoriteUpdateSnapshot')));
    expect(page, isNot(contains('_startTask')));
    expect(page, isNot(contains('Timer(')));
    for (final source in [details, reader, windowFrame]) {
      expect(source, isNot(contains('classifyNotFoundError')));
      expect(source, isNot(contains('recordComicNotFoundEverywhere')));
      expect(source, isNot(contains('recheckFavoriteComic')));
    }
    expect(windowFrame, contains('followUpdateScannerUnavailableMessage'));

    final unavailableCall = headless.indexOf(
      'unavailableHeadlessScanResult(args)',
    );
    final initCall = headless.indexOf('if (!await init())');
    expect(unavailableCall, greaterThanOrEqualTo(0));
    expect(initCall, greaterThan(unavailableCall));

    expect(favorites, contains('CREATE TABLE IF NOT EXISTS scan_queue'));
    expect(
      favorites,
      contains('CREATE TABLE IF NOT EXISTS favorite_update_scan_state'),
    );
  });

  test('retired source-declaration fields leave no app-side residue', () {
    final favorites = _read('lib/foundation/favorites.dart');
    final comicSourceFavorites = _read(
      'lib/foundation/comic_source/favorites.dart',
    );
    final models = _read('lib/foundation/comic_source/models.dart');
    final normalizer = _read('lib/foundation/tracking/normalizer.dart');

    // T069: `FavoriteUpdateCheckData.markerScheme` had no reader and the
    // application-side parser no longer supplies it, so the field and its
    // parameter are gone.  The legacy *database column* lives on
    // `FavoriteUpdateScanState` and is deliberately still here.
    expect(comicSourceFavorites, isNot(contains('markerScheme')));
    expect(comicSourceFavorites, contains('class FavoriteUpdateCheckData'));
    expect(favorites, contains('lastComicCount'));

    // T068: `FavoriteUpdateHint` is a passthrough carrier kept for source
    // compatibility and theme-cache round-tripping, not dead code that may be
    // deleted.  Its presence is asserted so a later "cleanup" has to argue with
    // this test rather than silently drop cached favorite data.
    expect(models, contains('class FavoriteUpdateHint'));
    expect(models, contains('favoriteUpdate = FavoriteUpdateHint.fromJson'));
    expect(models, isNot(contains('fromFavoriteUpdate')));

    // The application side must not resurrect the list-level channel.
    expect(normalizer, isNot(contains('fromFavoriteUpdate')));
  });
}
