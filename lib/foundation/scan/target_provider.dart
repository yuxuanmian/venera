import '../appdata.dart';
import '../catalog/source_preferences.dart';
import '../comic_source/comic_source.dart';
import '../favorites.dart';
import '../js_engine.dart';
import '../log.dart';
import 'due_filter.dart';
import 'js_source_adapter.dart';
import 'models.dart';
import 'full_scan_planner.dart';
import 'scan_log.dart';
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

  /// Builds the round's frozen work list.
  ///
  /// [dueComicIdsBySource] narrows per-comic work to the identities that are
  /// actually due (Contract S4).  It is a plain map rather than a callback so
  /// this class stays free of both stores: the composition layer merges them
  /// and hands the answer down.  A source missing from the map contributes no
  /// per-comic work; collection work is unaffected, because a `(source, comic)`
  /// schedule cannot express it in the first place.
  ///
  /// [scopeSourceKeys] restricts which sources are visited at all (`null` =
  /// every configured one).  A source outside the scope is **skipped silently**,
  /// not reported in `skippedSources`: "this round is not about that source" is
  /// not a defect of the source, and reporting it would drown the
  /// absent/invalid/disabled diagnostics the second plan line exists for
  /// (Contract F1.4 / L3).
  ///
  /// [roundLabel] is the trigger's name, forwarded to the plan overview line so
  /// the log answers "who asked for this round?" as well as "what did it do?".
  Future<ScanTargetSnapshot> snapshot({
    Map<String, Set<String>>? dueComicIdsBySource,
    Set<String>? scopeSourceKeys,
    String? roundLabel,
  }) async {
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
      if (scopeSourceKeys != null && !scopeSourceKeys.contains(source.key)) {
        continue;
      }
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
        final entries = _readComicEntries(sourceFolders);
        for (final entry in entries) {
          works.add(
            ScanWorkSpec.comic(
              source: source,
              adapter: adapter,
              comicId: entry.comicId,
              // The display name is taken **here**, from the cache entry the
              // loop is already holding (007 Contract L4): no extra query and no
              // extra request.  `comicLabel` falls back to the identity when the
              // name is missing or unusable.
              logLabel: comicLabel(source.key, entry.name, entry.comicId),
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
    final unfiltered = ScanTargetSnapshot(
      works: works,
      cacheGeneration: startGeneration,
      skippedSources: skipped,
    );
    if (dueComicIdsBySource == null) {
      _logPlanOverview(
        snapshot: unfiltered,
        narrowed: unfiltered,
        roundLabel: roundLabel,
        scopeSourceKeys: scopeSourceKeys,
      );
      return unfiltered;
    }
    final narrowed = filterTargetsByDue(
      snapshot: unfiltered,
      dueComicIdsBySource: dueComicIdsBySource,
    );
    _logPlanOverview(
      snapshot: unfiltered,
      narrowed: narrowed,
      roundLabel: roundLabel,
      scopeSourceKeys: scopeSourceKeys,
    );
    return narrowed;
  }

  /// One **plan overview** per round, at most two lines (007 Contract L1/L3/L8).
  ///
  /// Emitted here because this is the only place that holds both halves of the
  /// answer: the frozen work list *after* the due rule narrowed it, and the
  /// sources that never produced work at all.  The line count does not depend on
  /// how many comics are in scope; per-comic identities appear only as the short
  /// request-log prefixes of L4.
  ///
  /// The trigger and the round's scope travel with it (F1.4): `works=1/141` on
  /// its own does not say whether one collection is the whole round or the only
  /// part of it that survived the due rule.
  void _logPlanOverview({
    required ScanTargetSnapshot snapshot,
    required ScanTargetSnapshot narrowed,
    String? roundLabel,
    Set<String>? scopeSourceKeys,
  }) {
    final bySource = <String, ScanPlanSourceLine>{};
    for (final work in narrowed.works) {
      final existing = bySource[work.sourceKey];
      bySource[work.sourceKey] = ScanPlanSourceLine(
        sourceKey: work.sourceKey,
        unit: work.producer.value,
        workCount: (existing?.workCount ?? 0) + 1,
      );
    }
    final skippedByReason = <ScanSourceSkipReason, List<String>>{};
    for (final skip in snapshot.skippedSources) {
      skippedByReason.putIfAbsent(skip.reason, () => []).add(skip.sourceKey);
    }
    final lines = formatPlanOverview(
      perSource: bySource.keys.map((key) => bySource[key]!).toList()
        ..sort((a, b) => a.sourceKey.compareTo(b.sourceKey)),
      worksBeforeNarrowing: snapshot.works.length,
      worksAfterNarrowing: narrowed.works.length,
      skippedByReason: skippedByReason,
      trigger: roundLabel,
      scopeSourceKeys: scopeSourceKeys,
    );
    // Deliberately `info`, and deliberately unconditional: the round overview
    // is the same level as the existing scan transport lines, and MUST NOT
    // depend on developer mode (L6) — otherwise a release build has no lead when
    // a scan misbehaves.
    for (final line in lines) {
      Log.info('Scan', line);
    }
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

  /// One entry per per-comic work item: the identity and the display name.
  ///
  /// The name is read from the same page of cache entries the identity comes
  /// from — the loop already holds it, so the log label costs no extra query and
  /// no extra request (007 R-04 / F-10).  A missing name is a normal case, not an
  /// error: `comicLabel` falls back to the identity.
  List<({String comicId, String? name})> _readComicEntries(
    List<NetworkFavoriteFolderRef> folders,
  ) {
    if (folders.isEmpty) return const [];
    final count = cache.countCachedComicsInFolders(folders);
    if (count <= 0) return const [];
    final entries = <String, String?>{};
    for (var offset = 0; offset < count; offset += pageSize) {
      final page = cache.getComicsWithUpdatesInfoPageInFolders(
        folders,
        limit: pageSize,
        offset: offset,
      );
      for (final item in page) {
        entries.putIfAbsent(item.id, () => item.name);
      }
      if (page.isEmpty) break;
    }
    final ids = entries.keys.toList()..sort();
    return [for (final id in ids) (comicId: id, name: entries[id])];
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
