import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_update_schedule.dart';
import 'package:venera/foundation/follow_updates_service.dart';
import 'package:venera/foundation/schedule/schedule_service.dart';
import 'package:venera/foundation/schedule/schedule_state.dart';
import 'package:venera/foundation/schedule/sqlite_schedule_repository.dart';
import 'package:venera/foundation/scan/full_scan_planner.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_result_repository.dart';
import 'package:venera/foundation/scan/scan_service.dart';
import 'package:venera/foundation/scan/sqlite_scan_result_repository.dart';
import 'package:venera/foundation/scan/target_provider.dart';
import 'package:venera/foundation/tracking/judgment_event.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';
import 'package:venera/foundation/tracking/sqlite_judgment_repository.dart';

import '../scan_kernel/fakes.dart';

void main() {
  test(
    'restart recovers newer attempts and committed schedule inputs',
    () async {
      final temp = await Directory.systemTemp.createTemp('venera-014-restart-');
      final scanPath = '${temp.path}${Platform.pathSeparator}scan.db';
      final judgmentPath = '${temp.path}${Platform.pathSeparator}judgment.db';
      final schedulePath = '${temp.path}${Platform.pathSeparator}schedule.db';
      final now = DateTime.utc(2026, 9, 10, 12);
      final nowMs = now.millisecondsSinceEpoch;
      const sourceKey = 'src';
      const revision = 'rev-1';
      const schema = 'latestChapterId';
      var scanClock = now;

      var scanRepository = SqliteScanResultRepository(
        databasePath: scanPath,
        clock: () => scanClock,
      );
      var judgmentRepository = SqliteJudgmentRepository(
        databasePath: judgmentPath,
      );
      var scheduleRepository = SqliteScheduleRepository(
        databasePath: schedulePath,
      );
      try {
        await scanRepository.ensureOpen();
        await judgmentRepository.ensureOpen();
        await scheduleRepository.ensureOpen();

        Future<String> saveObservation(
          String comicId,
          String latest,
          DateTime observedAt, {
          bool? sourceUnread,
          bool finish = true,
        }) async {
          scanClock = observedAt;
          final scope = await scanRepository.beginScope(
            sourceKey: sourceKey,
            producer: ScanProducer.comic,
            scopeKey: comicId,
            definitionRevision: revision,
            scopeAttemptId: newScanUuidV4(),
          );
          final attemptId = scanUuidV5(
            scope.scopeAttemptId,
            '$sourceKey\u0000$comicId',
          );
          await scanRepository.saveItem(
            ScanIngestionContext(scope: scope),
            _item(
              scope: scope,
              comicId: comicId,
              attemptId: attemptId,
              revision: revision,
              schema: schema,
              latest: latest,
              observedAt: observedAt,
              sourceUnread: sourceUnread,
            ),
          );
          if (finish) {
            await scanRepository.finishScope(
              ScanIngestionContext(scope: scope),
              ScanScopeStatus.completed,
            );
          }
          return attemptId;
        }

        final pendingAAttempt = await saveObservation(
          'pending',
          'a',
          now.subtract(const Duration(days: 5)),
        );
        await saveObservation(
          'changed',
          'old',
          now.subtract(const Duration(days: 2)),
        );
        final stagingJudgment = JudgmentService(
          repository: judgmentRepository,
          scanRepository: scanRepository,
          clock: () => now,
        );
        await stagingJudgment.run();
        expect(
          judgmentRepository
              .readComicRecoveryInputs()['$sourceKey\u0000pending']
              ?.input
              .attemptId,
          pendingAAttempt,
        );

        final changedObservedAt = now.subtract(const Duration(hours: 2));
        await saveObservation('changed', 'new', changedObservedAt);
        await stagingJudgment.run();
        expect(
          await judgmentRepository.clearVisibleFlag(sourceKey, 'changed'),
          1,
        );
        expect(
          (await judgmentRepository.readFor(
            sourceKey,
            'changed',
          ))!.hasNewUpdate,
          isFalse,
        );

        await saveObservation(
          'unread',
          'mixed',
          now.subtract(const Duration(minutes: 30)),
          sourceUnread: true,
        );
        final pendingBAttempt = await saveObservation(
          'pending',
          'b',
          now.subtract(const Duration(hours: 1)),
          finish: false,
        );

        final oldNextAt = nowMs + const Duration(days: 30).inMilliseconds;
        await scheduleRepository.applyBatch([
          ScheduleState(
            sourceKey: sourceKey,
            comicId: 'pending',
            nextAtMs: nowMs - const Duration(days: 1).inMilliseconds,
            activityAtMs: nowMs - const Duration(days: 5).inMilliseconds,
          ),
          ScheduleState(
            sourceKey: sourceKey,
            comicId: 'changed',
            nextAtMs: oldNextAt,
            activityAtMs: nowMs - const Duration(days: 2).inMilliseconds,
          ),
          ScheduleState(
            sourceKey: sourceKey,
            comicId: 'unread',
            nextAtMs: oldNextAt,
            activityAtMs: nowMs - const Duration(minutes: 30).inMilliseconds,
          ),
          ScheduleState(
            sourceKey: sourceKey,
            comicId: 'due',
            nextAtMs: oldNextAt,
            activityAtMs: nowMs,
          ),
        ]);

        await scanRepository.close();
        await judgmentRepository.close();
        await scheduleRepository.close();

        scanRepository = SqliteScanResultRepository(
          databasePath: scanPath,
          clock: () => now,
        );
        judgmentRepository = SqliteJudgmentRepository(
          databasePath: judgmentPath,
        );
        scheduleRepository = SqliteScheduleRepository(
          databasePath: schedulePath,
        );
        await scanRepository.ensureOpen();
        final interrupted = await scanRepository.readLatestScope(
          sourceKey,
          ScanProducer.comic,
          'pending',
        );
        expect(interrupted!.status, ScanScopeStatus.interrupted);
        expect(interrupted.finishedAtMs, isNotNull);

        final source = makeScanTestSource(sourceKey);
        final loaded = <String>[];
        final adapter = FakeScanAdapter(
          sourceKey: sourceKey,
          definitionRevision: revision,
          evidenceSchema: schema,
          comicLoader: (comicId, lease) async {
            loaded.add(comicId);
            return const {
              'observation': {
                'update': {'latestChapterId': 'after-restart'},
              },
            };
          },
        );
        ScanWorkSpec work(String comicId) => ScanWorkSpec.comic(
          source: source,
          adapter: adapter,
          comicId: comicId,
          sourceSnapshot: ScanSourceSnapshot(managed: false),
        );
        final cache = _FixedIdsCache(const [
          'pending',
          'changed',
          'unread',
          'due',
        ]);
        final targetProvider = _FixedTargetProvider(
          cache,
          ScanTargetSnapshot(
            works: [
              work('pending'),
              work('changed'),
              work('unread'),
              work('due'),
            ],
            cacheGeneration: cache.cacheGeneration,
            skippedSources: const [],
          ),
        );
        final judgment = JudgmentService(
          repository: judgmentRepository,
          scanRepository: scanRepository,
          clock: () => now,
        );
        final schedule = ScheduleService(
          repository: scheduleRepository,
          events: judgment.events,
          clock: () => now,
        );
        final scan = PreparedScanService(
          repository: scanRepository,
          targetProvider: targetProvider,
        );
        final coordinator = FollowUpdateCoordinator(
          followUpdatesEnabledReader: () => true,
          judgmentService: judgment,
          scanService: scan,
          scheduleService: schedule,
          scanRepository: scanRepository,
          favoriteCache: cache,
          criterionSourceKeys: () => const {sourceKey},
          completeSourceKeys: () => const {sourceKey},
          clock: () => now,
          batchThreshold: 1000,
        )..attachScheduleService(schedule);
        final events = <JudgmentBatchEvent>[];
        final subscription = judgment.events.listen(events.add);

        expect(await coordinator.runRound(FollowUpdateTrigger.manual), isTrue);
        await pumpEventQueue();
        await judgment.withComicBatchLock(() async {});

        expect(loaded, ['due']);
        final pendingSchedule = await scheduleRepository.readByIdentity(
          sourceKey,
          'pending',
        );
        expect(pendingSchedule, isNotNull);
        expect(pendingSchedule!.nextAtMs, greaterThan(nowMs));

        final changedSchedule = await scheduleRepository.readByIdentity(
          sourceKey,
          'changed',
        );
        expect(
          changedSchedule!.autoHotUntilMs,
          changedObservedAt.millisecondsSinceEpoch +
              kFollowUpdateHotWindow.inMilliseconds,
        );
        expect(
          (await judgmentRepository.readFor(
            sourceKey,
            'changed',
          ))!.hasNewUpdate,
          isFalse,
        );

        final recoveredInputs = judgmentRepository.readComicRecoveryInputs();
        expect(
          recoveredInputs['$sourceKey\u0000pending']!.input.attemptId,
          pendingBAttempt,
        );
        expect(recoveredInputs.containsKey('$sourceKey\u0000unread'), isFalse);
        expect(events, isNotEmpty);
        expect(events.every((event) => event.rows.isNotEmpty), isTrue);
        final unreadEvent = events
            .expand((event) => event.rows)
            .singleWhere((row) => row.comicId == 'unread');
        expect(unreadEvent, isNot(isA<ComicScheduleInput>()));

        await subscription.cancel();
        await judgment.close();
        await scanRepository.close();
        await schedule.close();
        cache.dispose();
      } finally {
        try {
          await scanRepository.close();
          await judgmentRepository.close();
          await scheduleRepository.close();
        } catch (_) {}
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'recent Picacg startup skips network after recovery, while manual still scans',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'venera-016-recovery-',
      );
      final scanPath = '${temp.path}${Platform.pathSeparator}scan.db';
      final judgmentPath = '${temp.path}${Platform.pathSeparator}judgment.db';
      final schedulePath = '${temp.path}${Platform.pathSeparator}schedule.db';
      final now = DateTime.utc(2026, 11, 13, 12);
      const sourceKey = 'picacg';
      const currentRevision = '1.0.11';
      const oldRevision = '1.0.10';
      const collectionSchema = '{"chapterCount":"epsCount"}';
      const comicSchema = '{"updatedAt":"updated_at@day"}';
      var scanClock = now;

      var scanRepository = SqliteScanResultRepository(
        databasePath: scanPath,
        clock: () => scanClock,
      );
      var judgmentRepository = SqliteJudgmentRepository(
        databasePath: judgmentPath,
      );
      var scheduleRepository = SqliteScheduleRepository(
        databasePath: schedulePath,
      );
      try {
        await scanRepository.ensureOpen();
        await judgmentRepository.ensureOpen();
        await scheduleRepository.ensureOpen();
        final stagingJudgment = JudgmentService(
          repository: judgmentRepository,
          scanRepository: scanRepository,
          clock: () => now,
        );

        Future<String> saveComicObservation(
          String comicId,
          String updatedAt,
          DateTime observedAt,
        ) async {
          scanClock = observedAt;
          final scope = await scanRepository.beginScope(
            sourceKey: sourceKey,
            producer: ScanProducer.comic,
            scopeKey: comicId,
            definitionRevision: oldRevision,
            scopeAttemptId: newScanUuidV4(),
          );
          final attemptId = scanUuidV5(
            scope.scopeAttemptId,
            '$sourceKey\u0000$comicId',
          );
          await scanRepository.saveItem(
            ScanIngestionContext(scope: scope),
            _item(
              scope: scope,
              comicId: comicId,
              attemptId: attemptId,
              revision: oldRevision,
              schema: comicSchema,
              latest: updatedAt,
              observedAt: observedAt,
            ),
          );
          await scanRepository.finishScope(
            ScanIngestionContext(scope: scope),
            ScanScopeStatus.completed,
          );
          return attemptId;
        }

        Future<String> saveCollectionObservation(
          String comicId,
          int chapterCount,
          DateTime observedAt,
        ) async {
          scanClock = observedAt;
          final scope = await scanRepository.beginScope(
            sourceKey: sourceKey,
            producer: ScanProducer.collection,
            scopeKey: 'default',
            definitionRevision: currentRevision,
            scopeAttemptId: newScanUuidV4(),
          );
          final attemptId = scanUuidV5(
            scope.scopeAttemptId,
            '$sourceKey\u0000$comicId',
          );
          await scanRepository.saveItem(
            ScanIngestionContext(scope: scope),
            _collectionItem(
              scope: scope,
              comicId: comicId,
              attemptId: attemptId,
              revision: currentRevision,
              schema: collectionSchema,
              chapterCount: chapterCount,
              observedAt: observedAt,
            ),
          );
          await scanRepository.finishScope(
            ScanIngestionContext(scope: scope),
            ScanScopeStatus.completed,
          );
          return attemptId;
        }

        await saveComicObservation(
          'comic-pending',
          '2026-11-01',
          now.subtract(const Duration(days: 10)),
        );
        await stagingJudgment.run();
        await saveCollectionObservation(
          'collection-pending',
          5,
          now.subtract(const Duration(days: 5)),
        );
        await stagingJudgment.run();
        final collectionObservedAt = now.subtract(const Duration(hours: 1));
        final comicObservedAt = now.subtract(const Duration(hours: 2));
        await saveCollectionObservation(
          'collection-pending',
          6,
          collectionObservedAt,
        );
        await saveComicObservation(
          'comic-pending',
          '2026-11-13',
          comicObservedAt,
        );

        await scanRepository.close();
        await judgmentRepository.close();
        await scheduleRepository.close();
        scanRepository = SqliteScanResultRepository(
          databasePath: scanPath,
          clock: () => now,
        );
        judgmentRepository = SqliteJudgmentRepository(
          databasePath: judgmentPath,
        );
        scheduleRepository = SqliteScheduleRepository(
          databasePath: schedulePath,
        );
        await scanRepository.ensureOpen();

        final source = makeScanTestSource(sourceKey);
        final adapter = FakeScanAdapter(
          sourceKey: sourceKey,
          definitionRevision: currentRevision,
          collectionEvidenceSchema: collectionSchema,
          comicEvidenceSchema: comicSchema,
          allowCollectionItemFailures: true,
        );
        final work = ScanWorkSpec.collection(
          source: source,
          adapter: adapter,
          collectionKey: 'default',
          sourceSnapshot: ScanSourceSnapshot(managed: false),
        );
        final cache = _FixedMembershipCache(sourceKey, const {
          'collection-pending',
          'comic-pending',
        });
        final judgment = JudgmentService(
          repository: judgmentRepository,
          scanRepository: scanRepository,
          clock: () => now,
        );
        final schedule = ScheduleService(
          repository: scheduleRepository,
          events: judgment.events,
          clock: () => now,
        );
        final scan = _PreparedProbeScanService(
          repository: scanRepository,
          initial: ScanTargetSnapshot(
            works: [work],
            cacheGeneration: cache.cacheGeneration,
          ),
        );
        final coordinator = FollowUpdateCoordinator(
          followUpdatesEnabledReader: () => true,
          judgmentService: judgment,
          scanService: scan,
          scheduleService: schedule,
          scanRepository: scanRepository,
          favoriteCache: cache,
          criterionSourceKeys: () => const {sourceKey},
          completeSourceKeys: () => const {sourceKey},
          collectionItemFailuresSourceReader: (_) => true,
          clock: () => now,
          batchThreshold: 1000,
        )..attachScheduleService(schedule);

        await coordinator.onProcessStart();
        expect(scan.preparedWorks, isEmpty);
        final collectionSchedule = await scheduleRepository.readByIdentity(
          sourceKey,
          'collection-pending',
        );
        final comicSchedule = await scheduleRepository.readByIdentity(
          sourceKey,
          'comic-pending',
        );
        final collectionHotUntil =
            collectionObservedAt.millisecondsSinceEpoch +
            kFollowUpdateHotWindow.inMilliseconds;
        final comicHotUntil =
            comicObservedAt.millisecondsSinceEpoch +
            kFollowUpdateHotWindow.inMilliseconds;
        expect(collectionSchedule!.autoHotUntilMs, collectionHotUntil);
        expect(comicSchedule!.autoHotUntilMs, comicHotUntil);
        expect(
          judgmentRepository
              .readComicRecoveryInputs()['$sourceKey\u0000collection-pending']
              ?.input
              .attemptId,
          isNotNull,
        );

        expect(await coordinator.runRound(FollowUpdateTrigger.manual), isTrue);
        expect(scan.preparedWorks, [work]);

        Future<void> saveAttempt(
          ScanScopeStatus status,
          DateTime finishedAt,
        ) async {
          final scope = await scanRepository.beginScope(
            sourceKey: sourceKey,
            producer: ScanProducer.collection,
            scopeKey: 'default',
            definitionRevision: currentRevision,
          );
          await scanRepository.finishScope(
            ScanIngestionContext(scope: scope),
            status,
            finishedAt: finishedAt,
          );
        }

        await saveAttempt(ScanScopeStatus.failed, now);
        await coordinator.runRound(FollowUpdateTrigger.startup);
        expect(scan.preparedWorks, [work]);

        await saveAttempt(
          ScanScopeStatus.completed,
          now.subtract(const Duration(hours: 12)),
        );
        await coordinator.runRound(FollowUpdateTrigger.startup);
        expect(scan.preparedWorks, [work]);
        await coordinator.dispose();
        await schedule.close();
        await judgment.close();
        await scanRepository.close();
        scheduleRepository = SqliteScheduleRepository(
          databasePath: schedulePath,
        );
        await scheduleRepository.ensureOpen();
        expect(
          (await scheduleRepository.readByIdentity(
            sourceKey,
            'collection-pending',
          ))!.autoHotUntilMs,
          collectionHotUntil,
        );
        cache.dispose();
      } finally {
        try {
          await scanRepository.close();
          await judgmentRepository.close();
          await scheduleRepository.close();
        } catch (_) {}
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'recovery write failure defers the whole collection before retry',
    () async {
      final temp = await Directory.systemTemp.createTemp('venera-016-defer-');
      final scanPath = '${temp.path}${Platform.pathSeparator}scan.db';
      final judgmentPath = '${temp.path}${Platform.pathSeparator}judgment.db';
      final schedulePath = '${temp.path}${Platform.pathSeparator}schedule.db';
      final now = DateTime.utc(2026, 11, 13, 12);
      const sourceKey = 'picacg';
      const revision = '1.0.11';
      const schema = '{"chapterCount":"epsCount"}';
      final scanRepository = SqliteScanResultRepository(
        databasePath: scanPath,
        clock: () => now,
      );
      final judgmentRepository = SqliteJudgmentRepository(
        databasePath: judgmentPath,
      );
      final scheduleRepository = SqliteScheduleRepository(
        databasePath: schedulePath,
      );
      try {
        await scanRepository.ensureOpen();
        await judgmentRepository.ensureOpen();
        await scheduleRepository.ensureOpen();
        final scope = await scanRepository.beginScope(
          sourceKey: sourceKey,
          producer: ScanProducer.collection,
          scopeKey: 'default',
          definitionRevision: revision,
          scopeAttemptId: newScanUuidV4(),
        );
        await scanRepository.saveItem(
          ScanIngestionContext(scope: scope),
          _collectionItem(
            scope: scope,
            comicId: 'pending',
            attemptId: scanUuidV5(
              scope.scopeAttemptId,
              '$sourceKey\u0000pending',
            ),
            revision: revision,
            schema: schema,
            chapterCount: 1,
            observedAt: now,
          ),
        );
        await scanRepository.finishScope(
          ScanIngestionContext(scope: scope),
          ScanScopeStatus.completed,
        );

        scheduleRepository.database.execute('''
          CREATE TRIGGER fail_016_recovery
          BEFORE INSERT ON schedule_state
          BEGIN
            SELECT RAISE(ABORT, 'synthetic recovery failure');
          END
        ''');
        final source = makeScanTestSource(sourceKey);
        final adapter = FakeScanAdapter(
          sourceKey: sourceKey,
          definitionRevision: revision,
          collectionEvidenceSchema: schema,
          comicEvidenceSchema: '{"updatedAt":"updated_at@day"}',
          allowCollectionItemFailures: true,
        );
        final cache = _FixedMembershipCache(sourceKey, const {'pending'});
        final judgment = JudgmentService(
          repository: judgmentRepository,
          scanRepository: scanRepository,
          clock: () => now,
        );
        final schedule = ScheduleService(
          repository: scheduleRepository,
          events: judgment.events,
          clock: () => now,
        );
        final scan = _PreparedProbeScanService(
          repository: scanRepository,
          initial: ScanTargetSnapshot(
            works: [
              ScanWorkSpec.collection(
                source: source,
                adapter: adapter,
                collectionKey: 'default',
                sourceSnapshot: ScanSourceSnapshot(managed: false),
              ),
            ],
            cacheGeneration: 0,
          ),
        );
        final coordinator = FollowUpdateCoordinator(
          followUpdatesEnabledReader: () => true,
          judgmentService: judgment,
          scanService: scan,
          scheduleService: schedule,
          scanRepository: scanRepository,
          favoriteCache: cache,
          criterionSourceKeys: () => const {sourceKey},
          completeSourceKeys: () => const {sourceKey},
          collectionItemFailuresSourceReader: (_) => true,
          clock: () => now,
          batchThreshold: 1000,
        )..attachScheduleService(schedule);

        await coordinator.runRound(FollowUpdateTrigger.manual);
        expect(scan.preparedWorks, isEmpty);
        expect(
          await scheduleRepository.readByIdentity(sourceKey, 'pending'),
          isNull,
        );
        expect(
          judgmentRepository
              .readComicRecoveryInputs()['$sourceKey\u0000pending']
              ?.input
              .attemptId,
          isNotNull,
        );

        scheduleRepository.database.execute('DROP TRIGGER fail_016_recovery');
        await coordinator.runRound(FollowUpdateTrigger.manual);
        expect(scan.preparedWorks, hasLength(1));
        expect(
          (await scheduleRepository.readByIdentity(
            sourceKey,
            'pending',
          ))!.nextAtMs,
          greaterThan(now.millisecondsSinceEpoch),
        );
        cache.dispose();
      } finally {
        try {
          await scanRepository.close();
          await judgmentRepository.close();
          await scheduleRepository.close();
        } catch (_) {}
        await temp.delete(recursive: true);
      }
    },
  );
}

ScanItemResult _item({
  required ScanScopeHandle scope,
  required String comicId,
  required String attemptId,
  required String revision,
  required String schema,
  required String latest,
  required DateTime observedAt,
  bool? sourceUnread,
}) => ScanItemResult.observed(
  attemptId: attemptId,
  scopeAttemptId: scope.scopeAttemptId,
  sourceKey: scope.sourceKey,
  comicId: comicId,
  producer: scope.producer,
  definitionRevision: revision,
  observedAt: observedAt.toIso8601String(),
  evidenceSchema: schema,
  observation: ScanObservation(
    update: UpdateDescriptor(latestChapterId: latest),
    sourceUnread: sourceUnread,
  ),
);

ScanItemResult _collectionItem({
  required ScanScopeHandle scope,
  required String comicId,
  required String attemptId,
  required String revision,
  required String schema,
  required int chapterCount,
  required DateTime observedAt,
}) => ScanItemResult.observed(
  attemptId: attemptId,
  scopeAttemptId: scope.scopeAttemptId,
  sourceKey: scope.sourceKey,
  comicId: comicId,
  producer: scope.producer,
  definitionRevision: revision,
  observedAt: observedAt.toIso8601String(),
  evidenceSchema: schema,
  observation: ScanObservation(
    update: UpdateDescriptor(chapterCount: chapterCount),
  ),
);

class _FixedTargetProvider extends ScanTargetProvider {
  _FixedTargetProvider(NetworkFavoriteCacheManager cache, this.value)
    : super(cache: cache, sources: () => const []);

  final ScanTargetSnapshot value;

  @override
  Future<ScanTargetSnapshot> snapshot({
    Map<String, Set<String>>? dueComicIdsBySource,
    Set<String>? scopeSourceKeys,
    String? roundLabel,
  }) async => value;

  @override
  Future<ScanTargetSnapshot> snapshotForPreparation({
    Set<String>? scopeSourceKeys,
    String? roundLabel,
  }) async => value;
}

class _PreparedProbeScanService extends PreparedScanService {
  _PreparedProbeScanService({required super.repository, required this.initial});

  final ScanTargetSnapshot initial;
  List<ScanWorkSpec> preparedWorks = const [];

  @override
  Future<FullScanSummary> startPreparedFullScan({
    Map<String, Set<String>>? dueComicIdsBySource,
    Set<String>? scopeSourceKeys,
    String? roundLabel,
    required ScanPreparation prepareTargets,
  }) async {
    final prepared = await prepareTargets(initial, scopeSourceKeys);
    preparedWorks = prepared.works;
    return FullScanSummary(
      disposition: FullScanDisposition.completed,
      progress: ScanProgress(
        phase: ScanProgressPhase.finished,
        discoveredWorks: prepared.works.length,
        succeededWorks: prepared.works.length,
      ),
    );
  }
}

class _FixedIdsCache extends NetworkFavoriteCacheManager {
  _FixedIdsCache(this.ids) : super.forTesting();

  final List<String> ids;

  @override
  bool isFavoriteKnown(String sourceKey, String comicId) =>
      sourceKey == 'src' && ids.contains(comicId);

  @override
  List<NetworkFavoriteFolder> getAllCachedFolders() => [
    NetworkFavoriteFolder(
      sourceKey: 'src',
      folderId: 'default',
      title: 'default',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    ),
  ];

  @override
  int countCachedComicsInFolders(Iterable<NetworkFavoriteFolderRef> folders) =>
      ids.length;

  @override
  List<FavoriteItemWithUpdateInfo> getComicsWithUpdatesInfoPageInFolders(
    Iterable<NetworkFavoriteFolderRef> folders, {
    required int limit,
    required int offset,
  }) => [
    for (final id in ids.skip(offset).take(limit))
      FavoriteItemWithUpdateInfo(
        FavoriteItem(
          id: id,
          name: id,
          coverPath: '',
          author: '',
          sourceKeyValue: 'src',
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

class _FixedMembershipCache extends NetworkFavoriteCacheManager {
  _FixedMembershipCache(this.sourceKey, this.ids) : super.forTesting();

  final String sourceKey;
  final Set<String> ids;

  @override
  int get cacheGeneration => 0;

  @override
  bool isFavoriteKnown(String sourceKey, String comicId) =>
      sourceKey == this.sourceKey && ids.contains(comicId);

  @override
  Set<String> getFavoriteComicIds(String sourceKey) =>
      sourceKey == this.sourceKey ? Set<String>.of(ids) : const <String>{};
}
