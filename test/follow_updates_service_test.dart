import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/pages/follow_updates_page.dart';

void main() {
  late Directory tempDir;
  late NetworkFavoriteCacheManager cache;
  late Object? previousEnabledSources;
  late Object? previousFavorites;

  setUp(() async {
    previousEnabledSources = appdata.settings['enabledSources'];
    previousFavorites = appdata.settings['favorites'];
    appdata.settings['enabledSources'] = <String>[];
    appdata.settings['favorites'] = <String>[];
    tempDir = await Directory.systemTemp.createTemp('venera-follow-service-');
    cache = NetworkFavoriteCacheManager();
    await cache.init(
      databasePath: '${tempDir.path}${Platform.pathSeparator}cache.db',
      migrateLegacy: false,
    );
    FollowUpdatesService.disposeChecker();
  });

  tearDown(() async {
    FollowUpdatesService.disposeChecker();
    appdata.settings['enabledSources'] = previousEnabledSources;
    appdata.settings['favorites'] = previousFavorites;
    cache.close();
    await tempDir.delete(recursive: true);
  });

  test('init, cancel, and retired scan methods remain idle', () async {
    FollowUpdatesService.initChecker();
    FollowUpdatesService.initChecker();
    FollowUpdatesService.cancelChecking();
    FollowUpdatesService.onAppResumed();
    FollowUpdatesService.startBaseline();
    await FollowUpdatesService.runCheckNow();
    await FollowUpdatesService.forceScanAll();
    await FollowUpdatesService.refreshRandomComics();

    expect(FollowUpdatesService.taskRunning.value, isFalse);
    expect(FollowUpdatesService.baselineStatus.value, isNull);
  });

  test('dispose twice and reinit do not leave a duplicate listener', () {
    FollowUpdatesService.initChecker();
    FollowUpdatesService.initChecker();
    FollowUpdatesService.disposeChecker();
    FollowUpdatesService.disposeChecker();
    FollowUpdatesService.initChecker();
    cache.notifyListeners();

    expect(FollowUpdatesService.taskRunning.value, isFalse);
    expect(FollowUpdatesService.baselineStatus.value, isNull);
  });
}
