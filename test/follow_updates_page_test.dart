import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_update_availability.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/utils/translations.dart';

const _testSourceKey = 'test_source';

FavoriteItem _comic(String id) => FavoriteItem(
  id: id,
  name: 'Comic $id',
  coverPath: 'https://example.invalid/$id.jpg',
  author: 'Author',
  sourceKeyValue: _testSourceKey,
  tags: const ['tag'],
);

FavoriteData _numericData(
  Future<Res<List<Comic>>> Function(int page, [String? folder]) loader,
) => FavoriteData(
  key: _testSourceKey,
  title: 'Test source',
  multiFolder: true,
  loadComic: loader,
  loadNext: null,
  loadFolders: ([String? _]) async =>
      const Res(<String, String>{'remote': 'Remote'}),
);

ComicSource _detailSource() {
  return ComicSource(
    'Test source',
    _testSourceKey,
    null,
    null,
    null,
    null,
    const [],
    null,
    null,
    (id) async => Res(
      ComicDetails.fromJson({
        'title': 'Comic $id',
        'subtitle': 'Author',
        'cover': '',
        'tags': <String, List<String>>{},
        'chapters': <String, String>{'1': 'Chapter 1'},
        'sourceKey': _testSourceKey,
        'comicId': id,
      }),
    ),
    null,
    null,
    null,
    null,
    '',
    '',
    '1.0.0',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Object? previousEnabledSources;
  late Object? previousFavorites;
  const folder = NetworkFavoriteFolderRef(
    sourceKey: _testSourceKey,
    folderId: 'remote',
    title: 'Remote',
  );

  setUpAll(() async {
    previousEnabledSources = appdata.settings['enabledSources'];
    previousFavorites = appdata.settings['favorites'];
    appdata.settings['enabledSources'] = <String>[_testSourceKey];
    await AppTranslation.init();
    tempDir = await Directory.systemTemp.createTemp('venera-follow-ui-');
    final cache = NetworkFavoriteCacheManager();
    await cache.init(
      databasePath: '${tempDir.path}${Platform.pathSeparator}cache.db',
      migrateLegacy: false,
    );
    // A fully checked cache: the pre-scan database fallback would otherwise
    // claim "3 / 3 checked" (100%) while a scan task is still starting up.
    final data = _numericData(
      (page, [folder]) async =>
          Res([_comic('one'), _comic('two'), _comic('three')], subData: 1),
    );
    await cache.refreshFolders(data);
    await cache.refreshPage(data, folder, 1);
    final db = sqlite3.open('${tempDir.path}${Platform.pathSeparator}cache.db');
    for (final id in ['one', 'two', 'three']) {
      db.execute(
        '''INSERT INTO comic_check_state
           (source_key, comic_id, last_check_time, next_check_at,
            retry_after, check_suspect_gone)
           VALUES (?, ?, ?, ?, ?, ?)''',
        [
          _testSourceKey,
          id,
          1,
          DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch,
          null,
          0,
        ],
      );
    }
    db.dispose();
    expect(cache.countCachedComicsInFolders([folder]), 3);
    expect(cache.countUncheckedComicsInFolders([folder]), 0);

    appdata.settings['followUpdatesEnabled'] = true;
    appdata.settings['favorites'] = [_testSourceKey];
    appdata.settings['language'] = 'system';
    final source = _detailSource();
    source.data['account'] = <String, dynamic>{};
    ComicSourceManager().add(source);
  });

  tearDownAll(() {
    appdata.settings['followUpdatesEnabled'] = false;
    ComicSourceManager().remove(_testSourceKey);
    appdata.settings['enabledSources'] = previousEnabledSources;
    appdata.settings['favorites'] = previousFavorites;
    NetworkFavoriteCacheManager().close();
    tempDir.deleteSync(recursive: true);
  });

  tearDown(() {
    FollowUpdatesService.taskRunning.value = false;
    FollowUpdatesService.baselineStatus.value = null;
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // The page's dialogs use App.rootContext, so the app's root navigator
    // key must be attached to the test MaterialApp.
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: FollowUpdatesPage(),
      ),
    );
  }

  testWidgets('the page shows history without a fake progress card', (
    tester,
  ) async {
    FollowUpdatesService.taskRunning.value = true;
    await pumpPage(tester);

    expect(find.text(followUpdateScannerUnavailableMessage.tl), findsOneWidget);
    expect(find.text('Displayed scan state is historical'.tl), findsWidgets);
    expect(find.text('Checking updates'.tl), findsNothing);
    expect(find.text('Follow-up scan in progress'.tl), findsNothing);
    expect(find.text('Retry'.tl), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('the progress entry gives unavailable feedback', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byTooltip('Update check progress'.tl));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));

    expect(find.text(followUpdateScannerUnavailableMessage.tl), findsWidgets);
    expect(find.text('Retry'.tl), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
