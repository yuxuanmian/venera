import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates_service.dart';
import 'package:venera/foundation/schedule/sqlite_schedule_repository.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';

/// The app-lifecycle facade over the follow-up coordinator.
///
/// The retired scanner's entry points (`startBaseline`, `forceScanAll`,
/// `refreshRandomComics`, `baselineStatus`) are gone rather than stubbed, so
/// their return is a compile error instead of silent dead code.  What remains is
/// the shape `main.dart` and `init.dart` call.
void main() {
  late Directory tempDir;
  late Object? previousEnabledSources;
  late Object? previousFavorites;
  late Object? previousFollowUpdatesEnabled;

  setUp(() async {
    previousEnabledSources = appdata.settings['enabledSources'];
    previousFavorites = appdata.settings['favorites'];
    previousFollowUpdatesEnabled = appdata.settings['followUpdatesEnabled'];
    appdata.settings['enabledSources'] = <String>[];
    appdata.settings['favorites'] = <String>[];
    appdata.settings['followUpdatesEnabled'] = true;
    tempDir = await Directory.systemTemp.createTemp('venera-follow-service-');
    // The coordinator resolves `scan_results.db`, `tracking_state.db` and
    // `schedule_state.db` from here, so the round needs a real directory.
    App.dataPath = tempDir.path;
    App.cachePath = tempDir.path;
    await NetworkFavoriteCacheManager().init(
      databasePath: '${tempDir.path}${Platform.pathSeparator}cache.db',
      migrateLegacy: false,
    );
    FollowUpdatesService.disposeChecker();
  });

  tearDown(() async {
    FollowUpdatesService.disposeChecker();
    FollowUpdatesService.cancelChecking();
    appdata.settings['enabledSources'] = previousEnabledSources;
    appdata.settings['favorites'] = previousFavorites;
    appdata.settings['followUpdatesEnabled'] = previousFollowUpdatesEnabled;
    await judgmentStateRepository.close();
    await scheduleStateRepository.close();
    NetworkFavoriteCacheManager().close();
    try {
      await tempDir.delete(recursive: true);
    } on PathAccessException {
      // Windows may release a native SQLite handle just after dispose.
    }
  });

  test('startup fires once per process, and resume never fires', () async {
    final first = FollowUpdatesService.initChecker();
    await first;
    expect(FollowUpdatesService.taskRunning, isFalse);

    // A second call in the same process is not a new session (Contract F1.1):
    // the same future comes back rather than a second round starting.
    final second = FollowUpdatesService.initChecker();
    expect(identical(first, second), isTrue);

    FollowUpdatesService.onAppResumed();
    FollowUpdatesService.onAppResumed();
    FollowUpdatesService.cancelChecking();
    expect(FollowUpdatesService.taskRunning, isFalse);
  });

  test('a later check is a round, not a forced scan', () async {
    // `runCheckNow` goes through the coordinator's single range rule.  With no
    // criterion sources it acquires nothing, which is the observable difference
    // from the retired `forceScanAll` that ignored every filter.
    await FollowUpdatesService.runCheckNow();
    expect(FollowUpdatesService.taskRunning, isFalse);
  });

  test('progress is task-based and starts idle', () async {
    expect(FollowUpdatesService.progress.value.discovered, 0);
    expect(FollowUpdatesService.progress.value.finished, 0);
    expect(
      FollowUpdatesService.progress.value.isComplete,
      isTrue,
      reason:
          'zero discovered tasks presents as complete, never as 0/0 running',
    );
  });

  test('dispose and reinit are safe to repeat', () async {
    await FollowUpdatesService.initChecker();
    FollowUpdatesService.disposeChecker();
    FollowUpdatesService.disposeChecker();
    await FollowUpdatesService.initChecker();
    await FollowUpdatesService.initChecker();
    expect(FollowUpdatesService.taskRunning, isFalse);
  });
}
