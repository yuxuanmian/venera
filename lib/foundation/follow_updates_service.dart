import 'dart:async';

import 'package:flutter/foundation.dart';

import 'comic_source/comic_source.dart';
import 'favorites.dart';
import 'follow_updates.dart';
import 'log.dart';
import 'schedule/schedule_service.dart';
import 'schedule/sqlite_schedule_repository.dart';
import 'scan/due_filter.dart';
import 'scan/models.dart';
import 'scan/scan_debug_service.dart';
import 'scan/scan_result_repository.dart';
import 'scan/sqlite_scan_result_repository.dart';
import 'tracking/judgment_event.dart';
import 'tracking/follow_up_migration.dart';
import 'tracking/judgment_service.dart' as tracking;

/// The prefix marking the app-owned scan scope used for follow-up work.
///
/// Follow-up checks share the acquisition kernel with the Debug full scan; the
/// distinction is which targets are handed to it, not a second scanner.
const String kFollowUpdateScopePrefix = 'follow-up';

/// Why a round was requested.  Recorded for diagnostics and used by tests to
/// prove every trigger goes through one range rule.
enum FollowUpdateTrigger { startup, cacheChanged, manual }

/// The progress shown while a round runs (Contract F5).
///
/// Counted in **tasks**, not comics: one collection-type task covers many
/// comics whose number is unknown before the task runs, so comics cannot give a
/// denominator.  The registered distortion is ~1.4 percentage points at the
/// current mix of one collection source plus N per-comic sources.
@immutable
class FollowUpdateProgress {
  const FollowUpdateProgress({
    required this.discovered,
    required this.finished,
    required this.phase,
  });

  const FollowUpdateProgress.idle()
    : discovered = 0,
      finished = 0,
      phase = ScanProgressPhase.idle;

  /// The denominator.  Fixed once target discovery completes; it MUST NOT
  /// change while the round runs.
  final int discovered;

  /// The numerator: succeeded **plus failed plus canceled**.
  ///
  /// Counting only successes is the mistake Contract F5.2 names: any failure
  /// would pin progress below the end forever, which is worse than no progress
  /// bar at all.
  final int finished;

  final ScanProgressPhase phase;

  /// Whether the round has reached its completion boundary.
  ///
  /// Completion has two shapes: the whole **round** is over (`idle` /
  /// `finished`), or target discovery established that there is nothing to do
  /// (Contract F5.2's zero-discovered rule).
  ///
  /// The second shape requires discovery to have finished.  During
  /// `discovering` the denominator is not zero, it is **unknown**, and reading
  /// unknown as zero is what parked a running round at a full "0 / 0" bar from
  /// the moment it started.
  ///
  /// A scan whose every task has settled is deliberately still not complete
  /// while the phase is `running`: judgment and the settle pass come after, and
  /// Contract F5.3 makes "progress reached completion" mean the list already
  /// reflects this round.
  bool get isComplete => switch (phase) {
    ScanProgressPhase.idle || ScanProgressPhase.finished => true,
    ScanProgressPhase.running || ScanProgressPhase.canceling => discovered == 0,
    ScanProgressPhase.discovering => false,
  };

  /// The bar's value.
  ///
  /// Zero while discovery is in flight: there is no denominator yet, and a full
  /// bar there reads as "already done" for a round that has not started
  /// scanning.  A zero denominator *after* discovery is the opposite case —
  /// nothing to do — and reads 100% (Contract F5.2).
  double get fraction {
    if (discovered > 0) return (finished / discovered).clamp(0, 1);
    return phase == ScanProgressPhase.discovering ? 0 : 1;
  }

  /// Whether this frame marks the end of the work it belongs to.
  ///
  /// Only the coordinator's own end-of-round publish carries `finished`, and it
  /// is emitted after judgment and the settle pass — the moment the stores may
  /// hold something the list has not shown yet.  The per-task frames in between
  /// exist to move the bar, not to trigger a store read: the list's read joins
  /// the whole judgment table to the favorite cache, so doing it per task would
  /// make UI cost grow with the number of comics.
  ///
  /// It is not the only read trigger.  A read is also due whenever judgment
  /// commits a batch — FR-009 has the event consumed by the UI side as well —
  /// which is the signal that actually corresponds to content changing.
  bool get isRoundEnd => phase == ScanProgressPhase.finished;

  @override
  String toString() =>
      'FollowUpdateProgress($finished/$discovered ${phase.name})';
}

/// Whether a thrown object is "this store has not been opened yet".
///
/// Matched by name rather than by type: the type is not reachable by an `on`
/// clause from this library without a `dart:core` import that would shadow the
/// implicit one and hide `String`, `int` and friends.
///
/// Both names are needed.  Dart reports the type as `LateError` while its
/// message says `LateInitializationError`, so a check for either one alone
/// misses half the cases (this was found by printing the type, not by guessing).
bool _isUnopenedStore(Object error) {
  final name = error.runtimeType.toString();
  return error is StateError ||
      name == 'LateError' ||
      name == 'LateInitializationError';
}

/// The sources whose favorite caches are complete (Contract F2.2).
///
/// Public so the gate can be evaluated from the page without duplicating the
/// completeness rule.  [cache] lets a caller pass the manager it already uses,
/// so a test cannot accidentally read a different database than the one it
/// seeded.
Set<String> completeFavoriteCacheSourceKeys({
  NetworkFavoriteCacheManager? cache,
}) => _completeSourceKeysFromCache(cache);

/// The sources whose favorite caches are complete (Contract F2.2).
///
/// A source counts as complete when it has at least one cached folder and every
/// one of its cached folders carries the completeness mark that a finished
/// full-cache run writes.  "No folders at all" is deliberately **not** complete:
/// it is the brand-new-cache case the gate exists to catch.
///
/// Read straight from the existing cache; no new marker and no new table.
Set<String> _completeSourceKeysFromCache([
  NetworkFavoriteCacheManager? injected,
]) {
  final NetworkFavoriteCacheManager cache;
  final List<NetworkFavoriteFolderRef> folders;
  try {
    cache = injected ?? NetworkFavoriteCacheManager();
    folders = cache.getAllCachedFolders();
  } catch (error) {
    // Consulted before the favorites store opened: nothing is complete yet,
    // which is the correct answer for a gate whose whole purpose is to hold
    // results back until a cache has actually finished.
    if (!_isUnopenedStore(error)) rethrow;
    return const <String>{};
  }
  final bySource = <String, List<NetworkFavoriteFolderRef>>{};
  for (final folder in folders) {
    bySource.putIfAbsent(folder.sourceKey, () => []).add(folder);
  }
  final complete = <String>{};
  for (final entry in bySource.entries) {
    if (entry.value.isEmpty) continue;
    if (entry.value.every(
      (folder) => cache.getFullCacheStatus(folder).isComplete,
    )) {
      complete.add(entry.key);
    }
  }
  return complete;
}

/// The cache reader for a coordinator.
///
/// A top-level helper rather than an inline conditional in the initializer
/// list: keeping the closure out of the constructor removes a `?` followed by
/// parentheses that the parser reads as part of the class body.
NetworkFavoriteCacheManager Function() _favoriteCacheReaderFor(
  NetworkFavoriteCacheManager? injected,
) {
  if (injected != null) return () => injected;
  return NetworkFavoriteCacheManager.new;
}

/// The coordinator: the only object that knows acquisition, judgment and
/// schedule all exist.
///
/// This follows the precedent 005 set when it wired "scan finished -> judge" in
/// the composition layer rather than inside either service.  The three domains
/// stay mutually unaware: acquisition broadcasts when an observation lands,
/// judgment consumes that and publishes batch events, and the schedule consumes
/// those events and writes its own store.  None of them holds a reference to
/// another.
///
/// It also holds the only triggers (Contract F1).  All three of them go through
/// [runRound] and therefore through one range rule — there is deliberately no
/// "check everything now" path, because a manual button that ignored the
/// schedule would cost ~5 minutes of requests for a 700-comic library and
/// cancel out the reason the schedule exists.
class FollowUpdateCoordinator {
  FollowUpdateCoordinator({
    required tracking.JudgmentService judgmentService,
    ScanDebugService? scanService,
    ScheduleService? scheduleService,
    ScanResultRepository? scanRepository,
    NetworkFavoriteCacheManager? favoriteCache,
    Set<String> Function()? criterionSourceKeys,
    Set<String> Function()? completeSourceKeys,
    DateTime Function()? clock,
    this.batchThreshold = 50,
    this.cacheChangeDebounce = const Duration(seconds: 2),
  }) : _scanService = scanService ?? scanDebugService,
       _scheduleService = scheduleService,
       _scanRepository = scanRepository ?? scanResultRepository,
       _favoriteCacheReader = _favoriteCacheReaderFor(favoriteCache),
       _judgmentService = judgmentService,
       // The criterion set comes from configuration and is derived fresh each
       // time: the user can enable, disable or log out of a source while the
       // app runs, and a cached answer would keep the old gate.
       _criterionSourceKeys =
           criterionSourceKeys ?? (() => followUpdateSourceKeys().keys),
       _clock = clock ?? DateTime.now,
       // Derived from the same local value the reader field was built from, so
       // a test that injects a cache gets an identical completeness answer
       // without this needing to read another field from the initializer list.
       _completeSourceKeys =
           completeSourceKeys ??
           (() => _completeSourceKeysFromCache(
             _favoriteCacheReaderFor(favoriteCache)(),
           )) {
    // Live counts are mirrored from the acquisition service rather than
    // polled, so the numerator moves exactly when a task settles (F5.4).
    // Unlike the schedule and observation subscriptions this needs no explicit
    // attach step: the acquisition service is a hard dependency of the
    // coordinator, so there is no wiring that could be forgotten.
    _scanService.progress.addListener(_onScanProgressChanged);
  }

  final ScanDebugService _scanService;

  /// Null until [attachScheduleService] runs, which needs the judgment service
  /// to exist first.  Kept nullable rather than constructed here so importing
  /// this library does not force the tracking singletons to initialize.
  ScheduleService? _scheduleService;
  final ScanResultRepository _scanRepository;
  final tracking.JudgmentService _judgmentService;
  final Set<String> Function() _criterionSourceKeys;
  final DateTime Function() _clock;
  final Set<String> Function() _completeSourceKeys;

  /// How many newly persisted observations trigger a judgment pass.
  ///
  /// An implementation parameter, never semantics: changing it MUST NOT change
  /// any conclusion (Contract E2).
  final int batchThreshold;

  /// How long cache notifications are coalesced before one round is requested.
  ///
  /// Also an implementation parameter: the only requirement is that a burst
  /// becomes one trigger rather than hundreds.
  final Duration cacheChangeDebounce;

  NetworkFavoriteCacheManager get _cache => _favoriteCacheReader();
  final NetworkFavoriteCacheManager Function() _favoriteCacheReader;

  FollowUpdateProgress _progress = const FollowUpdateProgress.idle();
  final ValueNotifier<FollowUpdateProgress> _progressNotifier =
      ValueNotifier<FollowUpdateProgress>(const FollowUpdateProgress.idle());

  bool _roundRunning = false;
  bool _cacheRunning = false;
  bool _fullCacheCanceled = false;
  bool _favoritesJustCached = false;
  bool _startupTriggered = false;
  bool _disposed = false;
  bool _cacheListenerAttached = false;
  FollowUpdateTrigger? _activeTrigger;

  StreamSubscription<JudgmentBatchEvent>? _scheduleSubscription;
  StreamSubscription<ScanRepositoryEvent>? _observationSubscription;
  Timer? _debounce;
  int _observationsSinceJudgment = 0;

  /// Progress for the current (or last) round.
  ValueListenable<FollowUpdateProgress> get progress => _progressNotifier;

  /// Whether a round is in flight.  Drives the "already running" presentation
  /// instead of silently dropping a trigger (Contract F1.2).
  bool get isRunning => _roundRunning;

  /// Whether a full favorite cache is in flight (Contract F2.3).
  ///
  /// Distinct from [isRunning] because the two publish different progress: a
  /// cache unblocks the gate, a round fills the list.
  bool get isCachingFavorites => _cacheRunning;

  /// Whether a full cache finished since the page last acknowledged it.
  ///
  /// The transition signal for F2.3's "完整缓存完成后自动转入列表": the gate has
  /// just opened, so the page shows the refresh entry point once rather than
  /// leaving the user to guess that the list became available.  Consumed by
  /// [acknowledgeFavoritesCached] so the message does not reappear on every
  /// rebuild.
  bool get favoritesJustCached => _favoritesJustCached;

  /// Marks the post-cache transition as shown.
  void acknowledgeFavoritesCached() {
    if (!_favoritesJustCached) return;
    _favoritesJustCached = false;
    _publish(_progress);
  }

  /// Which trigger started the active round, or null when idle.
  FollowUpdateTrigger? get activeTrigger => _activeTrigger;

  /// The progress this coordinator last published, for tests and diagnostics.
  FollowUpdateProgress get currentProgress => _progress;

  /// Mirrors the acquisition service's live counts into the round's progress.
  ///
  /// Contract F5.4 requires the denominator to be fixed once target enumeration
  /// finishes and the numerator to move **as each task settles**.  The scan
  /// service already publishes exactly that; this is the wire that was missing.
  /// Without it the page only ever saw the round's two endpoints — "0 / 0" the
  /// moment it started and the totals once judgment had caught up — so a round
  /// that was in fact reporting every task looked stuck at zero for its whole
  /// duration.
  ///
  /// The scan's `finished` is reported as `running`: a finished **scan** is not
  /// a finished **round**, because judgment and the settle pass still follow,
  /// and Contract F5.3 makes completion mean the list already reflects this
  /// round.  Only [_runRoundOnce]'s own end-of-round publish claims completion.
  void _onScanProgressChanged() {
    if (!_roundRunning) return;
    final scan = _scanService.progress.value;
    _publish(
      FollowUpdateProgress(
        discovered: scan.discoveredWorks,
        finished: _finishedTasks(scan),
        phase: scan.phase == ScanProgressPhase.finished
            ? ScanProgressPhase.running
            : scan.phase,
      ),
    );
  }

  /// Begins consuming judgment batches to recompute schedules (Contract S3).
  ///
  /// Wiring the schedule to judgment here, rather than inside either service,
  /// is what keeps the domains unaware of each other.
  void attachScheduleService(ScheduleService scheduleService) {
    _scheduleService = scheduleService;
    _scheduleSubscription ??= _judgmentService.events.listen(
      scheduleService.recomputeFromEvent,
    );
  }

  /// Begins consuming newly persisted observations and cache changes.
  ///
  /// Two subscriptions, both on channels that **already exist** (Contract E1 /
  /// F1): the acquisition store's broadcast and the favorite cache's
  /// `ChangeNotifier`.  No new notification channel is created, and no timer is
  /// introduced for the batch trigger — it counts persisted items, which the
  /// acquisition side already publishes.
  ///
  /// Idempotent, and safe to call before the acquisition store is open: the
  /// broadcast simply carries nothing until it is.
  void attachObservationConsumer() {
    _observationSubscription ??= _scanRepository.events.listen((event) {
      // Only a persisted item is progress.  A scope event marks the end of a
      // range, so counting it would advance the threshold by one per range and
      // consume the remainder twice.
      if (event.item == null) return;
      unawaited(onObservationPersisted());
    });
    if (_cacheListenerAttached) return;
    _cacheListenerAttached = true;
    _cache.addListener(_onFavoriteCacheChanged);
  }

  /// Stops both subscriptions.  Safe to call more than once.
  void detachObservationConsumer() {
    unawaited(_observationSubscription?.cancel());
    _observationSubscription = null;
    _debounce?.cancel();
    _debounce = null;
    if (!_cacheListenerAttached) return;
    _cacheListenerAttached = false;
    _cache.removeListener(_onFavoriteCacheChanged);
  }

  /// Whether the incremental consumer is wired.  A regression test asserts this
  /// so a coordinator that never subscribed cannot pass by staying silent.
  @visibleForTesting
  bool get observationConsumerAttached => _observationSubscription != null;

  @visibleForTesting
  bool get cacheListenerAttached => _cacheListenerAttached;

  /// High-frequency cache notifications collapse into one trigger (FR-007).
  ///
  /// A full cache writes hundreds of pages and notifies on each; without this
  /// every one of them would request a round.  The round's own single-round
  /// lock would absorb the bursts, but only after each had been scheduled.
  void _onFavoriteCacheChanged() {
    if (_disposed) return;
    _debounce?.cancel();
    _debounce = Timer(cacheChangeDebounce, () {
      if (_disposed) return;
      unawaited(runRound(FollowUpdateTrigger.cacheChanged));
    });
  }

  /// Whether the schedule consumer is wired.  A regression test asserts this so
  /// a coordinator that never subscribed cannot pass by staying silent.
  @visibleForTesting
  bool get scheduleConsumerAttached => _scheduleSubscription != null;

  /// The session boundary for the startup trigger (Contract F1.1).
  ///
  /// The boundary is the **process**, so this fires at most once per process
  /// and a foreground resume is not a new start.  It is not a timer and not a
  /// lifecycle callback: only a fresh process triggers.
  Future<void> onProcessStart() async {
    if (_startupTriggered || _disposed) return;
    _startupTriggered = true;
    await runRound(FollowUpdateTrigger.startup);
  }

  /// Deliberately a no-op.
  ///
  /// Returning to the foreground is not a new session (Contract F1.1).  The
  /// method exists because the app lifecycle already calls it.
  void onAppResumed() {}

  /// Runs one round: due-filtered acquisition, then judgment, then settle.
  ///
  /// Returns true when a round was started, false when the request was
  /// absorbed.  An in-flight round absorbs the new request by **presenting the
  /// current round's state** — not by dropping it silently and not by queueing a
  /// second one (Contract F1.2).
  Future<bool> runRound(FollowUpdateTrigger trigger) async {
    if (_disposed) return false;
    if (_roundRunning) {
      _activeTrigger = trigger;
      return false;
    }
    _roundRunning = true;
    _activeTrigger = trigger;
    _publish(
      FollowUpdateProgress(
        discovered: 0,
        finished: 0,
        phase: ScanProgressPhase.discovering,
      ),
    );
    try {
      await _runRoundOnce();
      return true;
    } finally {
      _roundRunning = false;
      _activeTrigger = null;
    }
  }

  Future<void> _runRoundOnce() async {
    final nowMs = _clock().millisecondsSinceEpoch;
    await _scanRepository.ensureOpen();

    // ---- Due filtering (Contract S4) -------------------------------------
    //
    // The complete four-condition test needs both stores, so the due set is
    // computed here and the target snapshot is narrowed before the scan starts.
    // With nothing due this yields an empty work list and the round issues no
    // source request at all.
    final dueBySource = await _dueComicIdsBySource(nowMs);

    final summary = await _scanService.startFullScan(
      dueComicIdsBySource: dueBySource,
    );

    // ---- Settlement ------------------------------------------------------
    //
    // The fallback judgment pass is unconditional: batches fire on a count
    // threshold, so the remainder has to be consumed here or the tail of every
    // round is never judged (Contract E2).  It is also what makes "progress
    // reached completion" mean "judgment has caught up" (F5.3).
    try {
      await _judgmentService.run();
    } finally {
      _observationsSinceJudgment = 0;
    }

    _publish(
      FollowUpdateProgress(
        discovered: summary.progress.discoveredWorks,
        finished: _finishedTasks(summary.progress),
        phase: ScanProgressPhase.finished,
      ),
    );
  }

  /// The complete due set per source (Contract S4).
  ///
  /// Returns **null** to mean "do not filter at all" — the caller passes it
  /// straight to the acquisition side, where null selects the unfiltered
  /// target list.  This distinction is load-bearing: an *empty map* is not the
  /// same answer.  `filterTargetsByDue` treats a source missing from the map as
  /// "no identity of it is due", so an empty map drops every per-comic work and
  /// the round scans nothing while still reporting success.
  Future<Map<String, Set<String>>?> _dueComicIdsBySource(int nowMs) async {
    final schedule = _scheduleService;
    if (schedule == null) {
      // No schedule attached: every identity is due, because "no schedule
      // record" is itself a due condition.  That has to be expressed as **null**
      // (no filtering), not as an empty map — an empty map means "nothing is
      // due" and would silently stop all checks: the round would discover zero
      // works, report success, and leave the update list permanently empty with
      // no diagnostic pointing at the cause.
      return null;
    }
    final sources = _criterionSourceKeys();
    // An empty criterion set is a genuine "nothing is due": there is no source
    // we are tracking, so an empty map is the correct answer here (as opposed to
    // the null case above, where the domain is unknown rather than empty).
    if (sources.isEmpty) return const <String, Set<String>>{};

    final all = await _scanRepository.readAllItems();
    final observedBySource = <String, Set<String>>{};
    for (final item in all) {
      observedBySource
          .putIfAbsent(item.result.sourceKey, () => <String>{})
          .add(item.result.comicId);
    }

    final result = <String, Set<String>>{};
    for (final sourceKey in sources) {
      final observed = observedBySource[sourceKey] ?? const <String>{};
      final expired = await schedule.expiredIdentities(sourceKey, nowMs: nowMs);
      final scheduledFuture = await schedule.futureIdentities(
        sourceKey,
        nowMs: nowMs,
      );
      // The domain is everything we could ask the source about: what the cache
      // holds plus what was ever observed.  Taking it from observations alone
      // would skip comics whose first cache landing has not happened yet.
      final domain = <String>{...observed, ..._cachedComicIds(sourceKey)};
      result[sourceKey] = computeDueComicIds(
        allComicIds: domain,
        observedComicIds: observed,
        expiredComicIds: expired,
        futureScheduledComicIds: scheduledFuture,
      ).dueComicIds;
    }
    return result;
  }

  /// Comic ids the favorite cache holds for one source.
  ///
  /// Read-only projection of the existing cache.  When the cache has never been
  /// populated — or the manager has not opened its database yet, which is the
  /// state during startup — this is empty, and the domain falls back to
  /// whatever was already observed.  A round is therefore never blocked by a
  /// cache that is still filling, and never fails because it was consulted
  /// before the favorites store was ready.
  Set<String> _cachedComicIds(String sourceKey) {
    final NetworkFavoriteCacheManager cache;
    final List<NetworkFavoriteFolderRef> folders;
    try {
      cache = _cache;
      folders = cache
          .getAllCachedFolders()
          .where((folder) => folder.sourceKey == sourceKey)
          .toList();
      if (folders.isEmpty) return const <String>{};
    } catch (error) {
      // A `late final` store consulted before startup finished throws a
      // late-initialization error whose type an `on` clause cannot name here
      // without shadowing the implicit `dart:core` import.  Match it by name,
      // and refuse to swallow anything else -- a genuine defect must not look
      // like an empty cache.
      if (!_isUnopenedStore(error)) rethrow;
      return const <String>{};
    }
    final ids = <String>{};
    final count = cache.countCachedComicsInFolders(folders);
    for (var offset = 0; offset < count; offset += 256) {
      final page = cache.getComicsWithUpdatesInfoPageInFolders(
        folders,
        limit: 256,
        offset: offset,
      );
      if (page.isEmpty) break;
      for (final item in page) {
        ids.add(item.id);
      }
    }
    return ids;
  }

  /// Numerator = succeeded + failed + canceled (Contract F5.2).
  static int _finishedTasks(ScanProgress progress) =>
      progress.succeededWorks + progress.failedWorks + progress.canceledWorks;

  /// Consumes newly persisted observations and judges in batches (Contract E2).
  ///
  /// Triggered by the acquisition store's **existing** broadcast; no new
  /// notification channel is created.  The remainder is handled by the
  /// unconditional settle pass in [_runRoundOnce].
  Future<void> onObservationPersisted() async {
    _observationsSinceJudgment++;
    if (_observationsSinceJudgment < batchThreshold) return;
    _observationsSinceJudgment = 0;
    await _judgmentService.run();
  }

  /// Requests cancellation of the in-flight round.  Results already stored are
  /// kept (Contract F1.3).
  void cancel() => _scanService.cancel();

  /// Cancels an in-flight full-cache run.
  void cancelFullCache() => _fullCacheCanceled = true;

  /// Runs the full favorite cache for every criterion source's folders.
  ///
  /// This is the gate's trigger (Contract F2.3): it writes the completeness mark
  /// that lets the gate open, and it is the **user-driven** half of the
  /// two-step "clear, then rerun" flow — it never clears judgment, schedule or
  /// observation state.
  ///
  /// Returns false when a round is already running, so the caller can present
  /// the current round instead of silently starting a second one.
  bool startFullFavoriteCache() {
    if (_cacheRunning) return false;
    _cacheRunning = true;
    _fullCacheCanceled = false;
    unawaited(_runFullFavoriteCache());
    return true;
  }

  Future<void> _runFullFavoriteCache() async {
    _publish(
      FollowUpdateProgress(
        discovered: 0,
        finished: 0,
        phase: ScanProgressPhase.discovering,
      ),
    );
    // Declared outside the `try` so the `finally` block can report whether the
    // run reached the end: only a completed cache opens the gate, so only a
    // completed one may announce the transition.
    var done = 0;
    var folders = const <NetworkFavoriteFolderRef>[];
    try {
      final sources = _criterionSourceKeys();
      folders = _cache
          .getAllCachedFolders()
          .where((folder) => sources.contains(folder.sourceKey))
          .toList();
      _publish(
        FollowUpdateProgress(
          discovered: folders.length,
          finished: 0,
          phase: ScanProgressPhase.running,
        ),
      );
      for (final folder in folders) {
        if (_fullCacheCanceled) break;
        final data = ComicSource.find(folder.sourceKey)?.favoriteData;
        if (data == null) {
          done++;
          continue;
        }
        // Completed pages are retained, so a cancel or a later failure never
        // throws away the work already done.
        await _cache
            .cacheAllPages(data, folder, isCanceled: () => _fullCacheCanceled)
            .drain<void>();
        done++;
        _publish(
          FollowUpdateProgress(
            discovered: folders.length,
            finished: done,
            phase: ScanProgressPhase.running,
          ),
        );
      }
    } catch (_) {
      // A failed cache leaves the gate closed, which is the safe direction: the
      // mark was not written, so results stay hidden.
    } finally {
      _cacheRunning = false;
      // The transition signal, set only for a cache that actually ran to the
      // end: a canceled or failed one has not opened the gate, so announcing it
      // would promise a list that is still withheld.
      _favoritesJustCached = !_fullCacheCanceled && done == folders.length;
      _publish(
        FollowUpdateProgress(
          discovered: _progress.discovered,
          finished: _progress.discovered,
          phase: ScanProgressPhase.finished,
        ),
      );
    }
  }

  void _publish(FollowUpdateProgress value) {
    _progress = value;
    _progressNotifier.value = value;
  }

  /// The gate state, evaluated from configuration (Contract F2).
  ///
  /// The criterion set is the coordinator's own, so the sources the gate judges
  /// are exactly the sources the round scans.
  FollowUpdateGate evaluateGate() => evaluateFollowUpdateGate(
    completeSourceKeys: _completeSourceKeys(),
    criterionSourceKeys: _criterionSourceKeys(),
  );

  Future<void> dispose() async {
    _disposed = true;
    detachObservationConsumer();
    _scanService.progress.removeListener(_onScanProgressChanged);
    await _scheduleSubscription?.cancel();
    _scheduleSubscription = null;
    _progressNotifier.dispose();
  }
}

/// The product-owned follow-up coordinator.
///
/// Constructed eagerly on first use of this library.  That is safe: the
/// coordinator opens no database in its constructor and starts no work — it
/// only holds references and subscribes to the acquisition service's progress
/// notifier, and the scan repository it defaults to resolves `App.dataPath`
/// lazily (the same reason `SqliteScanResultRepository` is a top-level `final`
/// in its own file).
final followUpdateCoordinator = FollowUpdateCoordinator(
  judgmentService: tracking.judgmentService,
);

/// App-lifecycle facade over [followUpdateCoordinator].
///
/// The shape is kept from the retired scanner so `main.dart` and `init.dart`
/// need no change, but every entry now reaches the live coordinator rather than
/// doing nothing.  The scanners that used to live here are gone: there is one
/// acquisition kernel, driven by the coordinator with a due-filtered target set.
abstract class FollowUpdatesService {
  static Future<void>? _startup;

  /// Whether a full favorite cache is running (Contract F2.3).
  static bool get isCachingFavorites =>
      followUpdateCoordinator.isCachingFavorites;

  /// Task-based progress of the active round (Contract F5).
  ///
  /// The legacy `baselineStatus` view used to live here.  It is gone rather
  /// than kept alongside: two progress representations inevitably disagree, and
  /// the comic-counted one could not produce a denominator for a
  /// collection-type task in the first place.
  static ValueListenable<FollowUpdateProgress> get progress =>
      followUpdateCoordinator.progress;

  /// Whether a round is in flight.  A live value, not a stored flag.
  static bool get taskRunning => followUpdateCoordinator.isRunning;

  /// Requests cancellation of the active round; stored results are kept.
  static void cancelChecking() => followUpdateCoordinator.cancel();

  /// Runs one schedule-respecting round now (Contract F1).
  static Future<void> runCheckNow() =>
      followUpdateCoordinator.runRound(FollowUpdateTrigger.manual);

  /// Deliberately a no-op.
  ///
  /// Returning to the foreground is not a new session (Contract F1.1), so this
  /// must not start a round.  The method exists because `main.dart`'s lifecycle
  /// observer already calls it.
  static void onAppResumed() {}

  /// Starts consumption of judgment batches and triggers the startup round.
  ///
  /// Idempotent, and the session boundary is the process: a second call in the
  /// same process does nothing, so a foreground resume never re-triggers
  /// (Contract F1.1).
  ///
  /// Returns the in-flight startup round, or null when one already ran.  The
  /// returned future exists so callers that need the round to have finished
  /// (tests, and anything sequencing work after startup) can await it instead
  /// of racing it.
  static Future<void>? initChecker() {
    final pending = _startup;
    if (pending != null) return pending;
    final schedule = ScheduleService(
      repository: scheduleStateRepository,
      events: tracking.judgmentService.events,
    );
    followUpdateCoordinator.attachScheduleService(schedule);
    followUpdateCoordinator.attachObservationConsumer();
    // The upgrade path runs before the first round, so a round never judges
    // evidence while the user's existing flags are still in the old store
    // (FR-035/FR-036).  A failure is logged and retried on the next startup:
    // the marker is written inside the migrating transaction, so a partial run
    // cannot leave the migration half-applied.
    unawaited(
      FollowUpMigration(
        judgmentRepository: tracking.judgmentService.repository,
        scheduleRepository: scheduleStateRepository,
        source: () async =>
            NetworkFavoriteCacheManager().readLegacyFollowUpRows(),
      ).run().catchError((Object error) {
        Log.warning(
          'FollowUpMigration',
          'Legacy follow-up migration failed: $error',
        );
        return const FollowUpMigrationReport.skipped();
      }),
    );
    return _startup = followUpdateCoordinator.onProcessStart();
  }

  /// Forgets the startup trigger so a later [initChecker] may run one again.
  ///
  /// Does not dispose the product singleton's notifier: it outlives any single
  /// app shell, and disposing it would make a later re-init throw.
  static void disposeChecker() {
    followUpdateCoordinator.detachObservationConsumer();
    _startup = null;
  }
}
