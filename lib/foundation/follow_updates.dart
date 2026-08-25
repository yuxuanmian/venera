import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_update_schedule.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';

export 'follow_update_schedule.dart';
export 'follow_update_marker.dart';

abstract interface class ScanCancellationToken {
  bool get isCanceled;

  bool get isCurrent;

  bool get canCommit => !isCanceled && isCurrent;
}

class _CallbackScanCancellationToken implements ScanCancellationToken {
  _CallbackScanCancellationToken(this._callback);

  final bool Function()? _callback;

  @override
  bool get isCanceled => _callback?.call() == true;

  @override
  bool get isCurrent => true;

  @override
  bool get canCommit => !isCanceled && isCurrent;
}

const int _defaultFollowUpdateThreads = 8;
const int _maxConcurrentPerSource = 5;
const int _followUpdateBatchWidth = 8;

Future<void> _defaultFollowUpdateDelay(Duration duration) =>
    Future<void>.delayed(duration);

/// Converts the user-facing batch delay into the minimum interval between
/// starts for one source. This is intentionally independent of the selected
/// global worker count so increasing global concurrency cannot create a burst
/// against a single source.
Duration calculateFollowUpdateSourceInterval(
  double batchDelay, {
  bool slowMode = false,
}) {
  final safeBatchDelay = batchDelay.isFinite ? math.max(0, batchDelay) : 0.0;
  final baseMs = (safeBatchDelay / _followUpdateBatchWidth * 1000).round();
  final milliseconds = baseMs * (slowMode ? 2 : 1);
  return Duration(milliseconds: math.max(0, milliseconds));
}

class _SourceLimiterState {
  var inFlight = 0;
  final permitWaiters = Queue<_SourcePermitWaiter>();
  Future<void> startGate = Future<void>.value();
  DateTime? lastStart;
}

class _SourcePermitWaiter {
  final completer = Completer<void>();
  var canceled = false;
  var granted = false;
}

/// Limits requests for each source without serializing their full network
/// actions. The permit covers the complete action lifetime while the start
/// gate only protects reservation of the next start time.
class _SourceRequestLimiter {
  _SourceRequestLimiter({
    required this.maxConcurrentPerSource,
    DateTime Function() clock = DateTime.now,
    Future<void> Function(Duration) delay = _defaultFollowUpdateDelay,
  }) : _clock = clock,
       _delay = delay,
       assert(maxConcurrentPerSource > 0);

  final int maxConcurrentPerSource;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;
  final _states = <String, _SourceLimiterState>{};

  Future<T?> run<T>(
    String sourceKey, {
    required Duration Function() interval,
    required ScanCancellationToken token,
    required Future<T> Function() action,
    void Function(T result)? onCompleted,
  }) async {
    if (!token.canCommit) return null;
    final state = _states.putIfAbsent(sourceKey, _SourceLimiterState.new);
    final acquired = await _acquirePermit(state, token);
    if (!acquired) return null;

    try {
      // A token can be invalidated while a FIFO waiter is being granted. Do
      // not enqueue a canceled request behind the source start gate; release
      // the transferred permit through this finally block immediately.
      if (!token.canCommit) return null;
      final reserved = await _reserveStart(state, interval, token);
      if (!reserved) return null;

      final result = await action();
      if (onCompleted != null && token.canCommit) onCompleted(result);
      return result;
    } finally {
      _releasePermit(state);
    }
  }

  Future<bool> _acquirePermit(
    _SourceLimiterState state,
    ScanCancellationToken token,
  ) async {
    if (state.inFlight < maxConcurrentPerSource) {
      state.inFlight++;
      return true;
    }

    final waiter = _SourcePermitWaiter();
    state.permitWaiters.addLast(waiter);
    while (true) {
      if (!token.canCommit && !waiter.granted) {
        waiter.canceled = true;
        state.permitWaiters.remove(waiter);
        return false;
      }
      if (waiter.granted) return true;
      // The token has no cancellation Future, so poll while queued. This
      // prevents a canceled scan from retaining a permit waiter indefinitely
      // when an in-flight request is slow.
      await Future.any<void>([
        waiter.completer.future,
        Future<void>.delayed(const Duration(milliseconds: 20)),
      ]);
    }
  }

  Future<bool> _reserveStart(
    _SourceLimiterState state,
    Duration Function() interval,
    ScanCancellationToken token,
  ) async {
    final releaseGate = Completer<void>();
    final previous = state.startGate;
    state.startGate = releaseGate.future;
    try {
      await previous;
      if (!token.canCommit) return false;
      final lastStart = state.lastStart;
      if (lastStart != null) {
        final spacing = interval();
        final nextAllowed = lastStart.add(
          spacing.isNegative ? Duration.zero : spacing,
        );
        final wait = nextAllowed.difference(_clock());
        if (wait > Duration.zero) await _delay(wait);
      }
      if (!token.canCommit) return false;
      final start = _clock();
      state.lastStart = start;
      return true;
    } finally {
      releaseGate.complete();
    }
  }

  void _releasePermit(_SourceLimiterState state) {
    while (state.permitWaiters.isNotEmpty) {
      final waiter = state.permitWaiters.removeFirst();
      if (waiter.canceled || waiter.completer.isCompleted) continue;
      waiter.granted = true;
      // Transfer the existing permit directly to the FIFO waiter.
      waiter.completer.complete();
      return;
    }
    state.inFlight--;
  }
}

/// Public test-facing facade for exercising the same limiter used by scans
/// with a deterministic clock and delay scheduler.
class FollowUpdateRequestLimiter {
  FollowUpdateRequestLimiter({
    required int maxConcurrentPerSource,
    DateTime Function() clock = DateTime.now,
    Future<void> Function(Duration) delay = _defaultFollowUpdateDelay,
  }) : _limiter = _SourceRequestLimiter(
         maxConcurrentPerSource: maxConcurrentPerSource,
         clock: clock,
         delay: delay,
       );

  final _SourceRequestLimiter _limiter;

  Future<T?> run<T>(
    String sourceKey, {
    required Duration Function() interval,
    required ScanCancellationToken token,
    required Future<T> Function() action,
    void Function(T result)? onCompleted,
  }) => _limiter.run<T>(
    sourceKey,
    interval: interval,
    token: token,
    action: action,
    onCompleted: onCompleted,
  );
}

class ComicUpdateResult {
  final bool updated;
  final String? errorMessage;
  final bool canceled;

  ComicUpdateResult(this.updated, this.errorMessage, {this.canceled = false});
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
/// Returns `true` (alive), `false` (dead: error or timeout) or
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
      // An empty but successful list is still a successful request. It may
      // simply mean that this account has no folders/comics on the source.
      return res.success;
    }
    final res = await data.loadComic!(1).timeout(const Duration(seconds: 10));
    return res.success;
  } catch (_) {
    return false;
  }
}

String? comicUpdateMarker(ComicDetails info) {
  final updateTime = info.findUpdateTime();
  final chapterCount = info.chapters?.length;
  final recent = _recentChapterFingerprint(info.chapters);
  if (updateTime == null && chapterCount == null && recent == null) return null;
  return 'v2|time:${_normalizeMarkerTime(updateTime)}|'
      'chapters:${chapterCount ?? ''}|recent:${recent ?? ''}';
}

String _normalizeMarkerTime(String? value) {
  if (value == null || value.trim().isEmpty) return '';
  final parts = value.trim().split('-');
  if (parts.length != 3) return value.trim();
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return value.trim();
  return '$year-${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';
}

/// Extracts the source activity time for scheduling without changing the
/// marker/display-date semantics. Update metadata wins; malformed update
/// metadata falls back to upload metadata.
DateTime? comicSourceActivityAt(ComicDetails info, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final updateValues = <String?>[info.updateTime];
  const updateNamespaces = {'更新', '最後更新', '最后更新', 'update', 'last update'};
  for (final entry in info.tags.entries) {
    if (updateNamespaces.contains(entry.key.toLowerCase())) {
      updateValues.addAll(entry.value);
    }
  }
  for (final value in updateValues) {
    final parsed = parseFollowUpdateActivityTime(value, now: current);
    if (parsed != null) return parsed;
  }

  final uploadValues = <String?>[info.uploadTime];
  const uploadNamespaces = {'上传', '上架', 'upload', 'uploaded'};
  for (final entry in info.tags.entries) {
    if (uploadNamespaces.contains(entry.key.toLowerCase())) {
      uploadValues.addAll(entry.value);
    }
  }
  for (final value in uploadValues) {
    final parsed = parseFollowUpdateActivityTime(value, now: current);
    if (parsed != null) return parsed;
  }
  return null;
}

String? _recentChapterFingerprint(ComicChapters? chapters) {
  if (chapters == null) return null;
  final entries = <Map<String, String>>[];
  if (chapters.isGrouped) {
    for (final group in chapters.groups) {
      for (final entry in chapters.getGroup(group).entries) {
        entries.add({'group': group, 'id': entry.key, 'title': entry.value});
      }
    }
  } else {
    for (final entry in chapters.allChapters.entries) {
      entries.add({'group': '', 'id': entry.key, 'title': entry.value});
    }
  }
  final recent = entries.take(10).toList(growable: false);
  final payload = jsonEncode(recent);
  return sha256.convert(utf8.encode(payload)).toString();
}

Future<ComicUpdateResult> updateComic(
  FavoriteItemWithUpdateInfo c,
  NetworkFavoriteFolderRef folder, {
  NetworkFavoriteCacheManager? cache,
  bool sourceHealthy = true,
  ScanCancellationToken? cancellationToken,
  DateTime Function()? clock,
}) async {
  final manager = cache ?? NetworkFavoriteCacheManager();
  DateTime currentTime() => clock?.call() ?? DateTime.now();
  bool canCommit() => cancellationToken?.canCommit ?? true;
  ComicUpdateResult canceled() =>
      ComicUpdateResult(false, null, canceled: true);

  Future<ComicUpdateResult> onSuccess(ComicDetails newInfo) async {
    if (!canCommit()) return canceled();
    final completedAt = currentTime();
    final author = newInfo.subTitle?.trim();
    // Commit the check state and every favorite snapshot together. The
    // (likely changed) cover URL is only included when the committed marker
    // proves this is an actual update.
    final updated = manager.applySuccessfulComicCheck(
      folder,
      c.id,
      updateTime: newInfo.findUpdateTime(),
      sourceActivityAt: comicSourceActivityAt(newInfo, now: completedAt),
      completedAt: completedAt,
      updateMarker: comicUpdateMarker(newInfo),
      title: newInfo.title,
      author: author?.isNotEmpty == true ? author : newInfo.findAuthor(),
      chapterCount: newInfo.chapters?.length,
      // The transaction only applies this cover when the marker confirms an
      // update; refreshing it on every successful check would invalidate the
      // URL-keyed image cache during each scheduled sweep.
      cover: newInfo.cover,
    );
    if (!canCommit()) return canceled();
    return ComicUpdateResult(updated, null);
  }

  var comicSource = c.type.comicSource;
  if (comicSource == null) {
    if (!canCommit()) return canceled();
    manager.markComicRetryLaterEverywhere(
      c.sourceKey,
      c.id,
      now: currentTime(),
    );
    return ComicUpdateResult(false, "Comic source not found");
  }
  if (comicSource.favoriteData?.updateCheck != null) {
    // List-strategy sources are checked by a complete favorite snapshot. Do
    // not fall back to a detail request for an individual comic.
    return ComicUpdateResult(false, 'Favorite source uses list update checks');
  }
  if (comicSource.loadComicInfo == null) {
    if (!canCommit()) return canceled();
    manager.markComicRetryLaterEverywhere(
      c.sourceKey,
      c.id,
      now: currentTime(),
    );
    return ComicUpdateResult(false, 'Comic source does not load details');
  }
  int retries = 3;
  while (true) {
    if (!canCommit()) return canceled();
    try {
      final info = await comicSource.loadComicInfo!(c.id).timeout(
        const Duration(seconds: 20),
      );
      if (!canCommit()) return canceled();
      return await onSuccess(info.data);
    } catch (e, s) {
      if (!canCommit()) return canceled();
      final message = e.toString();
      _logCheckError(message, e, s);
      final signal = classifyNotFoundError(message);
      if (signal != NotFoundSignal.none && sourceHealthy) {
        if (signal == NotFoundSignal.strong) {
          // A confirmed 404/410/delist response on a healthy source marks the
          // comic as suspected removed right away.
          if (!canCommit()) return canceled();
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
        if (!canCommit()) return canceled();
        final hits = manager.markComicNotFoundHitEverywhere(c.sourceKey, c.id);
        if (hits >= 3) {
          if (!canCommit()) return canceled();
          manager.markComicSuspectGoneEverywhere(c.sourceKey, c.id);
          return ComicUpdateResult(false, message);
        }
        final failures = c.checkFailures + 1;
        if (!canCommit()) return canceled();
        manager.markComicRetryLaterEverywhere(
          c.sourceKey,
          c.id,
          delay: retryDelayForFailures(failures),
          failures: failures,
          now: currentTime(),
        );
        return ComicUpdateResult(false, message);
      }
      await Future.delayed(kTransientRetryDelay);
      if (!canCommit()) return canceled();
      retries--;
      if (retries == 0) {
        final failures = c.checkFailures + 1;
        if (!canCommit()) return canceled();
        manager.markComicRetryLaterEverywhere(
          c.sourceKey,
          c.id,
          delay: retryDelayForFailures(failures),
          failures: failures,
          now: currentTime(),
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

bool hasPendingFollowUpdateWork({
  required FollowUpdateMode mode,
  Iterable<NetworkFavoriteFolderRef>? folders,
  DateTime? now,
}) {
  final manager = NetworkFavoriteCacheManager();
  final selected = (folders ?? getFollowUpdateFolders()).toList();
  if (selected.isEmpty) return false;
  final detailFolders = [
    for (final folder in selected)
      if (ComicSource.find(folder.sourceKey)?.favoriteData?.updateCheck == null)
        folder,
  ];
  if (detailFolders.isNotEmpty &&
      manager
          .getScanCandidates(
            detailFolders,
            modeName: mode.name,
            ignoreRetryAfter: false,
            includeSuspect: false,
            now: now,
          )
          .isNotEmpty) {
    return true;
  }
  return _buildFavoriteListScanJobs(
    manager,
    selected,
    mode,
    forceListSnapshots: false,
    ignoreRetryAfter: false,
    now: now ?? DateTime.now(),
  ).isNotEmpty;
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
    this.isBatchWork = false,
    this.currentLabel,
    this.containsBatchWork = false,
  });

  final bool isRunning;
  final int total;
  final int completed;
  final int errors;
  final int updated;
  final String? currentComic;
  final bool isBatchWork;
  final String? currentLabel;
  final bool containsBatchWork;
}

/// Selection rule used when checking a remote favorite folder.
enum FollowUpdateMode {
  /// Only comics that have never completed a check.
  missing,

  /// Comics with no check yet plus those whose persisted schedule is due.
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

class _FavoriteListScanJob {
  const _FavoriteListScanJob({required this.folder});

  final NetworkFavoriteFolderRef folder;
}

List<_FavoriteListScanJob> _buildFavoriteListScanJobs(
  NetworkFavoriteCacheManager manager,
  List<NetworkFavoriteFolderRef> folders,
  FollowUpdateMode mode, {
  required bool forceListSnapshots,
  required bool ignoreRetryAfter,
  required DateTime now,
}) {
  final jobs = <_FavoriteListScanJob>[];
  final seen = <String>{};
  for (final folder in folders) {
    final key = '${folder.sourceKey}\u0000${folder.folderId}';
    if (!seen.add(key)) continue;
    final data = ComicSource.find(folder.sourceKey)?.favoriteData;
    final updateCheck = data?.updateCheck;
    if (updateCheck == null) continue;
    final state = manager.getFavoriteUpdateScanState(folder);
    final retryReady =
        state?.retryAfter == null || !state!.retryAfter!.isAfter(now);
    final schemeChanged = state?.markerScheme != updateCheck.markerScheme;
    final due = forceListSnapshots || mode == FollowUpdateMode.force
        ? true
        : mode == FollowUpdateMode.missing
        ? state?.lastSuccessAt == null || schemeChanged
        : schemeChanged ||
              state?.lastSuccessAt == null ||
              !now.isBefore(
                state!.lastSuccessAt!.add(updateCheck.scanInterval),
              );
    if (due && (forceListSnapshots || ignoreRetryAfter || retryReady)) {
      jobs.add(_FavoriteListScanJob(folder: folder));
    }
  }
  return jobs;
}

Future<({bool success, bool canceled, int updated, String? error})>
_runFavoriteListScanJob(
  NetworkFavoriteCacheManager manager,
  _FavoriteListScanJob job, {
  required ScanCancellationToken token,
  required DateTime Function() clock,
  required int expectedEpoch,
}) async {
  if (!token.canCommit) {
    return (success: false, canceled: true, updated: 0, error: null);
  }
  if (!manager.tryAcquireFullCacheLock(job.folder)) {
    return (success: true, canceled: false, updated: 0, error: null);
  }
  try {
    final source = ComicSource.find(job.folder.sourceKey);
    final data = source?.favoriteData;
    final updateCheck = data?.updateCheck;
    if (source == null || data == null || updateCheck == null) {
      return (
        success: false,
        canceled: false,
        updated: 0,
        error: 'Favorite list update capability is unavailable',
      );
    }
    final attemptedAt = clock();
    manager.recordFavoriteUpdateScanAttempt(
      job.folder,
      attemptedAt: attemptedAt,
    );
    Res<FavoriteUpdateSnapshot> result;
    try {
      result = await updateCheck.load(job.folder.folderId);
    } catch (e, s) {
      Log.error('Favorite list update', e.toString(), s);
      if (!token.canCommit ||
          !manager.isFavoriteSessionEpochCurrent(
            job.folder.sourceKey,
            expectedEpoch,
          )) {
        return (success: false, canceled: true, updated: 0, error: null);
      }
      manager.recordFavoriteUpdateScanFailure(job.folder, failedAt: clock());
      return (success: false, canceled: false, updated: 0, error: e.toString());
    }
    if (!token.canCommit ||
        !manager.isFavoriteSessionEpochCurrent(
          job.folder.sourceKey,
          expectedEpoch,
        )) {
      return (success: false, canceled: true, updated: 0, error: null);
    }
    if (result.error) {
      manager.recordFavoriteUpdateScanFailure(job.folder, failedAt: clock());
      return (
        success: false,
        canceled: false,
        updated: 0,
        error: result.errorMessage,
      );
    }
    try {
      if (!token.canCommit ||
          !manager.isFavoriteSessionEpochCurrent(
            job.folder.sourceKey,
            expectedEpoch,
          )) {
        return (success: false, canceled: true, updated: 0, error: null);
      }
      final applied = manager.applyCompleteFavoriteUpdateSnapshot(
        data,
        job.folder,
        result.data,
        completedAt: clock(),
      );
      return (
        success: true,
        canceled: false,
        updated: applied.updatedComicCount,
        error: null,
      );
    } catch (e, s) {
      Log.error('Favorite list update', e.toString(), s);
      if (!token.canCommit ||
          !manager.isFavoriteSessionEpochCurrent(
            job.folder.sourceKey,
            expectedEpoch,
          )) {
        return (success: false, canceled: true, updated: 0, error: null);
      }
      manager.recordFavoriteUpdateScanFailure(job.folder, failedAt: clock());
      return (success: false, canceled: false, updated: 0, error: e.toString());
    }
  } finally {
    manager.releaseFullCacheLock(job.folder);
  }
}

Future<void> _runFavoriteListScanJobs(
  NetworkFavoriteCacheManager manager,
  List<_FavoriteListScanJob> jobs, {
  required ScanCancellationToken token,
  required DateTime Function() clock,
  required void Function(
    _FavoriteListScanJob job,
    ({bool success, bool canceled, int updated, String? error}) result,
  )
  onResult,
}) async {
  final grouped = <String, Queue<_FavoriteListScanJob>>{};
  for (final job in jobs) {
    grouped
        .putIfAbsent(job.folder.sourceKey, Queue<_FavoriteListScanJob>.new)
        .addLast(job);
  }
  final sourceKeys = grouped.keys.toList();
  final expectedEpochs = <String, int>{
    for (final sourceKey in sourceKeys)
      sourceKey: manager.captureFavoriteSessionEpoch(sourceKey),
  };
  var nextSource = 0;
  Future<void> worker() async {
    while (token.canCommit) {
      final index = nextSource++;
      if (index >= sourceKeys.length) return;
      final queue = grouped[sourceKeys[index]]!;
      while (queue.isNotEmpty && token.canCommit) {
        final job = queue.removeFirst();
        final result = await _runFavoriteListScanJob(
          manager,
          job,
          token: token,
          clock: clock,
          expectedEpoch: expectedEpochs[job.folder.sourceKey]!,
        );
        onResult(job, result);
        if (result.canceled) return;
      }
    }
  }

  await Future.wait([
    for (var i = 0; i < math.min(3, sourceKeys.length); i++) worker(),
  ]);
}

/// Builds the deduplicated candidate queue for one scan run.
///
/// The suspect skip, the [mode] window (missing: never checked only;
/// regular: never checked or due by the persisted schedule; force: all) and the
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
  required DateTime now,
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
    now: now,
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
  return _interleaveScanItemsBySource(items.values);
}

/// Interleaves source queues in first-seen order while preserving each
/// source's original item order. This keeps a blocked source from occupying
/// every worker before another source gets a chance to start.
List<_ScanItem> _interleaveScanItemsBySource(Iterable<_ScanItem> items) {
  final grouped = <String, Queue<_ScanItem>>{};
  for (final item in items) {
    grouped.putIfAbsent(item.sourceKey, Queue<_ScanItem>.new).addLast(item);
  }

  final result = <_ScanItem>[];
  while (grouped.isNotEmpty) {
    for (final sourceKey in grouped.keys.toList(growable: false)) {
      final queue = grouped[sourceKey]!;
      result.add(queue.removeFirst());
      if (queue.isEmpty) grouped.remove(sourceKey);
    }
  }
  return result;
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
  ScanCancellationToken? cancellationToken,
  bool ignoreRetryAfter = false,
  NetworkFavoriteCacheManager? cache,
  bool includeSuspect = false,
  bool forceListSnapshots = false,
  DateTime Function()? clock,
  Future<void> Function(Duration)? delay,
}) {
  var stream = StreamController<UpdateProgress>();
  final token = cancellationToken ?? _CallbackScanCancellationToken(isCanceled);
  unawaited(
    _runScan(
      folders,
      mode,
      stream,
      token: token,
      ignoreRetryAfter: ignoreRetryAfter,
      cache: cache,
      includeSuspect: includeSuspect,
      forceListSnapshots: forceListSnapshots,
      clock: clock ?? DateTime.now,
      delay: delay ?? _defaultFollowUpdateDelay,
    ),
  );
  return stream.stream;
}

Future<void> _runScan(
  List<NetworkFavoriteFolderRef> folders,
  FollowUpdateMode mode,
  StreamController<UpdateProgress> stream, {
  required ScanCancellationToken token,
  required DateTime Function() clock,
  required Future<void> Function(Duration) delay,
  bool ignoreRetryAfter = false,
  NetworkFavoriteCacheManager? cache,
  bool includeSuspect = false,
  bool forceListSnapshots = false,
}) async {
  final manager = cache ?? NetworkFavoriteCacheManager();
  var errors = 0;
  var updated = 0;
  var checked = 0;
  var current = 0;
  final healthySources = <String>{};
  // A successful list probe is independent evidence that the source is
  // available. This matters when every comic in the batch returns 404: no
  // detail check can establish health in that case.
  final probeHealthySources = <String>{};
  final sourceDegraded = <String>{};
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

  // Sources judged down from failure evidence (service-error accumulation or
  // a failed list probe). Unlike the ordinary consecutive-error trip, the
  // verdict is not undone by a later success in the same run: a single
  // success right after a dead probe must not re-trust the delist-looking
  // responses that preceded it. The next run re-evaluates from scratch.
  final hardDelistedSources = <String>{};

  // A source is healthy while it has at least one successful detail check or
  // probe in this run, has not tripped the bulk-delist detector and has no
  // accumulated service-class errors (timeouts/5xx are evidence the source
  // is flaky, so delist-looking responses are not trusted).
  bool sourceHealthy(String sourceKey) =>
      (healthySources.contains(sourceKey) ||
          probeHealthySources.contains(sourceKey)) &&
      !bulkDelistSources.contains(sourceKey) &&
      !hardDelistedSources.contains(sourceKey) &&
      !sourceDegraded.contains(sourceKey) &&
      (serviceErrorCounts[sourceKey] ?? 0) == 0;

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

  ScanRunInfo? run;
  try {
    // Candidate selection and this run's initial scheduling decisions share a
    // single captured instant, making injected-clock tests deterministic.
    final scanNow = clock();
    // Resume an interrupted (crash) run with its stored mode and cooldown
    // policy; otherwise start a fresh run.
    final previousRun = manager.getCurrentScanRun();
    final listMode = previousRun != null && previousRun.status == 'running'
        ? FollowUpdateMode.values.asNameMap()[previousRun.mode] ?? mode
        : mode;
    final listIgnoreRetryAfter =
        previousRun != null && previousRun.status == 'running'
        ? previousRun.ignoreRetryAfter
        : ignoreRetryAfter;
    final listJobs = _buildFavoriteListScanJobs(
      manager,
      folders,
      listMode,
      forceListSnapshots:
          forceListSnapshots || listMode == FollowUpdateMode.force,
      ignoreRetryAfter: listIgnoreRetryAfter,
      now: scanNow,
    );
    final List<_ScanItem> items;
    if (previousRun != null && previousRun.status == 'running') {
      final storedMode =
          FollowUpdateMode.values.asNameMap()[previousRun.mode] ?? mode;
      manager.markListStrategyScanItemsSkipped(
        previousRun.runId,
        folders
            .where(
              (folder) =>
                  ComicSource.find(
                    folder.sourceKey,
                  )?.favoriteData?.updateCheck !=
                  null,
            )
            .map((folder) => folder.sourceKey),
      );
      items = _buildScanItems(
        manager,
        folders,
        storedMode,
        ignoreRetryAfter: previousRun.ignoreRetryAfter,
        now: scanNow,
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
        now: scanNow,
        includeSuspect: includeSuspect,
      );
      run = manager.createScanRun(
        mode: mode.name,
        ignoreRetryAfter: ignoreRetryAfter,
        total: listJobs.length + items.length,
        items: [for (final item in items) (item.sourceKey, item.comicId)],
      );
    }
    final total = listJobs.length + items.length;
    // The final total is emitted once, before any work starts.
    stream.add(
      UpdateProgress(
        total,
        0,
        0,
        0,
        null,
        null,
        false,
        null,
        listJobs.isNotEmpty,
      ),
    );

    // Keep a stable non-null id for all worker closures. The nullable [run]
    // remains available to the finalizer so an initialization failure cannot
    // be replaced by a LateInitializationError.
    final initializedRun = run;
    final runId = initializedRun.runId;

    final threads =
        ((appdata.settings['followUpdateThreads'] as num?)?.toInt().clamp(
                  1,
                  16,
                ) ??
                _defaultFollowUpdateThreads)
            .toInt();
    final batchDelay =
        (appdata.settings['followUpdateBatchDelay'] as num?)?.toDouble() ?? 5;
    var nextIndex = 0;
    // One limiter per scan keeps the normal worker, probes and retry phase on
    // the same source bounded and rate-limited. Cross-generation writes are
    // isolated by the cancellation token; a canceled request may still
    // finish independently.
    final sourceLimiter = _SourceRequestLimiter(
      maxConcurrentPerSource: math.min(_maxConcurrentPerSource, threads),
      clock: clock,
      delay: delay,
    );
    Duration sourceInterval(String sourceKey) =>
        calculateFollowUpdateSourceInterval(
          batchDelay,
          slowMode: sourceSlowMode.contains(sourceKey),
        );

    // List-strategy work is one complete snapshot per folder. It is kept out
    // of scan_queue and runs before detail work; folders of the same source
    // are serial while up to three different sources can run in parallel.
    await _runFavoriteListScanJobs(
      manager,
      listJobs,
      token: token,
      clock: clock,
      onResult: (job, result) {
        if (result.canceled || !token.canCommit) return;
        current++;
        updated += result.updated;
        if (!result.success) errors++;
        stream.add(
          UpdateProgress(
            total,
            current,
            errors,
            updated,
            null,
            result.error,
            true,
            '${job.folder.sourceKey}/${job.folder.folderId}',
            listJobs.isNotEmpty,
          ),
        );
      },
    );
    if (!token.canCommit) return;

    Future<void> worker() async {
      while (true) {
        if (!token.canCommit) return;
        final i = nextIndex++;
        if (i >= items.length) return;
        final item = items[i];
        final folder = NetworkFavoriteFolderRef(
          sourceKey: item.sourceKey,
          folderId: item.representativeFolderId,
        );
        if (!token.canCommit) return;
        // Re-read the row so the persisted schedule and retry state are current.
        final fresh = manager.getComicUpdateInfo(
          item.sourceKey,
          item.comicId,
          item.representativeFolderId,
        );
        if (fresh == null) {
          if (!token.canCommit) return;
          manager.markScanItemDone(
            runId,
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
              () => sourceLimiter.run<bool?>(
                item.sourceKey,
                interval: () => sourceInterval(item.sourceKey),
                token: token,
                action: () => probeSourceAlive(item.sourceKey),
              ),
            );
            final alive = await probe;
            probingSources.remove(item.sourceKey);
            if (!token.canCommit) return;
            if (alive == false) {
              delistSource(item.sourceKey, reason: 're-probe failed');
            } else {
              probeHealthySources.add(item.sourceKey);
              probeWindowRequests.remove(item.sourceKey);
              probeWindowHits.remove(item.sourceKey);
            }
          }
        }
        final sourceKey = item.sourceKey;
        final ComicUpdateResult result;
        try {
          result =
              await sourceLimiter.run<ComicUpdateResult>(
                item.sourceKey,
                interval: () => sourceInterval(item.sourceKey),
                token: token,
                action: () => updateComic(
                  fresh,
                  folder,
                  cache: manager,
                  sourceHealthy: sourceHealthy(item.sourceKey),
                  cancellationToken: token,
                  clock: clock,
                ),
                onCompleted: (completed) {
                  if (completed.canceled) return;
                  final message = completed.errorMessage;
                  if (message != null) {
                    final signal = classifyNotFoundError(message);
                    if (signal != NotFoundSignal.none) {
                      notFoundRetries.add((comic: fresh, folder: folder));
                    }
                    sourceConsecutiveErrors[sourceKey] =
                        (sourceConsecutiveErrors[sourceKey] ?? 0) + 1;
                    if ((sourceConsecutiveErrors[sourceKey] ?? 0) >= 10) {
                      bulkDelistSources.add(sourceKey);
                      sourceSlowMode.add(sourceKey);
                    }
                    if (signal == NotFoundSignal.none) {
                      sourceDegraded.add(sourceKey);
                      serviceErrorCounts[sourceKey] =
                          (serviceErrorCounts[sourceKey] ?? 0) + 1;
                      if ((serviceErrorCounts[sourceKey] ?? 0) >=
                          kServiceErrorDelistThreshold) {
                        delistSource(
                          sourceKey,
                          reason:
                              '${serviceErrorCounts[sourceKey]} service errors',
                        );
                      }
                    }
                    if (signal != NotFoundSignal.none &&
                        manager.isComicSuspectGone(sourceKey, item.comicId)) {
                      sourceConfirmedHits[sourceKey] =
                          (sourceConfirmedHits[sourceKey] ?? 0) + 1;
                      markedThisRun.add((
                        sourceKey: sourceKey,
                        comicId: item.comicId,
                      ));
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
                  } else {
                    healthySources.add(sourceKey);
                    sourceConsecutiveErrors[sourceKey] = 0;
                    sourceConfirmedHits[sourceKey] = 0;
                    serviceErrorCounts[sourceKey] = 0;
                    sourceSlowMode.remove(sourceKey);
                    if (!hardDelistedSources.contains(sourceKey)) {
                      bulkDelistSources.remove(sourceKey);
                    }
                  }
                },
              ) ??
              ComicUpdateResult(false, null, canceled: true);
        } catch (e, s) {
          if (!token.canCommit) return;
          // Defensive: an unexpected exception must never kill the worker or
          // leave the item stuck. Back off by the accumulated failure count
          // like every other failure path.
          Log.error('Follow updates item', e, s);
          if (!token.canCommit) return;
          manager.markComicRetryLaterEverywhere(
            item.sourceKey,
            item.comicId,
            failures: fresh.checkFailures + 1,
            now: clock(),
          );
          manager.markScanItemDone(
            runId,
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
              false,
              null,
              listJobs.isNotEmpty,
            ),
          );
          continue;
        }
        if (result.canceled || !token.canCommit) return;
        current++;
        if (result.errorMessage != null) {
          final signal = classifyNotFoundError(result.errorMessage!);
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
                () => sourceLimiter.run<bool?>(
                  sourceKey,
                  interval: () => sourceInterval(sourceKey),
                  token: token,
                  action: () => probeSourceAlive(sourceKey),
                ),
              );
              final alive = await probe;
              probingSources.remove(sourceKey);
              if (!token.canCommit) return;
              if (alive == false) {
                delistSource(sourceKey, reason: 'probe failed');
              } else if (alive == true) {
                probeHealthySources.add(sourceKey);
                probeWindowRequests[sourceKey] = 0;
                probeWindowHits[sourceKey] = 0;
              }
            } else {
              probeWindowHits[sourceKey] = probeWindowHits[sourceKey]! + 1;
            }
          }
          errors++;
          manager.markScanItemDone(
            runId,
            item.sourceKey,
            item.comicId,
            result: signal == NotFoundSignal.none ? 'retry_later' : 'not_found',
            error: result.errorMessage,
          );
        } else {
          checked++;
          if (result.updated) updated++;
          manager.markScanItemDone(
            runId,
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
            false,
            null,
            listJobs.isNotEmpty,
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
    // resets the counters); another not-found remains in its retry window and
    // cannot accumulate repeatedly in one check cycle. Re-checks share the main
    // workers' rate limiter and run on a few concurrent workers instead of
    // serially.
    if (notFoundRetries.isNotEmpty && token.canCommit) {
      final retryThreads = math.min(3, threads);
      var retryIndex = 0;
      Future<void> retryWorker() async {
        while (true) {
          if (!token.canCommit) return;
          final i = retryIndex++;
          if (i >= notFoundRetries.length) return;
          final retry = notFoundRetries[i];
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
          final result =
              await sourceLimiter.run<ComicUpdateResult>(
                retry.comic.sourceKey,
                interval: () => sourceInterval(retry.comic.sourceKey),
                token: token,
                action: () => updateComic(
                  fresh,
                  retry.folder,
                  cache: manager,
                  sourceHealthy: sourceHealthy(retry.comic.sourceKey),
                  cancellationToken: token,
                  clock: clock,
                ),
              ) ??
              ComicUpdateResult(false, null, canceled: true);
          if (result.canceled || !token.canCommit) return;
          if (result.errorMessage == null) {
            checked++;
            if (result.updated) updated++;
            if (errors > 0) errors--;
          }
        }
      }

      await Future.wait([for (var i = 0; i < retryThreads; i++) retryWorker()]);
    }

    if (token.canCommit) {
      stream.add(
        UpdateProgress(
          total,
          current,
          errors,
          updated,
          null,
          null,
          false,
          null,
          listJobs.isNotEmpty,
        ),
      );
    }
  } catch (e, s) {
    // _runScan is intentionally started in the background. Surface failures
    // to the stream consumer instead of leaving them as unhandled zone errors.
    stream.addError(e, s);
  } finally {
    try {
      // The run always reaches a terminal state; a canceled run is not
      // resumed later (the normal filters re-select its pending items).
      if (run != null) {
        manager.updateScanRunStatus(
          run.runId,
          token.isCanceled ? 'canceled' : 'finished',
        );
      }
    } finally {
      if (checked > 0 && token.isCurrent) manager.notifyCacheChanged();
      await stream.close();
    }
  }
}

class FavoriteRecheckResult {
  const FavoriteRecheckResult({
    required this.succeeded,
    this.found,
    this.errorMessage,
  });

  final bool succeeded;
  final bool? found;
  final String? errorMessage;
}

Future<FavoriteRecheckResult> recheckFavoriteComicDetailed(
  String sourceKey,
  String comicId, {
  NetworkFavoriteCacheManager? cache,
}) async {
  final manager = cache ?? NetworkFavoriteCacheManager();
  final source = ComicSource.find(sourceKey);
  final updateCheck = source?.favoriteData?.updateCheck;
  if (updateCheck != null) {
    final known = manager.getKnownFolderIds(sourceKey, comicId);
    final folders = manager
        .getAllCachedFolders()
        .where((folder) => folder.sourceKey == sourceKey)
        .where((folder) => known.isEmpty || known.contains(folder.folderId))
        .toList();
    if (folders.isEmpty) {
      return const FavoriteRecheckResult(succeeded: false);
    }
    final folder = folders.first;
    if (!manager.tryAcquireFullCacheLock(folder)) {
      return const FavoriteRecheckResult(
        succeeded: false,
        errorMessage: 'A full favorite snapshot is already running',
      );
    }
    final expectedEpoch = manager.captureFavoriteSessionEpoch(sourceKey);
    try {
      manager.recordFavoriteUpdateScanAttempt(folder);
      final result = await updateCheck.load(folder.folderId);
      if (!manager.isFavoriteSessionEpochCurrent(sourceKey, expectedEpoch)) {
        return const FavoriteRecheckResult(
          succeeded: false,
          errorMessage: 'Favorite session changed',
        );
      }
      if (result.error) {
        manager.recordFavoriteUpdateScanFailure(folder);
        return FavoriteRecheckResult(
          succeeded: false,
          errorMessage: result.errorMessage,
        );
      }
      final found = result.data.comics.any((comic) => comic.id == comicId);
      if (!manager.isFavoriteSessionEpochCurrent(sourceKey, expectedEpoch)) {
        return const FavoriteRecheckResult(
          succeeded: false,
          errorMessage: 'Favorite session changed',
        );
      }
      manager.applyCompleteFavoriteUpdateSnapshot(
        source!.favoriteData!,
        folder,
        result.data,
        completedAt: DateTime.now(),
      );
      manager.notifyCacheChanged();
      return FavoriteRecheckResult(succeeded: true, found: found);
    } catch (e, s) {
      Log.error('Favorite list recheck', e.toString(), s);
      if (!manager.isFavoriteSessionEpochCurrent(sourceKey, expectedEpoch)) {
        return const FavoriteRecheckResult(
          succeeded: false,
          errorMessage: 'Favorite session changed',
        );
      }
      manager.recordFavoriteUpdateScanFailure(folder);
      return FavoriteRecheckResult(
        succeeded: false,
        errorMessage: e.toString(),
      );
    } finally {
      manager.releaseFullCacheLock(folder);
    }
  }
  final folderIds = manager.getKnownFolderIds(sourceKey, comicId);
  FavoriteItemWithUpdateInfo? itemToCheck;
  NetworkFavoriteFolderRef? folderToCheck;
  for (final folderId in folderIds) {
    final folder = NetworkFavoriteFolderRef(
      sourceKey: sourceKey,
      folderId: folderId,
    );
    final item = manager
        .getComicsWithUpdatesInfo(folder)
        .where((candidate) => candidate.id == comicId)
        .firstOrNull;
    if (item != null) {
      itemToCheck = item;
      folderToCheck = folder;
      break;
    }
  }
  var succeeded = false;
  if (itemToCheck != null && folderToCheck != null) {
    final result = await updateComic(
      itemToCheck,
      folderToCheck,
      cache: manager,
    );
    succeeded = result.errorMessage == null;
  }
  manager.notifyCacheChanged();
  return FavoriteRecheckResult(succeeded: succeeded, found: succeeded);
}

Future<bool> recheckFavoriteComic(
  String sourceKey,
  String comicId, {
  NetworkFavoriteCacheManager? cache,
}) async {
  final result = await recheckFavoriteComicDetailed(
    sourceKey,
    comicId,
    cache: cache,
  );
  return result.succeeded;
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
