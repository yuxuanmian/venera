import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';

class ComicUpdateResult {
  final bool updated;
  final String? errorMessage;

  ComicUpdateResult(this.updated, this.errorMessage);
}

/// How credible a not-found style error is as evidence of a delisted comic.
///
/// Risk-control rejections (rate limiting, captchas, account bans) must never
/// count as delist evidence; a bare 400 is ambiguous between delist and
/// risk-control and needs the confirmation retry before it counts.
enum NotFoundSignal { strong, weak, none }

/// Responses that indicate the source is rejecting us (risk control, auth,
/// rate limits, server errors, connection issues) rather than the comic being
/// gone. These never count toward the suspected-removed mark.
final _riskControlPattern = RegExp(
  r'风控|验证|captcha|verify|频繁|访问过于频繁|请求过于频繁|rate limit|too many requests|access denied|connection (timeout|reset|terminated)|invalid status code:\s*(401|403|429)|\b[5-9]\d\d\b',
  caseSensitive: false,
);

/// Explicit "this comic is gone" wording, either in the error message or the
/// response body surfaced by a source script.
final _delistBodyPattern = RegExp(
  r'已下架|不存在|not found|no longer available|已删除|该内容已失效',
  caseSensitive: false,
);

/// Extracts the HTTP status from the app's fixed error format
/// ("Invalid Status Code: N. ...", see AppDio.MyLogInterceptor).
final _statusCodePattern = RegExp(
  r'invalid status code:\s*(\d{3})',
  caseSensitive: false,
);

/// Last log time per error message, so a source failing identically for
/// every comic (e.g. a 500 storm) prints one stack trace per 30s instead of
/// one per comic.
final _lastErrorLogAt = <String, DateTime>{};
void _logCheckError(String message, Object e, StackTrace s) {
  final now = DateTime.now();
  final last = _lastErrorLogAt[message];
  if (last == null || now.difference(last) > const Duration(seconds: 30)) {
    _lastErrorLogAt[message] = now;
    Log.error('Check Updates', e, s);
  }
}

NotFoundSignal classifyNotFoundError(String message) {
  if (_riskControlPattern.hasMatch(message)) return NotFoundSignal.none;
  final status = _statusCodePattern.firstMatch(message)?.group(1);
  if (status == '404' || status == '410') return NotFoundSignal.strong;
  if (status == '400') return NotFoundSignal.weak;
  if (_delistBodyPattern.hasMatch(message)) return NotFoundSignal.strong;
  return NotFoundSignal.none;
}

/// Whether [message] looks like a delisted comic at all (strong or weak).
///
/// Note: bare "404"/"400" substrings without the status-code context no longer
/// match, so comic ids or urls containing "404" cannot false-positive.
bool isNotFoundError(String message) =>
    classifyNotFoundError(message) != NotFoundSignal.none;

Duration retryDelayForFailures(int failures) {
  if (failures <= 1) return const Duration(hours: 1);
  if (failures == 2) return const Duration(hours: 6);
  if (failures == 3) return const Duration(hours: 24);
  return const Duration(days: 7);
}

/// Delay between transient (non-delist) retries inside [updateComic]. Tests
/// replace this with zero; production keeps the short backoff.
Duration kTransientRetryDelay = const Duration(seconds: 2);

/// Number of per-source service-class errors (timeouts, 5xx, connection
/// failures, risk control) after which the source is treated as down for
/// delist purposes: no more marks are made this run and every mark already
/// made for the source (including earlier runs) is rolled back. Counts are
/// kept across runs and reset by any successful check. Tests shorten this.
int kServiceErrorDelistThreshold = 5;

/// Window size (requests on the worker path) after which a source with at
/// least one delist-looking hit is probed again through its list endpoints.
/// Tests shorten this.
int kProbeWindowSize = 20;

/// Per-source counts of service-class errors, kept across runs so small
/// batches (a few comics per run) can still trip the delist detector.
final serviceErrorCounts = <String, int>{};

/// Per-source re-probe windows: requests seen since the window opened and
/// delist-looking hits inside it. Kept across runs like [serviceErrorCounts].
final probeWindowRequests = <String, int>{};
final probeWindowHits = <String, int>{};

/// Asks [sourceKey]'s list endpoints whether the site is alive.
///
/// Returns `true` (alive), `false` (dead: error, timeout or empty list) or
/// `null` when the source has no list interface to probe with, in which case
/// the caller must keep its previous behavior (no probing).
Future<bool?> probeSourceAlive(String sourceKey) async {
  final source = ComicSource.find(sourceKey);
  final data = source?.favoriteData;
  if (data == null) return null;
  final hasFolders = data.loadFolders != null;
  final hasComic = data.loadComic != null;
  if (!hasFolders && !hasComic) return null;
  try {
    if (hasFolders) {
      final res = await data.loadFolders!().timeout(
        const Duration(seconds: 10),
      );
      return res.success && res.data.isNotEmpty;
    }
    final res = await data.loadComic!(1).timeout(const Duration(seconds: 10));
    return res.success && res.data.isNotEmpty;
  } catch (_) {
    return false;
  }
}

String? comicUpdateMarker(ComicDetails info) {
  final values = <String>[];
  final updateTime = info.findUpdateTime();
  if (updateTime != null) values.add('time:$updateTime');
  final chapterCount = info.chapters?.length;
  if (chapterCount != null) values.add('chapters:$chapterCount');
  return values.isEmpty ? null : values.join('|');
}

Future<ComicUpdateResult> updateComic(
  FavoriteItemWithUpdateInfo c,
  NetworkFavoriteFolderRef folder, {
  NetworkFavoriteCacheManager? cache,
  bool sourceHealthy = true,
}) async {
  final manager = cache ?? NetworkFavoriteCacheManager();

  Future<ComicUpdateResult> onSuccess(ComicDetails newInfo) async {
    final author = newInfo.subTitle?.trim();
    // Record the check first: its "updated" verdict decides whether the
    // (likely changed) cover URL is committed to the cache rows.
    final updated = manager.recordComicCheckEverywhere(
      c.sourceKey,
      c.id,
      updateTime: newInfo.findUpdateTime(),
      updateMarker: comicUpdateMarker(newInfo),
    );
    manager.updateBasicInfoEverywhere(
      folder,
      c.id,
      title: newInfo.title,
      author: author?.isNotEmpty == true ? author : newInfo.findAuthor(),
      chapterCount: newInfo.chapters?.length,
      // Only confirmed updates refresh the cover URL. Refreshing it on every
      // successful check would invalidate the URL-keyed image cache during
      // each 24h sweep, since many sources sign cover URLs per response.
      cover: updated ? newInfo.cover : null,
    );
    return ComicUpdateResult(updated, null);
  }

  var comicSource = c.type.comicSource;
  if (comicSource == null) {
    manager.markComicRetryLaterEverywhere(c.sourceKey, c.id);
    return ComicUpdateResult(false, "Comic source not found");
  }
  if (comicSource.loadComicInfo == null) {
    manager.markComicRetryLaterEverywhere(c.sourceKey, c.id);
    return ComicUpdateResult(false, 'Comic source does not load details');
  }
  int retries = 3;
  while (true) {
    try {
      final info = await comicSource.loadComicInfo!(c.id).timeout(
        const Duration(seconds: 20),
      );
      return await onSuccess(info.data);
    } catch (e, s) {
      final message = e.toString();
      _logCheckError(message, e, s);
      final signal = classifyNotFoundError(message);
      if (signal != NotFoundSignal.none && sourceHealthy) {
        if (signal == NotFoundSignal.strong) {
          // A confirmed 404/410/delist response on a healthy source marks the
          // comic as suspected removed right away.
          manager.markComicSuspectGoneEverywhere(c.sourceKey, c.id);
          return ComicUpdateResult(false, message);
        }
        // Bare 400: ambiguous between delist and risk control. Record one
        // hit; the count accumulates across rounds (this check plus the
        // retry phase re-check) and three hits confirm the delist. Not
        // confirmed yet: skip this round's remaining retries so the worker
        // is never blocked by a 400 loop; the next round accumulates another
        // hit. A transient (non-400) failure never resets the accumulated
        // count, only a successful check or a suspect mark does.
        final hits = manager.markComicNotFoundHitEverywhere(c.sourceKey, c.id);
        if (hits >= 3) {
          manager.markComicSuspectGoneEverywhere(c.sourceKey, c.id);
          return ComicUpdateResult(false, message);
        }
        final failures = c.checkFailures + 1;
        manager.markComicRetryLaterEverywhere(
          c.sourceKey,
          c.id,
          delay: retryDelayForFailures(failures),
          failures: failures,
        );
        return ComicUpdateResult(false, message);
      }
      await Future.delayed(kTransientRetryDelay);
      retries--;
      if (retries == 0) {
        final failures = c.checkFailures + 1;
        manager.markComicRetryLaterEverywhere(
          c.sourceKey,
          c.id,
          delay: retryDelayForFailures(failures),
          failures: failures,
        );
        return ComicUpdateResult(false, message);
      }
    }
  }
}

class UpdateProgress {
  final int total;
  final int current;
  final int errors;
  final int updated;
  final FavoriteItemWithUpdateInfo? comic;
  final String? errorMessage;

  UpdateProgress(
    this.total,
    this.current,
    this.errors,
    this.updated, [
    this.comic,
    this.errorMessage,
  ]);
}

bool get followUpdatesEnabled =>
    appdata.settings['followUpdatesEnabled'] == true;

List<NetworkFavoriteFolderRef> getFollowUpdateFolders() {
  final enabled = appdata.settings['favorites'];
  if (enabled is! List) return const [];
  final cache = NetworkFavoriteCacheManager();
  return cache.getAllCachedFolders().where((folder) {
    final source = ComicSource.find(folder.sourceKey);
    return enabled.contains(folder.sourceKey) &&
        source?.isLogged == true &&
        source?.loadComicInfo != null &&
        cache.countCachedComics(folder) > 0;
  }).toList();
}

/// Progress of a background follow-up scan run.
class BaselineStatus {
  const BaselineStatus({
    required this.isRunning,
    required this.total,
    required this.completed,
    required this.errors,
    required this.updated,
    this.currentComic,
  });

  final bool isRunning;
  final int total;
  final int completed;
  final int errors;
  final int updated;
  final String? currentComic;
}

/// Selection rule used when checking a remote favorite folder.
enum FollowUpdateMode {
  /// Only comics that have never completed a check.
  missing,

  /// Comics with no check yet plus those checked more than 24 hours ago.
  regular,

  /// Every cached comic, regardless of previous check time.
  force,
}

/// A deduplicated queue item for one follow-up scan run.
class _ScanItem {
  const _ScanItem({
    required this.sourceKey,
    required this.comicId,
    required this.representativeFolderId,
  });

  final String sourceKey;
  final String comicId;

  /// Folder of the row with the earliest last check; used for the fresh
  /// re-read before checking and as the fallback for everywhere writes.
  final String representativeFolderId;
}

/// Builds the deduplicated candidate queue for one scan run.
///
/// The suspect skip, the [mode] window (missing: never checked only;
/// regular: never checked or checked more than 24h ago; force: all) and the
/// retry-after cooldown are all applied in SQL by
/// [NetworkFavoriteCacheManager.getScanCandidates]; this function only
/// deduplicates comics that appear in several folders, keeping the row with
/// the earliest last check (never-checked wins). [skipKeys] excludes
/// already-processed items when resuming an interrupted run.
List<_ScanItem> _buildScanItems(
  NetworkFavoriteCacheManager manager,
  List<NetworkFavoriteFolderRef> folders,
  FollowUpdateMode mode, {
  required bool ignoreRetryAfter,
  Set<String>? skipKeys,
  bool includeSuspect = false,
}) {
  final items = <String, _ScanItem>{};
  final earliestCheck = <String, DateTime?>{};
  for (final c in manager.getScanCandidates(
    folders,
    modeName: mode.name,
    ignoreRetryAfter: ignoreRetryAfter,
    includeSuspect: includeSuspect,
  )) {
    final key = '${c.sourceKey}\u0000${c.comicId}';
    final previous = earliestCheck[key];
    if (previous == null) {
      earliestCheck[key] = c.lastCheckTime;
      items[key] = _ScanItem(
        sourceKey: c.sourceKey,
        comicId: c.comicId,
        representativeFolderId: c.folderId,
      );
    } else {
      // A never-checked row (epoch) beats any checked row.
      final thisEffective =
          c.lastCheckTime ?? DateTime.fromMillisecondsSinceEpoch(0);
      if (thisEffective.isBefore(previous)) {
        earliestCheck[key] = c.lastCheckTime;
        items[key] = _ScanItem(
          sourceKey: c.sourceKey,
          comicId: c.comicId,
          representativeFolderId: c.folderId,
        );
      }
    }
  }
  if (skipKeys != null) {
    items.removeWhere((key, _) => skipKeys.contains(key));
  }
  return items.values.toList();
}

/// Runs a follow-up scan over every qualifying comic of [folders] with a
/// single deduplicated queue.
///
/// The queue is persisted (see [NetworkFavoriteCacheManager.scan_queue]) so an
/// interrupted run (app killed mid-scan) is resumed by the next scan with its
/// stored mode; already-processed items are never re-requested. The stream is
/// always closed and the run always reaches a terminal state (finished or
/// canceled).
Stream<UpdateProgress> scanFollowUpdates(
  List<NetworkFavoriteFolderRef> folders,
  FollowUpdateMode mode, {
  bool Function()? isCanceled,
  bool ignoreRetryAfter = false,
  NetworkFavoriteCacheManager? cache,
  bool includeSuspect = false,
}) {
  var stream = StreamController<UpdateProgress>();
  _runScan(
    folders,
    mode,
    stream,
    isCanceled: isCanceled,
    ignoreRetryAfter: ignoreRetryAfter,
    cache: cache,
    includeSuspect: includeSuspect,
  );
  return stream.stream;
}

Future<void> _runScan(
  List<NetworkFavoriteFolderRef> folders,
  FollowUpdateMode mode,
  StreamController<UpdateProgress> stream, {
  bool Function()? isCanceled,
  bool ignoreRetryAfter = false,
  NetworkFavoriteCacheManager? cache,
  bool includeSuspect = false,
}) async {
  final manager = cache ?? NetworkFavoriteCacheManager();
  var errors = 0;
  var updated = 0;
  var checked = 0;
  var current = 0;
  final healthySources = <String>{};
  final sourceConsecutiveErrors = <String, int>{};
  final sourceConfirmedHits = <String, int>{};
  final bulkDelistSources = <String>{};
  // Sources that tripped the consecutive-error threshold; their requests are
  // rate-limited to half speed. Unlike the old global fallback, one bad
  // source no longer slows down every healthy source.
  final sourceSlowMode = <String>{};
  final markedThisRun = <({String sourceKey, String comicId})>[];
  final notFoundRetries =
      <({FavoriteItemWithUpdateInfo comic, NetworkFavoriteFolderRef folder})>[];
  // In-flight source probes, deduplicating concurrent workers that hit the
  // same source in the same frame.
  final probingSources = <String, Future<bool?>>{};

  // A source is healthy while it has at least one successful check in this
  // run, has not tripped the bulk-delist detector and has no accumulated
  // service-class errors (timeouts/5xx are evidence the source is flaky, so
  // delist-looking responses are not trusted).
  bool sourceHealthy(String sourceKey) =>
      healthySources.contains(sourceKey) &&
      !bulkDelistSources.contains(sourceKey) &&
      (serviceErrorCounts[sourceKey] ?? 0) == 0;

  // Sources judged down from failure evidence (service-error accumulation or
  // a failed list probe). Unlike the ordinary consecutive-error trip, the
  // verdict is not undone by a later success in the same run: a single
  // success right after a dead probe must not re-trust the delist-looking
  // responses that preceded it. The next run re-evaluates from scratch.
  final hardDelistedSources = <String>{};

  // Judges the source as down for delist purposes: no more marks are made
  // this run and every mark already made for it (including earlier runs) is
  // rolled back, so delist-looking responses it served while failing cannot
  // linger. Idempotent; the warning only fires on the first trip.
  void delistSource(String sourceKey, {required String reason}) {
    final newlyTripped = bulkDelistSources.add(sourceKey);
    hardDelistedSources.add(sourceKey);
    manager.clearComicSuspectGoneForSourceEverywhere(sourceKey);
    if (newlyTripped) {
      Log.warning(
        'Follow updates',
        'Source $sourceKey delist-tripped: $reason',
      );
    }
  }

  late ScanRunInfo run;
  try {
    // Resume an interrupted (crash) run with its stored mode and cooldown
    // policy; otherwise start a fresh run.
    final previousRun = manager.getCurrentScanRun();
    final List<_ScanItem> items;
    if (previousRun != null && previousRun.status == 'running') {
      final storedMode =
          FollowUpdateMode.values.asNameMap()[previousRun.mode] ?? mode;
      items = _buildScanItems(
        manager,
        folders,
        storedMode,
        ignoreRetryAfter: previousRun.ignoreRetryAfter,
        skipKeys: manager.getDoneScanItems(previousRun.runId),
        includeSuspect: includeSuspect,
      );
      run = previousRun;
      // The rebuilt queue may contain comics cached after the original run
      // was persisted; they have no scan_queue rows yet. Backfill them so a
      // second interruption excludes them via the done-set like every other
      // item (otherwise force-mode resumes re-request them every time).
      final queued = manager.getScanRunKeys(previousRun.runId);
      final missing = [
        for (final item in items)
          if (!queued.contains('${item.sourceKey}\u0000${item.comicId}'))
            (item.sourceKey, item.comicId),
      ];
      manager.addScanRunItems(previousRun.runId, missing);
    } else {
      items = _buildScanItems(
        manager,
        folders,
        mode,
        ignoreRetryAfter: ignoreRetryAfter,
        includeSuspect: includeSuspect,
      );
      run = manager.createScanRun(
        mode: mode.name,
        ignoreRetryAfter: ignoreRetryAfter,
        total: items.length,
        items: [for (final item in items) (item.sourceKey, item.comicId)],
      );
    }
    final total = items.length;
    // The final total is emitted once, before any work starts.
    stream.add(UpdateProgress(total, 0, 0, 0));

    final threads =
        ((appdata.settings['followUpdateThreads'] as num?)?.toInt().clamp(
                  1,
                  16,
                ) ??
                5)
            .toInt();
    final batchDelay =
        (appdata.settings['followUpdateBatchDelay'] as num?)?.toDouble() ?? 5;
    final spacingMs = (batchDelay / 5 * 1000).round();
    var nextAllowed = DateTime.now();
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        if (isCanceled?.call() == true) return;
        final i = nextIndex++;
        if (i >= items.length) return;
        final item = items[i];
        final folder = NetworkFavoriteFolderRef(
          sourceKey: item.sourceKey,
          folderId: item.representativeFolderId,
        );
        // Rate limit: keep the old effective pace (batchDelay seconds per 5
        // comics), doubled for sources in slow mode. Approximate shared
        // timestamp; a rare same-frame double fire is acceptable.
        final now = DateTime.now();
        final effectiveSpacing =
            spacingMs * (sourceSlowMode.contains(item.sourceKey) ? 2 : 1);
        if (effectiveSpacing > 0) {
          final wait = nextAllowed.difference(now);
          if (wait > Duration.zero) {
            await Future.delayed(wait);
          }
          nextAllowed = DateTime.now().add(
            Duration(milliseconds: effectiveSpacing),
          );
        }
        // Re-read the row so the 24h hit window and retry state are current.
        final fresh = manager.getComicUpdateInfo(
          item.sourceKey,
          item.comicId,
          item.representativeFolderId,
        );
        if (fresh == null) {
          manager.markScanItemDone(
            run.runId,
            item.sourceKey,
            item.comicId,
            result: 'skipped',
          );
          continue;
        }
        // Re-probe window counting (worker path only; the retry phase never
        // touches the window). A full window with at least one delist-looking
        // hit asks the list endpoints again: if the site has gone down since
        // the first probe, everything marked in between is rolled back.
        if (probeWindowRequests.containsKey(item.sourceKey)) {
          probeWindowRequests[item.sourceKey] =
              probeWindowRequests[item.sourceKey]! + 1;
          if (probeWindowHits[item.sourceKey]! > 0 &&
              probeWindowRequests[item.sourceKey]! >= kProbeWindowSize) {
            final probe = probingSources.putIfAbsent(
              item.sourceKey,
              () => probeSourceAlive(item.sourceKey),
            );
            final alive = await probe;
            probingSources.remove(item.sourceKey);
            if (alive == false) {
              delistSource(item.sourceKey, reason: 're-probe failed');
            } else {
              probeWindowRequests.remove(item.sourceKey);
              probeWindowHits.remove(item.sourceKey);
            }
          }
        }
        final ComicUpdateResult result;
        try {
          result = await updateComic(
            fresh,
            folder,
            cache: manager,
            sourceHealthy: sourceHealthy(item.sourceKey),
          );
        } catch (e, s) {
          // Defensive: an unexpected exception must never kill the worker or
          // leave the item stuck. Back off by the accumulated failure count
          // like every other failure path.
          Log.error('Follow updates item', e, s);
          manager.markComicRetryLaterEverywhere(
            item.sourceKey,
            item.comicId,
            failures: fresh.checkFailures + 1,
          );
          manager.markScanItemDone(
            run.runId,
            item.sourceKey,
            item.comicId,
            result: 'retry_later',
            error: e.toString(),
          );
          current++;
          errors++;
          stream.add(
            UpdateProgress(
              total,
              current,
              errors,
              updated,
              fresh,
              e.toString(),
            ),
          );
          continue;
        }
        current++;
        if (result.errorMessage != null) {
          final signal = classifyNotFoundError(result.errorMessage!);
          if (signal != NotFoundSignal.none) {
            notFoundRetries.add((comic: fresh, folder: folder));
          }
          final sourceKey = item.sourceKey;
          sourceConsecutiveErrors[sourceKey] =
              (sourceConsecutiveErrors[sourceKey] ?? 0) + 1;
          if ((sourceConsecutiveErrors[sourceKey] ?? 0) >= 10) {
            bulkDelistSources.add(sourceKey);
            sourceSlowMode.add(sourceKey);
          }
          // Service-class errors (timeouts, 5xx, risk control) are evidence
          // the source itself is failing. They accumulate across runs so
          // small batches can still trip the detector, and any successful
          // check resets them; a delist-looking response is never both.
          if (signal == NotFoundSignal.none) {
            serviceErrorCounts[sourceKey] =
                (serviceErrorCounts[sourceKey] ?? 0) + 1;
            if ((serviceErrorCounts[sourceKey] ?? 0) >=
                kServiceErrorDelistThreshold) {
              delistSource(
                sourceKey,
                reason: '${serviceErrorCounts[sourceKey]} service errors',
              );
            }
          }
          // A confirmed delist hit (strong 404 or a 3x400 session). Several
          // in one run strongly suggest the source itself is rejecting
          // requests (risk control or a full-site outage) rather than
          // individual delists: stop marking for the source and roll back
          // everything this run already marked for it. Rolled-back comics
          // are re-checked by the next run and re-marked only if they are
          // really gone.
          if (signal != NotFoundSignal.none &&
              manager.isComicSuspectGone(sourceKey, item.comicId)) {
            sourceConfirmedHits[sourceKey] =
                (sourceConfirmedHits[sourceKey] ?? 0) + 1;
            markedThisRun.add((sourceKey: sourceKey, comicId: item.comicId));
            if ((sourceConfirmedHits[sourceKey] ?? 0) >= 3) {
              bulkDelistSources.add(sourceKey);
              for (final marked in markedThisRun) {
                if (marked.sourceKey == sourceKey) {
                  manager.clearComicSuspectGoneEverywhere(
                    marked.sourceKey,
                    marked.comicId,
                  );
                }
              }
            }
          }
          // First delist-looking hit of the run: ask the list endpoints
          // whether the site is alive before trusting further hits. A dead
          // answer trips the detector right away (the mark of this comic is
          // rolled back together with all others); an alive answer opens the
          // periodic re-probe window. Sources without a list interface
          // (probe returns null) keep their previous behavior.
          if (signal != NotFoundSignal.none &&
              !bulkDelistSources.contains(sourceKey)) {
            if (!probeWindowRequests.containsKey(sourceKey)) {
              final probe = probingSources.putIfAbsent(
                sourceKey,
                () => probeSourceAlive(sourceKey),
              );
              final alive = await probe;
              probingSources.remove(sourceKey);
              if (alive == false) {
                delistSource(sourceKey, reason: 'probe failed');
              } else if (alive == true) {
                probeWindowRequests[sourceKey] = 0;
                probeWindowHits[sourceKey] = 0;
              }
            } else {
              probeWindowHits[sourceKey] = probeWindowHits[sourceKey]! + 1;
            }
          }
          errors++;
          manager.markScanItemDone(
            run.runId,
            item.sourceKey,
            item.comicId,
            result: signal == NotFoundSignal.none ? 'retry_later' : 'not_found',
            error: result.errorMessage,
          );
        } else {
          healthySources.add(item.sourceKey);
          sourceConsecutiveErrors[item.sourceKey] = 0;
          sourceConfirmedHits[item.sourceKey] = 0;
          serviceErrorCounts[item.sourceKey] = 0;
          sourceSlowMode.remove(item.sourceKey);
          if (!hardDelistedSources.contains(item.sourceKey)) {
            bulkDelistSources.remove(item.sourceKey);
          }
          checked++;
          if (result.updated) updated++;
          manager.markScanItemDone(
            run.runId,
            item.sourceKey,
            item.comicId,
            result: 'ok',
          );
        }
        stream.add(
          UpdateProgress(
            total,
            current,
            errors,
            updated,
            fresh,
            result.errorMessage,
          ),
        );
      }
    }

    final workerFutures = <Future<void>>[];
    for (var i = 0; i < threads; i++) {
      workerFutures.add(worker());
    }
    await Future.wait(workerFutures);

    // Second opinion for not-found results: re-check each once after the
    // queue drains. A success clears the accumulated hits (recordComicCheck
    // resets the counters); another not-found stays inside the 24h window and
    // cannot accumulate twice on the same day. Re-checks share the main
    // workers' rate limiter and run on a few concurrent workers instead of
    // serially.
    if (notFoundRetries.isNotEmpty && isCanceled?.call() != true) {
      final retryThreads = math.min(3, threads);
      var retryIndex = 0;
      Future<void> retryWorker() async {
        while (true) {
          if (isCanceled?.call() == true) return;
          final i = retryIndex++;
          if (i >= notFoundRetries.length) return;
          final retry = notFoundRetries[i];
          if (manager.isComicSuspectGone(retry.comic.sourceKey, retry.comic.id)) {
            continue;
          }
          // The source tripped the bulk-delist detector; re-checking only
          // repeats the same rejected requests.
          if (bulkDelistSources.contains(retry.comic.sourceKey)) continue;
          final fresh = manager.getComicUpdateInfo(
            retry.comic.sourceKey,
            retry.comic.id,
            retry.folder.folderId,
          );
          if (fresh == null) continue;
          final now = DateTime.now();
          if (spacingMs > 0) {
            final wait = nextAllowed.difference(now);
            if (wait > Duration.zero) await Future.delayed(wait);
            nextAllowed = DateTime.now().add(Duration(milliseconds: spacingMs));
          }
          final result = await updateComic(
            fresh,
            retry.folder,
            cache: manager,
            sourceHealthy: sourceHealthy(retry.comic.sourceKey),
          );
          if (result.errorMessage == null) {
            checked++;
            if (result.updated) updated++;
            if (errors > 0) errors--;
          }
        }
      }
      await Future.wait([
        for (var i = 0; i < retryThreads; i++) retryWorker(),
      ]);
    }

    stream.add(UpdateProgress(total, current, errors, updated));
  } finally {
    try {
      // The run always reaches a terminal state; a canceled run is not
      // resumed later (the normal filters re-select its pending items).
      manager.updateScanRunStatus(
        run.runId,
        isCanceled?.call() == true ? 'canceled' : 'finished',
      );
    } finally {
      if (checked > 0) manager.notifyCacheChanged();
      stream.close();
    }
  }
}

Future<bool> recheckFavoriteComic(String sourceKey, String comicId) async {
  final manager = NetworkFavoriteCacheManager();
  final folderIds = manager.getKnownFolderIds(sourceKey, comicId);
  var succeeded = false;
  for (final folderId in folderIds) {
    final folder = NetworkFavoriteFolderRef(
      sourceKey: sourceKey,
      folderId: folderId,
    );
    for (final item in manager.getComicsWithUpdatesInfo(folder)) {
      if (item.id == comicId) {
        final result = await updateComic(item, folder, cache: manager);
        if (result.errorMessage == null) succeeded = true;
        break;
      }
    }
  }
  manager.notifyCacheChanged();
  return succeeded;
}

Future<String> getUpdatedComicsAsJsonInFolders(
  Iterable<NetworkFavoriteFolderRef> folders,
) async {
  var updatedComics = NetworkFavoriteCacheManager().getUpdatedComicsInFolders(
    folders,
  );
  var jsonList = updatedComics
      .map(
        (c) => {
          'id': c.id,
          'name': c.name,
          'coverUrl': c.coverPath,
          'author': c.author,
          'chapterCount': c.chapterCount,
          'type': c.sourceKey,
          'updateTime': c.updateTime,
          'tags': c.tags,
        },
      )
      .toList();
  return jsonEncode(jsonList);
}
