import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/utils/translations.dart';

FavoriteItem _comic(String id) => FavoriteItem(
  id: id,
  name: 'Comic $id',
  coverPath: 'https://example.invalid/$id.jpg',
  author: 'Author',
  sourceKeyValue: 'test-source',
  tags: const ['tag'],
);

FavoriteData _numericData(
  Future<Res<List<Comic>>> Function(int page, [String? folder]) loader,
) => FavoriteData(
  key: 'test-source',
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
    'test-source',
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
        'sourceKey': 'test-source',
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
  const folder = NetworkFavoriteFolderRef(
    sourceKey: 'test-source',
    folderId: 'remote',
    title: 'Remote',
  );

  setUpAll(() async {
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
           (source_key, comic_id, last_check_time, retry_after,
            check_suspect_gone)
           VALUES (?, ?, ?, ?, ?)''',
        ['test-source', id, 1, null, 0],
      );
    }
    db.dispose();
    expect(cache.countCachedComicsInFolders([folder]), 3);
    expect(cache.countUncheckedComicsInFolders([folder]), 0);

    appdata.settings['followUpdatesEnabled'] = true;
    appdata.settings['favorites'] = ['test-source'];
    appdata.settings['language'] = 'system';
    final source = _detailSource();
    source.data['account'] = <String, dynamic>{};
    ComicSourceManager().add(source);
  });

  tearDownAll(() {
    appdata.settings['followUpdatesEnabled'] = false;
    ComicSourceManager().remove('test-source');
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

  testWidgets(
    'progress card stays indeterminate until the scan publishes its queue',
    (tester) async {
      // A restart triggers the auto scan: the task is running but the queue
      // numbers have not been published yet (summaries refreshing).
      FollowUpdatesService.taskRunning.value = true;
      FollowUpdatesService.baselineStatus.value = null;
      await pumpPage(tester);

      expect(find.text('Checking updates'.tl), findsOneWidget);
      // No database-derived counts in the pre-first-frame window.
      expect(find.textContaining('checked'), findsNothing);
      final indicator = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(indicator.value, isNull);
      expect(find.text('Follow-up scan in progress'.tl), findsOneWidget);
      expect(find.text('Retry'.tl), findsNothing);

      // First frame arrives: the queue's own numbers take over.
      FollowUpdatesService.baselineStatus.value = const BaselineStatus(
        isRunning: true,
        total: 300,
        completed: 7,
        errors: 0,
        updated: 0,
      );
      await tester.pump();
      expect(find.text('7 / 300 checked'), findsOneWidget);
      final runningIndicator = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(runningIndicator.value, closeTo(7 / 300, 1e-9));

      // The task finishes with everything checked: the card disappears.
      FollowUpdatesService.taskRunning.value = false;
      FollowUpdatesService.baselineStatus.value = null;
      await tester.pump();
      expect(find.text('Checking updates'.tl), findsNothing);
    },
  );

  testWidgets('progress dialog mirrors the card in the starting window', (
    tester,
  ) async {
    FollowUpdatesService.taskRunning.value = true;
    FollowUpdatesService.baselineStatus.value = null;
    await pumpPage(tester);

    await tester.tap(find.byTooltip('Update check progress'.tl));
    // Dialog entrance animation; the indeterminate indicators never settle,
    // so advance fixed frames instead of pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Update check progress'.tl), findsOneWidget);
    // Neither the card nor the dialog renders DB-derived counts while the
    // task is starting, and neither offers Retry.
    expect(find.textContaining('checked'), findsNothing);
    expect(find.text('Follow-up scan in progress'.tl), findsNWidgets(2));
    expect(find.text('Retry'.tl), findsNothing);

    // The published queue numbers show up in both places.
    FollowUpdatesService.baselineStatus.value = const BaselineStatus(
      isRunning: true,
      total: 300,
      completed: 7,
      errors: 0,
      updated: 0,
    );
    await tester.pump();
    expect(find.text('7 / 300 checked'), findsNWidgets(2));
  });
}
