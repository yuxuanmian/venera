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
}
