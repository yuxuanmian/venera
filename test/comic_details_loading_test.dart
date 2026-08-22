import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

class _DetailFixture {
  _DetailFixture({
    required this.sourceKey,
    required this.comicId,
    required this.loadFolders,
  });

  final String sourceKey;

  final String comicId;

  final Future<Res<Map<String, String>>> Function(String comicId) loadFolders;

  ComicSource buildSource() {
    final coverPath =
        'file://${Directory.current.path}${Platform.pathSeparator}assets'
        '${Platform.pathSeparator}app_icon.png';
    final favoriteData = FavoriteData(
      key: sourceKey,
      title: 'Favorites',
      multiFolder: true,
      loadComic: null,
      loadNext: null,
      loadFolders: ([String? id]) => loadFolders(id ?? comicId),
    );
    final source = ComicSource(
      'Test source',
      sourceKey,
      null,
      null,
      null,
      favoriteData,
      const [],
      null,
      null,
      (id) async => Res(
        ComicDetails.fromJson({
          'title': 'Comic $id',
          'subtitle': 'Author',
          'cover': coverPath,
          'description': 'Details loaded',
          'tags': <String, List<String>>{},
          'chapters': <String, String>{'ep': 'Chapter'},
          'sourceKey': sourceKey,
          'comicId': id,
          'isFavorite': false,
          'isLiked': false,
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
    source.data['account'] = const ['logged-in'];
    return source;
  }
}

Future<void> _pumpDetail(WidgetTester tester, _DetailFixture fixture) async {
  ComicSourceManager().add(fixture.buildSource());
  await tester.pumpWidget(
    MaterialApp(
      home: ComicPage(id: fixture.comicId, sourceKey: fixture.sourceKey),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    await AppTranslation.init();
    tempDir = await Directory.systemTemp.createTemp('venera-detail-loading-');
    App.dataPath = tempDir.path;
    App.cachePath = tempDir.path;
    await HistoryManager().init();
    await NetworkFavoriteCacheManager().init(
      databasePath: '${tempDir.path}${Platform.pathSeparator}favorites.db',
      migrateLegacy: false,
    );
  });

  testWidgets('details render while loadFolders is pending', (tester) async {
    final folders = Completer<Res<Map<String, String>>>();
    const sourceKey = 'detail-pending-source';
    const comicId = 'pending-comic';
    final fixture = _DetailFixture(
      sourceKey: sourceKey,
      comicId: comicId,
      loadFolders: (_) => folders.future,
    );
    await _pumpDetail(tester, fixture);

    expect(find.text('Comic $comicId'), findsWidgets);
    expect(find.byType(NetworkError), findsNothing);

    folders.complete(const Res({'folder': 'Folder'}, subData: ['folder']));
    await tester.pump();
    await tester.pump();

    expect(
      NetworkFavoriteCacheManager().isFavoriteKnown(sourceKey, comicId),
      isTrue,
    );
  });

  testWidgets('folder refresh errors do not replace the detail body', (
    tester,
  ) async {
    final folders = Completer<Res<Map<String, String>>>();
    const sourceKey = 'detail-error-source';
    const comicId = 'error-comic';
    await _pumpDetail(
      tester,
      _DetailFixture(
        sourceKey: sourceKey,
        comicId: comicId,
        loadFolders: (_) => folders.future,
      ),
    );
    folders.complete(const Res.error('folder request failed'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Comic $comicId'), findsWidgets);
    expect(find.byType(NetworkError), findsNothing);
  });

  testWidgets('disposing before folder refresh completes is safe', (
    tester,
  ) async {
    final folders = Completer<Res<Map<String, String>>>();
    const sourceKey = 'detail-dispose-source';
    const comicId = 'dispose-comic';
    await _pumpDetail(
      tester,
      _DetailFixture(
        sourceKey: sourceKey,
        comicId: comicId,
        loadFolders: (_) => folders.future,
      ),
    );
    await tester.pumpWidget(const SizedBox());
    folders.complete(const Res({'folder': 'Folder'}, subData: ['folder']));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('empty remote membership preserves known favorite', (
    tester,
  ) async {
    const sourceKey = 'detail-known-source';
    const comicId = 'known-comic';
    final cache = NetworkFavoriteCacheManager();
    cache.replaceComicMembership(sourceKey, comicId, const ['old-folder']);
    final folders = Completer<Res<Map<String, String>>>();
    await _pumpDetail(
      tester,
      _DetailFixture(
        sourceKey: sourceKey,
        comicId: comicId,
        loadFolders: (_) => folders.future,
      ),
    );
    folders.complete(const Res({'folder': 'Folder'}, subData: <String>[]));
    await tester.pump();
    await tester.pump();

    expect(cache.isFavoriteKnown(sourceKey, comicId), isTrue);
  });

  testWidgets('empty remote membership clears unknown favorite', (
    tester,
  ) async {
    const sourceKey = 'detail-unknown-source';
    const comicId = 'unknown-comic';
    final folders = Completer<Res<Map<String, String>>>();
    await _pumpDetail(
      tester,
      _DetailFixture(
        sourceKey: sourceKey,
        comicId: comicId,
        loadFolders: (_) => folders.future,
      ),
    );
    folders.complete(const Res({'folder': 'Folder'}, subData: <String>[]));
    await tester.pump();
    await tester.pump();

    expect(
      NetworkFavoriteCacheManager().isFavoriteKnown(sourceKey, comicId),
      isFalse,
    );
  });
}
