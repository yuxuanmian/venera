import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';

export 'follow_update_availability.dart';
export 'follow_update_schedule.dart';

class UpdateProgress {
  final int total;
  final int current;
  final int errors;
  final int updated;
  final FavoriteItemWithUpdateInfo? comic;
  final String? errorMessage;
  final bool isBatchWork;
  final String? currentLabel;
  final bool containsBatchWork;

  UpdateProgress(
    this.total,
    this.current,
    this.errors,
    this.updated, [
    this.comic,
    this.errorMessage,
    this.isBatchWork = false,
    this.currentLabel,
    this.containsBatchWork = false,
  ]);
}

bool get followUpdatesEnabled =>
    appdata.settings['followUpdatesEnabled'] == true;

/// The keys the user selected for follow-up tracking.
///
/// This is **configuration**, not cache state.  Read straight from the settings
/// document, so it is non-empty on a device whose favorite cache has never been
/// populated.
Set<String> followUpdateSelectedSourceKeys() {
  final enabled = appdata.settings['favorites'];
  if (enabled is! List) return const <String>{};
  return enabled.whereType<String>().where((key) => key.isNotEmpty).toSet();
}

/// Why the follow-up gate is (or is not) satisfied.
enum FollowUpdateGateReason {
  /// No enabled, logged-in, scan-capable source is selected at all.
  noSources,

  /// **No** criterion source has a complete favorite cache yet, so there is
  /// nothing that could be shown.
  cacheIncomplete,

  /// At least one criterion source can answer.  Sources still missing a
  /// complete cache are reported through `pendingSourceKeys`, not through this
  /// value: they no longer hold the others closed.
  satisfied,
}

/// The result of evaluating the pre-condition gate (Contract F2).
///
/// The gate is **per source** (F2.3, revised 2026-09-13): [satisfiedSourceKeys]
/// is both "the sources whose cache is complete" and "the sources whose results
/// may be shown".  [pendingSourceKeys] is what the user still has to finish
/// caching; it explains, it does not block.
///
/// [isSatisfied] and [hasSources] remain deliberately separate questions.  An
/// empty criterion set means "there is nothing to track", which is **not** the
/// same as "everything is ready" — an empty set MUST NOT be shown an
/// ever-empty update list (F2.4).
class FollowUpdateGate {
  FollowUpdateGate({
    required Iterable<String> sourceKeys,
    required Iterable<String> satisfiedSourceKeys,
  }) : sourceKeys = Set.unmodifiable(sourceKeys),
       satisfiedSourceKeys = Set.unmodifiable(satisfiedSourceKeys);

  /// The criterion set: `配置 ∩ 已启用 ∩ 已登录 ∩ 具备采集能力`.
  final Set<String> sourceKeys;

  /// Those criterion sources whose own favorite folder carries the completeness
  /// mark written by a finished full-cache run.
  ///
  /// This is also the set whose results may be **shown**: a partial cache would
  /// render a partial answer as if it were the whole one, so a source's entries
  /// stay hidden until its own cache is complete.
  final Set<String> satisfiedSourceKeys;

  bool get hasSources => sourceKeys.isNotEmpty;

  /// Whether the update list may be shown at all.
  ///
  /// **Per source**, not all-or-nothing: one complete source is enough to show
  /// its results.  Requiring every criterion source made a source the user
  /// added but never cached hold follow-up closed **forever** — the more
  /// sources a user has, the less likely follow-up ever works, which is exactly
  /// backwards.
  bool get isSatisfied => satisfiedSourceKeys.isNotEmpty;

  /// Whether every criterion source's cache is complete.
  ///
  /// Kept separate from [isSatisfied]: with an empty criterion set this is
  /// vacuously true while [isSatisfied] is false, and "everything is ready" is
  /// still a different question from "something can be shown".
  bool get isCacheComplete => sourceKeys.every(satisfiedSourceKeys.contains);

  /// The sources still missing a complete cache.
  Set<String> get pendingSourceKeys =>
      sourceKeys.where((key) => !satisfiedSourceKeys.contains(key)).toSet();

  /// Whether some criterion source is still without a complete cache.
  ///
  /// True in the partial case — results are shown, and these sources are the
  /// ones the user has to finish caching to see theirs (F2.7).
  bool get hasPendingSources => pendingSourceKeys.isNotEmpty;

  FollowUpdateGateReason get reason {
    if (!hasSources) return FollowUpdateGateReason.noSources;
    // No source can answer yet: this is the "nothing to show" case, which still
    // gets the full explanation and the cache entry point.
    if (satisfiedSourceKeys.isEmpty) {
      return FollowUpdateGateReason.cacheIncomplete;
    }
    return FollowUpdateGateReason.satisfied;
  }
}

/// Derives the follow-up criterion set and its completeness (Contract F2.1).
///
/// ```
/// 判据集合 = 配置的追更源 ∩ 已启用 ∩ 已登录 ∩ 具备采集能力
/// ```
///
/// **Derived from configuration only — never from the favorite cache.** The
/// legacy enumeration ([getFollowUpdateFolders]) selects on "the cache already
/// holds entries for this folder", so it returns the empty set on a brand-new
/// cache.  Any gate built on it would therefore treat "nothing has been cached
/// yet" as "everything is fully cached", which is precisely backwards.
///
/// Only sources with a usable scan capability are included: only they can
/// produce a judgment row, so an incomplete cache for any other source cannot
/// make the follow-up list wrong.  Including them would let one source's cache
/// failure block follow-up permanently.
///
/// [completeSourceKeys] is the set whose own favorite folder carries the
/// completeness mark written by a finished full-cache run.
///
/// [criterionSourceKeys] lets a caller supply the criterion set instead of
/// deriving it.  A coordinator uses this so the set it scans and the set its
/// gate judges are the same object: if each derived its own copy, a source
/// enabled between the two derivations would make the gate claim readiness for
/// a source the round never covered.
FollowUpdateGate evaluateFollowUpdateGate({
  required Iterable<String> completeSourceKeys,
  Iterable<ComicSource>? sources,
  Set<String>? selectedSourceKeys,
  bool Function(String key)? sourceEnabled,
  Set<String>? criterionSourceKeys,
}) {
  // The scan capability is the only capability that matters here: it is what
  // makes a source able to produce an update at all.
  final keys =
      criterionSourceKeys ??
      followUpdateSourceKeys(
        sources: sources,
        selectedSourceKeys: selectedSourceKeys,
        sourceEnabled: sourceEnabled,
      ).keys;
  final complete = completeSourceKeys.toSet();
  return FollowUpdateGate(
    sourceKeys: keys,
    satisfiedSourceKeys: keys.where(complete.contains),
  );
}

/// Whether a source declares a **source-side unread signal** (Contract F8).
///
/// This is the account-switch cleanup criterion.  It replaces the old
/// `source?.favoriteData?.updateCheck == null` test, which hung on an
/// observation channel that 005 retired and that is itself slated for removal:
/// once that capability went away, sources declaring a source-side unread
/// signal would have **silently lost** their account-switch cleanup — and that
/// signal is account-level, which is precisely why it was cleared.
///
/// The criterion is the **declaration**, read through the normalized comparable
/// label rather than by re-parsing the source, so there is one interpretation of
/// a declaration instead of a second opinion that could disagree with the
/// scanner.
///
/// The retired channel is deliberately **not** accepted as a fallback, even
/// though `manwa` currently declares both.  Contract F8 says the criterion MUST
/// NOT depend on whether the retired channel exists, and the fallback would be
/// wrong on its own terms: a source that declares only the retired channel has
/// no account-level signal at all, so its update flag comes from the comparison
/// and is account **independent** — clearing it on an account switch would
/// discard a legitimate update rather than protect against someone else's.
bool sourceDeclaresUnreadSignal(String sourceKey) {
  final source = ComicSource.find(sourceKey);
  if (source == null) return false;
  final schema = source.scan?.selectedEvidenceSchema;
  if (schema == null) return false;
  return schema.toLowerCase().contains('sourceunread');
}

/// The source keys a follow-up result can actually come from.
///
/// Reading no cache: every input is configuration, so the answer does not
/// change when the cache is emptied or has never been filled.
({Set<String> keys, Map<String, String> skipped}) followUpdateSourceKeys({
  Iterable<ComicSource>? sources,
  Set<String>? selectedSourceKeys,
  bool Function(String key)? sourceEnabled,
}) {
  final selected = selectedSourceKeys ?? followUpdateSelectedSourceKeys();
  final keys = <String>{};
  final skipped = <String, String>{};
  if (selected.isEmpty) return (keys: keys, skipped: skipped);

  final readEnabled = sourceEnabled ?? isSourceEnabled;
  for (final source in sources ?? ComicSource.all()) {
    if (!selected.contains(source.key)) continue;
    // A source the user selected but switched off (or is not logged in to, or
    // that cannot be scanned) contributes no update, so it is not a criterion.
    if (!readEnabled(source.key)) {
      skipped[source.key] = 'disabled';
      continue;
    }
    if (source.account != null && !source.isLogged) {
      skipped[source.key] = 'notLoggedIn';
      continue;
    }
    final capabilities = source.scan;
    if (capabilities == null || !capabilities.isSupported) {
      skipped[source.key] = 'noScanCapability';
      continue;
    }
    keys.add(source.key);
  }
  return (keys: keys, skipped: skipped);
}

/// Legacy cache-derived folder enumeration.
///
/// Retained for callers that need the folders the cache actually holds.  It is
/// **not** a gate criterion: its `countCachedComics(folder) > 0` clause makes it
/// return the empty set on an empty cache (Contract F2.1).  Use
/// [followUpdateSourceKeys] for anything that decides whether results may be
/// shown.
List<NetworkFavoriteFolderRef> getFollowUpdateFolders() {
  final enabled = appdata.settings['favorites'];
  if (enabled is! List) return const [];
  final cache = NetworkFavoriteCacheManager();
  return cache.getAllCachedFolders().where((folder) {
    final source = ComicSource.find(folder.sourceKey);
    return enabled.contains(folder.sourceKey) &&
        isSourceEnabled(folder.sourceKey) &&
        source?.isLogged == true &&
        source?.loadComicInfo != null &&
        cache.countCachedComics(folder) > 0;
  }).toList();
}
