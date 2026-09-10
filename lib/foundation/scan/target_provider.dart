import '../appdata.dart';
import '../catalog/source_preferences.dart';
import '../comic_source/comic_source.dart';
import '../favorites.dart';
import '../js_engine.dart';
import 'js_source_adapter.dart';
import 'models.dart';
import 'full_scan_planner.dart';
import 'source_adapter.dart';

class ScanTargetSnapshot {
  ScanTargetSnapshot({
    required Iterable<ScanWorkSpec> works,
    required this.cacheGeneration,
    Iterable<ScanSourceSkip> skippedSources = const [],
  }) : works = List.unmodifiable(works),
       skippedSources = List.unmodifiable(skippedSources);

  final List<ScanWorkSpec> works;
  final int cacheGeneration;
  final List<ScanSourceSkip> skippedSources;
}

typedef ScanSourceAdapterFactory =
    ScanSourceAdapter Function(ComicSource source);

/// Reads only the public favorite-cache projections needed to discover a
/// frozen set of scan targets. It never refreshes a source or consults the
/// old update-check strategy.
class ScanTargetProvider {
  ScanTargetProvider({
    NetworkFavoriteCacheManager? cache,
    Iterable<ComicSource> Function()? sources,
    bool Function(String key)? sourceEnabled,
    ScanSourceAdapterFactory? adapterFactory,
    Object? Function()? favoriteSettingReader,
    bool Function(ComicSource source)? sourceIsManaged,
    this.pageSize = 256,
  }) : cache = cache ?? NetworkFavoriteCacheManager(),
       _sources = sources ?? ComicSource.all,
       _sourceEnabled = sourceEnabled ?? isSourceEnabled,
       _adapterFactory = adapterFactory ?? _defaultAdapterFactory,
       _favoriteSettingReader =
           favoriteSettingReader ?? (() => appdata.settings['favorites']),
       _sourceIsManaged =
           sourceIsManaged ??
           ((source) => identical(ComicSource.find(source.key), source));

  final NetworkFavoriteCacheManager cache;
  final Iterable<ComicSource> Function() _sources;
  final bool Function(String key) _sourceEnabled;
  final ScanSourceAdapterFactory _adapterFactory;
  final Object? Function() _favoriteSettingReader;
  final bool Function(ComicSource source) _sourceIsManaged;
  final int pageSize;

  Future<ScanTargetSnapshot> snapshot() async {
    final startGeneration = cache.cacheGeneration;
    final folders = cache.getAllCachedFolders();
    final bySource = <String, List<NetworkFavoriteFolderRef>>{};
    for (final folder in folders) {
      bySource.putIfAbsent(folder.sourceKey, () => []).add(folder);
    }
    final works = <ScanWorkSpec>[];
    final skipped = <ScanSourceSkip>[];
    final favoriteSourceKeys = _readFavoriteSourceKeys();

    for (final source in _sources()) {
      if (!favoriteSourceKeys.contains(source.key)) continue;
      final sourceSnapshot = ScanSourceSnapshot(
        managed: _sourceIsManaged(source),
        accountIdentity: _accountSnapshot(source),
      );
      final capabilities = source.scan;
      if (capabilities == null ||
          capabilities.state == ScanCapabilitiesState.absent) {
        skipped.add(
          ScanSourceSkip(
            sourceKey: source.key,
            reason: ScanSourceSkipReason.absent,
          ),
        );
        continue;
      }
      if (!capabilities.isSupported) {
        skipped.add(
          ScanSourceSkip(
            sourceKey: source.key,
            reason: ScanSourceSkipReason.invalid,
            message: capabilities.reason,
          ),
        );
        continue;
      }
      if (!_sourceEnabled(source.key)) {
        skipped.add(
          ScanSourceSkip(
            sourceKey: source.key,
            reason: ScanSourceSkipReason.disabled,
          ),
        );
        continue;
      }
      if (source.account != null && !source.isLogged) {
        skipped.add(
          ScanSourceSkip(
            sourceKey: source.key,
            reason: ScanSourceSkipReason.notLoggedIn,
          ),
        );
        continue;
      }
      final capability = capabilities.selected;
      if (capability == null) {
        skipped.add(
          ScanSourceSkip(
            sourceKey: source.key,
            reason: ScanSourceSkipReason.invalid,
            message: 'selected scan capability is missing',
          ),
        );
        continue;
      }
      final sourceFolders =
          bySource[source.key] ?? const <NetworkFavoriteFolderRef>[];
      final adapter = _adapterFactory(source);
      if (capability.producer == ScanProducer.comic) {
        final ids = _readComicIds(sourceFolders);
        for (final id in ids) {
          works.add(
            ScanWorkSpec.comic(
              source: source,
              adapter: adapter,
              comicId: id,
              sourceSnapshot: sourceSnapshot,
            ),
          );
        }
      } else {
        final collectionKeys = <String>{};
        if (source.favoriteData?.multiFolder == false) {
          if (sourceFolders.any(
            (folder) => cache.countCachedComics(folder) > 0,
          )) {
            collectionKeys.add('default');
          }
        } else {
          for (final folder in sourceFolders) {
            if (cache.countCachedComics(folder) > 0) {
              collectionKeys.add(folder.folderId);
            }
          }
        }
        for (final key in collectionKeys.toList()..sort()) {
          works.add(
            ScanWorkSpec.collection(
              source: source,
              adapter: adapter,
              collectionKey: key,
              sourceSnapshot: sourceSnapshot,
            ),
          );
        }
      }
      if (cache.cacheGeneration != startGeneration) {
        throw const ScanControlException(ScanControlReason.cacheInvalidated);
      }
    }
    if (cache.cacheGeneration != startGeneration) {
      throw const ScanControlException(ScanControlReason.cacheInvalidated);
    }
    return ScanTargetSnapshot(
      works: works,
      cacheGeneration: startGeneration,
      skippedSources: skipped,
    );
  }

  Set<String> _readFavoriteSourceKeys() {
    final raw = _favoriteSettingReader();
    if (raw is! List || raw.any((value) => value is! String)) {
      return const <String>{};
    }
    return raw.cast<String>().where((value) => value.isNotEmpty).toSet();
  }

  static List<String> _accountSnapshot(ComicSource source) {
    final raw = source.data['account'];
    if (raw is! Iterable) return const [];
    for (final value in raw) {
      if (value is String && value.isNotEmpty) return [value];
    }
    return const [];
  }

  List<String> _readComicIds(List<NetworkFavoriteFolderRef> folders) {
    if (folders.isEmpty) return const [];
    final count = cache.countCachedComicsInFolders(folders);
    if (count <= 0) return const [];
    final ids = <String>{};
    for (var offset = 0; offset < count; offset += pageSize) {
      final page = cache.getComicsWithUpdatesInfoPageInFolders(
        folders,
        limit: pageSize,
        offset: offset,
      );
      for (final item in page) {
        ids.add(item.id);
      }
      if (page.isEmpty) break;
    }
    return ids.toList()..sort();
  }

  static ScanSourceAdapter _defaultAdapterFactory(ComicSource source) {
    final capabilities = source.scan;
    if (capabilities == null || !capabilities.isSupported) {
      throw StateError('source has no supported scan capability');
    }
    return JsScanSourceAdapter(
      sourceKey: source.key,
      definitionRevision: source.version,
      capabilities: capabilities,
      runtimeContext: source.runtimeContext,
      requestFactory: (lease) =>
          (request) => JsEngine().requestForScan(
            request,
            source.runtimeContext,
            lease: lease,
          ),
    );
  }
}
