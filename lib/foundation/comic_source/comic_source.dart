library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/follow_update_schedule.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/tracking/update_state.dart';
import 'package:venera/foundation/tracking/source_revision_manager.dart';
import 'package:venera/foundation/tracking/source_revision_store.dart';
import 'package:venera/foundation/tracking/source_runtime_policy.dart';
import 'package:venera/foundation/tracking/trusted_catalog.dart';
import 'package:venera/pages/category_comics_page.dart';
import 'package:venera/pages/search_result_page.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/init.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

import '../js_engine.dart';
import '../log.dart';

part 'category.dart';

part 'favorites.dart';

part 'parser.dart';

part 'models.dart';

part 'types.dart';

class ComicSourceManager with ChangeNotifier, Init {
  final List<ComicSource> _sources = [];

  static ComicSourceManager? _instance;

  ComicSourceManager._create();

  factory ComicSourceManager() => _instance ??= ComicSourceManager._create();

  List<ComicSource> all() => List.from(_sources);

  ComicSource? find(String key) =>
      _sources.firstWhereOrNull((element) => element.key == key);

  ComicSource? fromIntKey(int key) =>
      _sources.firstWhereOrNull((element) => element.key.hashCode == key);

  /// Requires the manager to contain the exact selected artifact, rather than
  /// merely a source with the same key.  Same-key variants are independent
  /// runtime identities and must not satisfy one another's reload checks.
  void requireLoadedArtifact(ActiveArtifact artifact) {
    final expectedPath = p.normalize(
      p.absolute(p.join(App.dataPath, 'comic_source', artifact.relativePath)),
    );
    final matches = _sources.where(
      (source) =>
          source.key == artifact.sourceKey &&
          p.equals(p.normalize(p.absolute(source.filePath)), expectedPath),
    );
    if (matches.length != 1) {
      throw StateError(
        'Expected exactly one loaded runtime for ${artifact.fileName}, '
        'found ${matches.length}',
      );
    }
  }

  @override
  @protected
  Future<void> doInit() async {
    await App.cloudTracking.withCommitLock(() => _initialize());
  }

  Future<void> _initialize({
    ActiveArtifact? requiredArtifact,
    bool strictRequiredArtifact = false,
  }) async {
    await JsEngine().ensureInit();
    final path = "${App.dataPath}/comic_source";
    final sourceDirectory = Directory(path);
    if (!(await sourceDirectory.exists())) {
      await sourceDirectory.create(recursive: true);
    }
    final loadedPaths = <String>{};
    final store = SourceRevisionStore(sourceDirectory);
    try {
      final registry = await store.load() ?? const ActiveArtifactRegistry();
      // Production startup prepares this state before the manager is entered.
      // Keep direct/test reloads safe as well, without weakening an already
      // prepared Cloud admission boundary.
      if (sourceRuntimePolicy.registry == null ||
          sourceRuntimePolicy.sourceDirectoryPath == null) {
        sourceRuntimePolicy.prepare(
          cloudEnabled: sourceRuntimePolicy.cloudEnabled,
          registry: registry,
          sourceDirectoryPath: sourceDirectory.path,
          authorityRevision: sourceRuntimePolicy.authorityRevision,
          operationEpoch: sourceRuntimePolicy.operationEpoch,
        );
      }
      for (final artifact in registry.artifacts) {
        final file = store.fileForRelativePath(artifact.relativePath);
        if (!(await file.exists())) continue;
        // A blocked artifact is never part of ordinary discovery.  The only
        // exception is the exact artifact requested by an activation/edit
        // transaction while its one-shot candidate permit is still live.
        // That permit is checked again by ComicSourceParser before any JS
        // boundary, so a blocked working copy cannot become a normal runtime.
        final candidatePermit =
            requiredArtifact != null &&
                artifact.identity == requiredArtifact.identity
            ? sourceRuntimePolicy.permitForPath(file.path)
            : null;
        if (artifact.activationBlocked && candidatePermit == null) continue;
        try {
          await store.readBytes(artifact);
          final source = await file.readAsString();
          final parsed = await ComicSourceParser().parse(
            source,
            file.absolute.path,
            runtimePermit: candidatePermit,
            allowExistingKey: true,
          );
          if (requiredArtifact != null &&
              artifact.identity == requiredArtifact.identity) {
            if (artifact.relativePath != requiredArtifact.relativePath ||
                artifact.sha256 != requiredArtifact.sha256 ||
                parsed.key != requiredArtifact.sourceKey) {
              throw StateError("required artifact runtime identity mismatch");
            }
          }
          _sources.add(parsed);
          loadedPaths.add(file.absolute.path);
        } catch (e, s) {
          Log.error("ComicSource", "$e\n$s");
          if (strictRequiredArtifact &&
              requiredArtifact != null &&
              artifact.identity == requiredArtifact.identity) {
            rethrow;
          }
        }
      }
    } catch (e, s) {
      Log.error(
        "ComicSource",
        "Failed to load active artifact registry: $e\n$s",
      );
      if (strictRequiredArtifact) rethrow;
    }
    if (!sourceRuntimePolicy.cloudEnabled) {
      await for (var entity in sourceDirectory.list()) {
        if (entity is File && entity.path.endsWith(".js")) {
          if (loadedPaths.contains(entity.absolute.path) ||
              !sourceRuntimePolicy.allowUnmanagedRoot(entity.path)) {
            continue;
          }
          try {
            await _registerAndLoadLegacyRoot(entity, store, loadedPaths);
          } on _StaleLocalAdmission {
            // A newer mode request owns the next transition.  Do not continue
            // scanning root files under the old Local admission.
            break;
          } catch (e, s) {
            Log.error("ComicSource", "$e\n$s");
          }
        }
      }
    }
    if (strictRequiredArtifact && requiredArtifact != null) {
      final loaded = _sources.where(
        (source) =>
            source.key == requiredArtifact.sourceKey &&
            File(source.filePath).absolute.path ==
                store
                    .fileForRelativePath(requiredArtifact.relativePath)
                    .absolute
                    .path,
      );
      if (loaded.length != 1) {
        throw StateError("required artifact runtime was not loaded");
      }
    }
  }

  Future<void> _registerAndLoadLegacyRoot(
    File file,
    SourceRevisionStore store,
    Set<String> loadedPaths,
  ) async {
    final epoch = sourceRuntimePolicy.operationEpoch;
    void requireLocalCurrent() {
      if (sourceRuntimePolicy.operationEpoch != epoch ||
          sourceRuntimePolicy.cloudEnabled ||
          sourceRuntimePolicy.pendingCloudEnable ||
          !sourceRuntimePolicy.admissionReady ||
          sourceRuntimePolicy.admissionSuspended) {
        throw const _StaleLocalAdmission();
      }
    }

    requireLocalCurrent();
    final rawBytes = await file.readAsBytes();
    requireLocalCurrent();
    final probe = await ComicSourceParser().parse(
      utf8.decode(rawBytes, allowMalformed: false),
      file.absolute.path,
      register: false,
      allowExistingKey: true,
      loadData: false,
      scheduleInit: false,
    );
    final sourceKey = probe.key;
    requireLocalCurrent();

    final registered = await store.registerVerifiedLegacyRoot(
      fileName: p.basename(file.path),
      sourceKey: sourceKey,
      expectedBytes: rawBytes,
      requireCurrent: requireLocalCurrent,
    );
    requireLocalCurrent();
    final identity = TrustedArtifact(
      sourceKey: sourceKey,
      fileName: p.basename(file.path),
    );
    final registeredArtifact = registered.find(sourceKey, identity.fileName);
    if (registeredArtifact == null || !registeredArtifact.activationBlocked) {
      throw StateError('legacy source registration did not remain blocked');
    }
    sourceRuntimePolicy.updateRegistry(
      registered,
      authorityRevision: sourceRuntimePolicy.authorityRevision,
    );

    final normalizedHash = SourceRevisionManager(
      store: store,
    ).normalizedSourceHash(rawBytes);
    final permit = sourceRuntimePolicy.issueCandidatePermit(
      identity: identity,
      path: store.fileForRelativePath(registeredArtifact.relativePath).path,
      sha256: normalizedHash,
      revision: null,
    );
    SourceRuntimeExecutionContext? formalContext;
    try {
      final loaded = await ComicSourceParser().parse(
        utf8.decode(rawBytes, allowMalformed: false),
        file.absolute.path,
        register: true,
        allowExistingKey: true,
        loadData: true,
        scheduleInit: true,
        runtimePermit: permit,
      );
      formalContext = sourceRuntimePolicy.contextForRuntimeKey(sourceKey);
      requireLocalCurrent();
      final expectedPath = p.normalize(
        p.absolute(
          store.fileForRelativePath(registeredArtifact.relativePath).path,
        ),
      );
      if (loaded.key != sourceKey ||
          !p.equals(p.normalize(p.absolute(loaded.filePath)), expectedPath)) {
        throw StateError('legacy source runtime identity mismatch');
      }
      final actualBytes = await file.readAsBytes();
      requireLocalCurrent();
      if (sha256.convert(actualBytes).toString() != registeredArtifact.sha256) {
        throw const FormatException(
          'legacy source bytes changed after registration',
        );
      }
      final latest = await store.load() ?? const ActiveArtifactRegistry();
      requireLocalCurrent();
      final selected = latest.find(sourceKey, identity.fileName);
      if (selected == null ||
          !_sameLegacySelection(selected, registeredArtifact) ||
          !selected.activationBlocked) {
        throw const SourceRuntimeDenied(
          'Legacy source selection changed before activation.',
        );
      }
      final unblocked = await SourceRevisionManager(
        store: store,
      ).setActivationBlocked(identity, false);
      requireLocalCurrent();
      final activated = unblocked.find(sourceKey, identity.fileName);
      if (activated == null ||
          !_sameLegacySelection(activated, registeredArtifact) ||
          activated.activationBlocked) {
        throw const SourceRuntimeDenied(
          'Legacy source selection changed during activation.',
        );
      }
      sourceRuntimePolicy.updateRegistry(
        unblocked,
        authorityRevision: sourceRuntimePolicy.authorityRevision,
      );
      sourceRuntimePolicy.promoteRuntime(identity);
      if (!sourceRuntimePolicy.hasActiveRuntime(activated)) {
        throw StateError('legacy source runtime was not admitted after reload');
      }
      _sources.add(loaded);
      loadedPaths.add(file.absolute.path);
    } catch (_) {
      formalContext?.revoke();
      await _keepLegacySelectionBlocked(store, identity, registeredArtifact);
      rethrow;
    } finally {
      sourceRuntimePolicy.revoke(permit);
    }
  }

  Future<void> _keepLegacySelectionBlocked(
    SourceRevisionStore store,
    TrustedArtifact identity,
    ActiveArtifact owned,
  ) async {
    try {
      final latest = await store.load();
      final selected = latest?.find(identity.sourceKey, identity.fileName);
      if (selected == null ||
          !_sameLegacySelection(selected, owned) ||
          selected.activationBlocked) {
        return;
      }
      final blocked = await SourceRevisionManager(
        store: store,
      ).setActivationBlocked(identity, true, preserveLastKnownGood: true);
      sourceRuntimePolicy.updateRegistry(
        blocked,
        authorityRevision: sourceRuntimePolicy.authorityRevision,
      );
    } catch (error, stack) {
      Log.error('Block failed legacy source activation', error, stack);
    }
  }

  /// Reload implementation for callers that already hold the Cloud tracking
  /// commit lock.  This method deliberately does not acquire the lock again;
  /// callers must use [App.cloudTracking.withCommitLock].
  Future<void> reloadUnderCommitLock({ActiveArtifact? requiredArtifact}) async {
    sourceRuntimePolicy.revokeLoadedRuntimes();
    _sources.clear();
    JsEngine().runCode("ComicSource.sources = {};");
    await _initialize(
      requiredArtifact: requiredArtifact,
      strictRequiredArtifact: requiredArtifact != null,
    );
  }

  /// Public reload entry point for callers that do not already own the shared
  /// source commit transaction.
  Future<void> reload({ActiveArtifact? requiredArtifact}) async {
    await App.cloudTracking.withCommitLock(
      () => reloadUnderCommitLock(requiredArtifact: requiredArtifact),
    );
    notifyListeners();
  }

  void add(ComicSource source) {
    _sources.add(source);
    notifyListeners();
  }

  void remove(String key) {
    sourceRuntimePolicy.revokeLoadedRuntimes(sourceKey: key);
    _sources.removeWhere((element) => element.key == key);
    notifyListeners();
  }

  bool get isEmpty => _sources.isEmpty;

  /// Key is the source key, value is the version.
  final _availableUpdates = <String, String>{};

  void updateAvailableUpdates(Map<String, String> updates) {
    _availableUpdates.addAll(updates);
    notifyListeners();
  }

  Map<String, String> get availableUpdates => Map.from(_availableUpdates);

  void notifyStateChange() {
    notifyListeners();
  }
}

class _StaleLocalAdmission implements Exception {
  const _StaleLocalAdmission();
}

bool _sameLegacySelection(ActiveArtifact left, ActiveArtifact right) =>
    left.sourceKey == right.sourceKey &&
    left.fileName == right.fileName &&
    left.revision == right.revision &&
    left.relativePath == right.relativePath &&
    left.origin == right.origin &&
    left.sha256 == right.sha256 &&
    left.cloudCapable == right.cloudCapable;

class ComicSource {
  static List<ComicSource> all() => ComicSourceManager().all();

  static ComicSource? find(String key) => ComicSourceManager().find(key);

  static ComicSource? fromIntKey(int key) =>
      ComicSourceManager().fromIntKey(key);

  static bool get isEmpty => ComicSourceManager().isEmpty;

  /// Name of this source.
  final String name;

  /// Identifier of this source.
  final String key;

  int get intKey {
    return key.hashCode;
  }

  /// Account config.
  final AccountConfig? account;

  /// Category data used to build a static category tags page.
  final CategoryData? categoryData;

  /// Category comics data used to build a comics page with a category tag.
  final CategoryComicsData? categoryComicsData;

  /// Favorite data used to build favorite page.
  final FavoriteData? favoriteData;

  /// Explore pages.
  final List<ExplorePageData> explorePages;

  /// Search page.
  final SearchPageData? searchPageData;

  /// Load comic info.
  final LoadComicFunc? loadComicInfo;

  final ComicThumbnailLoader? loadComicThumbnail;

  /// Load comic pages.
  final LoadComicPagesFunc? loadComicPages;

  final GetImageLoadingConfigFunc? getImageLoadingConfig;

  final Map<String, dynamic> Function(String imageKey)?
  getThumbnailLoadingConfig;

  var data = <String, dynamic>{};

  bool get isLogged => data["account"] != null;

  final String filePath;

  final String url;

  final String version;

  final CommentsLoader? commentsLoader;

  final SendCommentFunc? sendCommentFunc;

  final ChapterCommentsLoader? chapterCommentsLoader;

  final SendChapterCommentFunc? sendChapterCommentFunc;

  final RegExp? idMatcher;

  final LikeOrUnlikeComicFunc? likeOrUnlikeComic;

  final VoteCommentFunc? voteCommentFunc;

  final LikeCommentFunc? likeCommentFunc;

  final Map<String, Map<String, dynamic>>? settings;

  final Map<String, Map<String, String>>? translations;

  final HandleClickTagEvent? handleClickTagEvent;

  /// Callback when a tag suggestion is selected in search.
  final TagSuggestionSelectFunc? onTagSuggestionSelected;

  final LinkHandler? linkHandler;

  final bool enableTagsSuggestions;

  final bool enableTagsTranslate;

  final StarRatingFunc? starRatingFunc;

  final ArchiveDownloader? archiveDownloader;

  Future<void> loadData() async {
    var file = File("${App.dataPath}/comic_source/$key.data");
    if (await file.exists()) {
      data = Map.from(jsonDecode(await file.readAsString()));
    }
  }

  bool _isSaving = false;
  bool _haveWaitingTask = false;

  Future<void> saveData({SourceRuntimeExecutionContext? runtimeContext}) async {
    if (runtimeContext != null) {
      sourceRuntimePolicy.requireExecutionContext(runtimeContext);
    }
    if (_haveWaitingTask) return;
    while (_isSaving) {
      _haveWaitingTask = true;
      await Future.delayed(const Duration(milliseconds: 20));
      _haveWaitingTask = false;
      if (runtimeContext != null) {
        sourceRuntimePolicy.requireExecutionContext(runtimeContext);
      }
    }
    _isSaving = true;
    try {
      var file = File("${App.dataPath}/comic_source/$key.data");
      if (!await file.exists()) {
        await file.create(recursive: true);
      }
      if (runtimeContext != null) {
        sourceRuntimePolicy.requireExecutionContext(runtimeContext);
      }
      await file.writeAsString(jsonEncode(data));
      if (runtimeContext != null) {
        sourceRuntimePolicy.requireExecutionContext(runtimeContext);
      }
      DataSync().uploadData();
    } finally {
      _isSaving = false;
    }
  }

  Future<bool> reLogin() async {
    if (data["account"] == null) {
      return false;
    }
    final List accountData = data["account"];
    var res = await account!.login!(accountData[0], accountData[1]);
    if (res.error) {
      Log.error("Failed to re-login", res.errorMessage ?? "Error");
    }
    return !res.error;
  }

  /// Get settings dynamically from JavaScript source.
  /// This allows sources to use getters for dynamic settings that can change at runtime.
  Map<String, Map<String, dynamic>>? getSettingsDynamic() {
    try {
      var value = JsEngine().runCode("ComicSource.sources.$key.settings");
      if (value is Map) {
        var newMap = <String, Map<String, dynamic>>{};
        for (var e in value.entries) {
          if (e.key is! String) {
            continue;
          }
          var v = <String, dynamic>{};
          for (var e2 in e.value.entries) {
            if (e2.key is! String) {
              continue;
            }
            var v2 = e2.value;
            if (v2 is JSInvokable) {
              v2 = JSAutoFreeFunction(v2);
            }
            v[e2.key] = v2;
          }
          newMap[e.key] = v;
        }
        return newMap;
      }
      return null;
    } catch (e) {
      Log.error("ComicSource", "Failed to get dynamic settings: $e");
      return settings;
    }
  }

  ComicSource(
    this.name,
    this.key,
    this.account,
    this.categoryData,
    this.categoryComicsData,
    this.favoriteData,
    this.explorePages,
    this.searchPageData,
    this.settings,
    this.loadComicInfo,
    this.loadComicThumbnail,
    this.loadComicPages,
    this.getImageLoadingConfig,
    this.getThumbnailLoadingConfig,
    this.filePath,
    this.url,
    this.version,
    this.commentsLoader,
    this.sendCommentFunc,
    this.chapterCommentsLoader,
    this.sendChapterCommentFunc,
    this.likeOrUnlikeComic,
    this.voteCommentFunc,
    this.likeCommentFunc,
    this.idMatcher,
    this.translations,
    this.handleClickTagEvent,
    this.onTagSuggestionSelected,
    this.linkHandler,
    this.enableTagsSuggestions,
    this.enableTagsTranslate,
    this.starRatingFunc,
    this.archiveDownloader,
  );
}

class AccountConfig {
  final LoginFunction? login;

  final String? loginWebsite;

  final String? registerWebsite;

  final void Function() logout;

  final List<AccountInfoItem> infoItems;

  final bool Function(String url, String title)? checkLoginStatus;

  final void Function()? onLoginWithWebviewSuccess;

  final List<String>? cookieFields;

  final Future<bool> Function(List<String>)? validateCookies;

  const AccountConfig(
    this.login,
    this.loginWebsite,
    this.registerWebsite,
    this.logout,
    this.checkLoginStatus,
    this.onLoginWithWebviewSuccess,
    this.cookieFields,
    this.validateCookies,
  ) : infoItems = const [];
}

class AccountInfoItem {
  final String title;
  final String Function()? data;
  final void Function()? onTap;
  final WidgetBuilder? builder;

  AccountInfoItem({required this.title, this.data, this.onTap, this.builder});
}

class LoadImageRequest {
  String url;

  Map<String, String> headers;

  LoadImageRequest(this.url, this.headers);
}

class ExplorePageData {
  final String title;

  final ExplorePageType type;

  final ComicListBuilder? loadPage;

  final ComicListBuilderWithNext? loadNext;

  final Future<Res<List<ExplorePagePart>>> Function()? loadMultiPart;

  /// return a `List` contains `List<Comic>` or `ExplorePagePart`
  final Future<Res<List<Object>>> Function(int index)? loadMixed;

  ExplorePageData(
    this.title,
    this.type,
    this.loadPage,
    this.loadNext,
    this.loadMultiPart,
    this.loadMixed,
  );
}

class ExplorePagePart {
  final String title;

  final List<Comic> comics;

  /// If this is not null, the [ExplorePagePart] will show a button to jump to new page.
  ///
  /// Value of this field should match the following format:
  ///   - search:keyword
  ///   - category:categoryName
  ///
  /// End with `@`+`param` if the category has a parameter.
  final PageJumpTarget? viewMore;

  const ExplorePagePart(this.title, this.comics, this.viewMore);
}

enum ExplorePageType {
  multiPageComicList,
  singlePageWithMultiPart,
  mixed,
  override,
}

typedef SearchFunction =
    Future<Res<List<Comic>>> Function(
      String keyword,
      int page,
      List<String> searchOption,
    );

typedef SearchNextFunction =
    Future<Res<List<Comic>>> Function(
      String keyword,
      String? next,
      List<String> searchOption,
    );

class SearchPageData {
  /// If this is not null, the default value of search options will be first element.
  final List<SearchOptions>? searchOptions;

  final SearchFunction? loadPage;

  final SearchNextFunction? loadNext;

  const SearchPageData(this.searchOptions, this.loadPage, this.loadNext);
}

class SearchOptions {
  final LinkedHashMap<String, String> options;

  final String label;

  final String type;

  final String? defaultVal;

  const SearchOptions(this.options, this.label, this.type, this.defaultVal);

  String get defaultValue => defaultVal ?? options.keys.firstOrNull ?? "";
}

typedef CategoryComicsLoader =
    Future<Res<List<Comic>>> Function(
      String category,
      String? param,
      List<String> options,
      int page,
    );

typedef CategoryOptionsLoader =
    Future<Res<List<CategoryComicsOptions>>> Function(
      String category,
      String? param,
    );

class CategoryComicsData {
  /// options
  final List<CategoryComicsOptions>? options;

  final CategoryOptionsLoader? optionsLoader;

  /// [category] is the one clicked by the user on the category page.
  ///
  /// if [BaseCategoryPart.categoryParams] is not null, [param] will be not null.
  ///
  /// [Res.subData] should be maxPage or null if there is no limit.
  final CategoryComicsLoader load;

  final RankingData? rankingData;

  const CategoryComicsData({
    this.options,
    this.optionsLoader,
    required this.load,
    this.rankingData,
  });
}

class RankingData {
  final Map<String, String> options;

  final Future<Res<List<Comic>>> Function(String option, int page)? load;

  final Future<Res<List<Comic>>> Function(String option, String? next)?
  loadWithNext;

  const RankingData(this.options, this.load, this.loadWithNext);
}

class CategoryComicsOptions {
  // The label will not be displayed if it is empty.
  final String label;

  /// Use a [LinkedHashMap] to describe an option list.
  /// key is for loading comics, value is the name displayed on screen.
  /// Default value will be the first of the Map.
  final LinkedHashMap<String, String> options;

  /// If [notShowWhen] contains category's name, the option will not be shown.
  final List<String> notShowWhen;

  final List<String>? showWhen;

  const CategoryComicsOptions(
    this.label,
    this.options,
    this.notShowWhen,
    this.showWhen,
  );
}

class LinkHandler {
  final List<String> domains;

  final String? Function(String url) linkToId;

  const LinkHandler(this.domains, this.linkToId);
}

class ArchiveDownloader {
  final Future<Res<List<ArchiveInfo>>> Function(String cid) getArchives;

  final Future<Res<String>> Function(String cid, String aid) getDownloadUrl;

  const ArchiveDownloader(this.getArchives, this.getDownloadUrl);
}
