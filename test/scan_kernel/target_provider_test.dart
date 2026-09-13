import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/source_adapter.dart';
import 'package:venera/foundation/scan/target_provider.dart';

import 'fakes.dart';

void main() {
  test('discovers unique comic identities from cached folders only', () async {
    final source = _comicSource('comic', ScanProducer.comic);
    final cache = _FakeCache(
      <NetworkFavoriteFolder>[_folder('comic', 'one'), _folder('comic', 'two')],
      <String, List<String>>{
        'one': ['a', 'b'],
        'two': ['b', 'c'],
      },
    );
    final adapter = FakeScanAdapter(sourceKey: source.key);
    final provider = ScanTargetProvider(
      cache: cache,
      sources: () => [source],
      sourceEnabled: (_) => true,
      favoriteSettingReader: () => ['comic'],
      sourceIsManaged: (_) => true,
      adapterFactory: (_) => adapter,
    );

    final snapshot = await provider.snapshot();

    expect(snapshot.works, hasLength(3));
    expect(snapshot.works.map((work) => work.comicId), ['a', 'b', 'c']);
    expect(snapshot.skippedSources, isEmpty);
    expect(adapter.comicLeases, isEmpty);
    expect(
      snapshot.works.every((work) => work.sourceSnapshot!.managed),
      isTrue,
    );
  });

  test(
    'discovers one default collection without filtering remote contents',
    () async {
      final source = _comicSource(
        'collection',
        ScanProducer.collection,
        singleFolder: true,
      );
      final cache = _FakeCache(
        <NetworkFavoriteFolder>[
          _folder('collection', 'favorites'),
          _folder('collection', 'archive'),
        ],
        <String, List<String>>{
          'favorites': ['cached-a'],
          'archive': ['cached-b'],
        },
      );
      final provider = ScanTargetProvider(
        cache: cache,
        sources: () => [source],
        sourceEnabled: (_) => true,
        favoriteSettingReader: () => ['collection'],
        adapterFactory: (value) => FakeScanAdapter(sourceKey: value.key),
      );

      final snapshot = await provider.snapshot();

      expect(snapshot.works, hasLength(1));
      expect(snapshot.works.single.producer, ScanProducer.collection);
      expect(snapshot.works.single.scopeKey, 'default');
    },
  );

  test(
    'reports absent, invalid, disabled, and unauthenticated sources',
    () async {
      final disabled = _comicSource('disabled', ScanProducer.comic);
      final missing = makeScanTestSource('missing');
      final invalid = makeScanTestSource(
        'invalid',
        scan: const ScanCapabilities.invalid('bad declaration'),
      );
      final account = AccountConfig(
        null,
        null,
        null,
        () {},
        null,
        null,
        null,
        null,
      );
      final loggedOut = makeScanTestSource(
        'logged-out',
        account: account,
        scan: const ScanCapabilities.supported(primary: ScanProducer.comic),
      );
      final cache = _FakeCache(
        <NetworkFavoriteFolder>[
          _folder('disabled', 'folder'),
          _folder('logged-out', 'folder'),
        ],
        <String, List<String>>{
          'folder': ['comic'],
        },
      );
      final provider = ScanTargetProvider(
        cache: cache,
        sources: () => [missing, invalid, disabled, loggedOut],
        sourceEnabled: (key) => key != 'disabled',
        favoriteSettingReader: () => [
          'missing',
          'invalid',
          'disabled',
          'logged-out',
        ],
        adapterFactory: (source) => FakeScanAdapter(sourceKey: source.key),
      );

      final snapshot = await provider.snapshot();

      expect(snapshot.works, isEmpty);
      expect(
        snapshot.skippedSources.map((item) => item.reason),
        containsAll(<ScanSourceSkipReason>[
          ScanSourceSkipReason.absent,
          ScanSourceSkipReason.invalid,
          ScanSourceSkipReason.disabled,
          ScanSourceSkipReason.notLoggedIn,
        ]),
      );
    },
  );

  test(
    'discovers only favorite sources even when stale folders remain cached',
    () async {
      final selected = _comicSource('selected', ScanProducer.comic);
      final excluded = _comicSource('excluded', ScanProducer.comic);
      final cache = _FakeCache(
        <NetworkFavoriteFolder>[
          _folder('selected', 'selected-folder'),
          _folder('excluded', 'excluded-folder'),
        ],
        <String, List<String>>{
          'selected-folder': ['selected-comic'],
          'excluded-folder': ['excluded-comic'],
        },
      );
      final provider = ScanTargetProvider(
        cache: cache,
        sources: () => [selected, excluded],
        sourceEnabled: (_) => true,
        favoriteSettingReader: () => ['selected'],
        adapterFactory: (source) => FakeScanAdapter(sourceKey: source.key),
      );

      final snapshot = await provider.snapshot();

      expect(snapshot.works.map((work) => work.sourceKey), ['selected']);
      expect(snapshot.works.single.comicId, 'selected-comic');
      expect(snapshot.skippedSources, isEmpty);
    },
  );

  test('missing or malformed favorites settings select no sources', () async {
    final source = _comicSource('source', ScanProducer.comic);
    final cache = _FakeCache(
      <NetworkFavoriteFolder>[_folder('source', 'folder')],
      <String, List<String>>{
        'folder': ['comic'],
      },
    );
    for (final setting in <Object?>[
      null,
      'source',
      ['source', 42],
    ]) {
      final provider = ScanTargetProvider(
        cache: cache,
        sources: () => [source],
        sourceEnabled: (_) => true,
        favoriteSettingReader: () => setting,
        adapterFactory: (value) => FakeScanAdapter(sourceKey: value.key),
      );
      expect((await provider.snapshot()).works, isEmpty);
    }
  });
}

ComicSource _comicSource(
  String key,
  ScanProducer producer, {
  bool singleFolder = false,
}) {
  final favoriteData = FavoriteData(
    key: key,
    title: key,
    multiFolder: !singleFolder,
    loadComic: null,
    loadNext: null,
    singleFolderForSingleComic: singleFolder,
  );
  final capability = producer == ScanProducer.comic
      ? ScanCapability.comic((_, __) async => const {})
      : ScanCapability.collection((_, __, ___) async => const {});
  return makeScanTestSource(
    key,
    favoriteData: favoriteData,
    scan: ScanCapabilities.supported(
      primary: producer,
      comic: producer == ScanProducer.comic ? capability : null,
      collection: producer == ScanProducer.collection ? capability : null,
    ),
  );
}

NetworkFavoriteFolder _folder(String source, String id) =>
    NetworkFavoriteFolder(
      sourceKey: source,
      folderId: id,
      title: id,
      updatedAt: DateTime.utc(2026, 9, 10),
    );

class _FakeCache extends NetworkFavoriteCacheManager {
  _FakeCache(this.folders, this.items) : super.forTesting();

  final List<NetworkFavoriteFolder> folders;
  final Map<String, List<String>> items;

  @override
  int get cacheGeneration => 0;

  @override
  List<NetworkFavoriteFolder> getAllCachedFolders() => folders;

  @override
  int countCachedComics(NetworkFavoriteFolderRef folder) =>
      items[folder.folderId]?.toSet().length ?? 0;

  @override
  int countCachedComicsInFolders(Iterable<NetworkFavoriteFolderRef> selected) =>
      {for (final folder in selected) ...?items[folder.folderId]}.length;

  @override
  List<FavoriteItemWithUpdateInfo> getComicsWithUpdatesInfoPageInFolders(
    Iterable<NetworkFavoriteFolderRef> selected, {
    required int limit,
    required int offset,
  }) {
    final ids = <String>{
      for (final folder in selected) ...?items[folder.folderId],
    }.toList()..sort();
    return [
      for (final id in ids.skip(offset).take(limit))
        FavoriteItemWithUpdateInfo(
          FavoriteItem(
            id: id,
            name: id,
            coverPath: '',
            author: '',
            sourceKeyValue: selected.first.sourceKey,
            tags: const [],
          ),
          null,
          null,
          false,
          null,
          null,
        ),
    ];
  }
}
