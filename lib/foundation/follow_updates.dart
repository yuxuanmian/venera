import 'dart:async';
import 'dart:convert';
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

/// Spacing of the confirmation retries for a bare 400 response. Tests replace
/// this with zero delays; production keeps the increasing gaps so a short
/// risk-control window has time to clear before the hit is confirmed.
List<Duration> kNotFoundConfirmationDelays = const [
  Duration(seconds: 3),
  Duration(seconds: 10),
  Duration(seconds: 30),
];

/// Delay between transient (non-delist) retries inside [updateComic]. Tests
/// replace this with zero; production keeps the short backoff.
Duration kTransientRetryDelay = const Duration(seconds: 2);

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
    manager.updateBasicInfoEverywhere(
      folder,
      c.id,
      title: newInfo.title,
      author: author?.isNotEmpty == true ? author : newInfo.findAuthor(),
      chapterCount: newInfo.chapters?.length,
    );
    final updated = manager.recordComicCheckEverywhere(
      c.sourceKey,
      c.id,
      updateTime: newInfo.findUpdateTime(),
      updateMarker: comicUpdateMarker(newInfo),
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
      Log.error("Check Updates", e, s);
      final message = e.toString();
      final signal = classifyNotFoundError(message);
      if (signal != NotFoundSignal.none && sourceHealthy) {
        if (signal == NotFoundSignal.strong) {
          // A confirmed 404/410/delist response on a healthy source marks the
          // comic as suspected removed right away.
          manager.markComicSuspectGoneEverywhere(c.sourceKey, c.id);
          return ComicUpdateResult(false, message);
        }
        // Bare 400: ambiguous between delist and risk control. Confirm with a
        // bounded retry session (3s/10s/30s, inline in this worker); only
        // three consecutive 400s count as a confirmed delist and mark the
        // comic. Any non-400 response during the session is treated as a
        // transient failure.
        var all400 = true;
        for (final delay in kNotFoundConfirmationDelays) {
          await Future.delayed(delay);
          try {
            final retryInfo = await comicSource.loadComicInfo!(c.id).timeout(
              const Duration(seconds: 20),
            );
            return await onSuccess(retryInfo.data);
          } catch (e2, s2) {
            Log.error("Check Updates 400 confirmation", e2, s2);
            final signal2 = classifyNotFoundError(e2.toString());
            if (signal2 == NotFoundSignal.strong) {
              manager.markComicSuspectGoneEverywhere(c.sourceKey, c.id);
              return ComicUpdateResult(false, e2.toString());
            }
            if (signal2 != NotFoundSignal.weak) {
              all400 = false;
              break;
            }
          }
        }
        if (all400) {
          manager.markComicSuspectGoneEverywhere(c.sourceKey, c.id);
          return ComicUpdateResult(false, message);
        }
        // Fall through to the transient retry path.
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

/// Progress of a background baseline-establishing run.
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
/// Skips suspect-gone comics, applies [mode] (missing: never checked only;
/// regular: never checked or checked more than 24h ago; force: all) and the
/// retry-after cooldown. Comics appearing in several folders are deduplicated
/// by keeping the row with the earliest last check (never-checked wins).
/// [skipKeys] excludes already-processed items when resuming an interrupted
/// run.
List<_ScanItem> _buildScanItems(
  NetworkFavoriteCacheManager manager,
  List<NetworkFavoriteFolderRef> folders,
  FollowUpdateMode mode, {
  required bool ignoreRetryAfter,
  Set<String>? skipKeys,
}) {
  final items = <String, _ScanItem>{};
  final earliestCheck = <String, DateTime?>{};
  for (final folder in folders) {
    for (final comic in manager.getComicsWithUpdatesInfo(folder)) {
      if (comic.isSuspectGone) continue;
      final lastCheckTime = comic.lastCheckTime;
      if (mode == FollowUpdateMode.missing) {
        if (lastCheckTime != null) continue;
      } else if (mode == FollowUpdateMode.regular) {
        if (lastCheckTime != null &&
            DateTime.now().difference(lastCheckTime).inDays < 1) {
          continue;
        }
      }
      final retryAfter = comic.retryAfter;
      if (!ignoreRetryAfter &&
          retryAfter != null &&
          retryAfter.isAfter(DateTime.now())) {
        continue;
      }
      final key = '${comic.sourceKey}\u0000${comic.id}';
      final previous = earliestCheck[key];
      if (previous == null) {
        earliestCheck[key] = lastCheckTime;
        items[key] = _ScanItem(
          sourceKey: comic.sourceKey,
          comicId: comic.id,
          representativeFolderId: folder.folderId,
        );
      } else {
        // A never-checked row (epoch) beats any checked row.
        final thisEffective = lastCheckTime ??
            DateTime.fromMillisecondsSinceEpoch(0);
        if (thisEffective.isBefore(previous)) {
          earliestCheck[key] = lastCheckTime;
          items[key] = _ScanItem(
            sourceKey: comic.sourceKey,
            comicId: comic.id,
            representativeFolderId: folder.folderId,
          );
        }
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
}) {
  var stream = StreamController<UpdateProgress>();
  _runScan(
    folders,
    mode,
    stream,
    isCanceled: isCanceled,
    ignoreRetryAfter: ignoreRetryAfter,
    cache: cache,
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
}) async {
  final manager = cache ?? NetworkFavoriteCacheManager();
  var errors = 0;
  var updated = 0;
  var checked = 0;
  var current = 0;
  var consecutiveErrors = 0;
  var usingFallback = false;
  final healthySources = <String>{};
  final sourceConsecutiveErrors = <String, int>{};
  final sourceConfirmedHits = <String, int>{};
  final bulkDelistSources = <String>{};
  final markedThisRun = <({String sourceKey, String comicId})>[];
  final notFoundRetries =
      <({FavoriteItemWithUpdateInfo comic, NetworkFavoriteFolderRef folder})>[];

  // A source is healthy while it has at least one successful check in this
  // run and has not tripped the bulk-delist detector (see below).
  bool sourceHealthy(String sourceKey) =>
      healthySources.contains(sourceKey) &&
      !bulkDelistSources.contains(sourceKey);

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
      );
      run = previousRun;
    } else {
      items = _buildScanItems(
        manager,
        folders,
        mode,
        ignoreRetryAfter: ignoreRetryAfter,
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

    final threads = ((appdata.settings['followUpdateThreads'] as num?)
                ?.toInt()
                .clamp(1, 16) ??
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
        // comics), doubled while in fallback mode. Approximate shared
        // timestamp; a rare same-frame double fire is acceptable.
        final now = DateTime.now();
        final effectiveSpacing = spacingMs * (usingFallback ? 2 : 1);
        if (effectiveSpacing > 0) {
          final wait = nextAllowed.difference(now);
          if (wait > Duration.zero) {
            await Future.delayed(wait);
          }
          nextAllowed = DateTime.now()
              .add(Duration(milliseconds: effectiveSpacing));
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
          // leave the item stuck.
          Log.error('Follow updates item', e, s);
          manager.markComicRetryLaterEverywhere(item.sourceKey, item.comicId);
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
          consecutiveErrors++;
          if (consecutiveErrors >= 10) usingFallback = true;
          final signal = classifyNotFoundError(result.errorMessage!);
          if (signal != NotFoundSignal.none) {
            notFoundRetries.add((comic: fresh, folder: folder));
          }
          final sourceKey = item.sourceKey;
          sourceConsecutiveErrors[sourceKey] =
              (sourceConsecutiveErrors[sourceKey] ?? 0) + 1;
          if ((sourceConsecutiveErrors[sourceKey] ?? 0) >= 10) {
            bulkDelistSources.add(sourceKey);
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
          errors++;
          manager.markScanItemDone(
            run.runId,
            item.sourceKey,
            item.comicId,
            result: signal == NotFoundSignal.none ? 'retry_later' : 'not_found',
            error: result.errorMessage,
          );
        } else {
          consecutiveErrors = 0;
          healthySources.add(item.sourceKey);
          sourceConsecutiveErrors[item.sourceKey] = 0;
          sourceConfirmedHits[item.sourceKey] = 0;
          bulkDelistSources.remove(item.sourceKey);
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
    // cannot accumulate twice on the same day.
    if (notFoundRetries.isNotEmpty && isCanceled?.call() != true) {
      for (final retry in notFoundRetries) {
        if (isCanceled?.call() == true) break;
        if (manager.isComicSuspectGone(
          retry.comic.sourceKey,
          retry.comic.id,
        )) {
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
          consecutiveErrors = 0;
        }
      }
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
