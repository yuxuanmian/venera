import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/runtime_context.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates_service.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/scan/execution_guard.dart';
import 'package:venera/foundation/scan/full_scan_planner.dart';
import 'package:venera/foundation/scan/models.dart';
import 'package:venera/foundation/scan/scan_call_lease.dart';
import 'package:venera/foundation/scan/scan_debug_service.dart';
import 'package:venera/foundation/scan/scan_emission.dart';
import 'package:venera/foundation/scan/scan_executor.dart';
import 'package:venera/foundation/scan/scan_limits.dart';
import 'package:venera/foundation/scan/scan_log.dart';
import 'package:venera/foundation/scan/source_adapter.dart';
import 'package:venera/foundation/scan/target_provider.dart';
import 'package:venera/foundation/tracking/judgment_service.dart';
import 'package:venera/network/app_dio.dart';

import '../tracking/fakes.dart' as tracking_fakes;
import 'fakes.dart' as scan_fakes;

/// Contract L (007) end to end: the label really reaches the request line, the
/// two overviews really appear once per round, and nothing forbidden ever does.
///
/// The pure functions are covered by `scan_log_test.dart`; this file asserts the
/// **wiring** — that the executor attaches a label, that the JS engine passes it
/// as host-owned request metadata, and that the interceptor prints it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late bool previousMuted;

  setUp(() {
    previousMuted = Log.isMuted;
    Log.isMuted = false;
    Log.clear();
  });

  tearDown(() {
    Log.clear();
    Log.isMuted = previousMuted;
  });

  String logs() => Log.logs.map((item) => item.content).join('\n');

  /// A Dio wired the way the scan path wires it: the shipped interceptor, and a
  /// plain-text body so a test can put anything in it without JSON decoding.
  Dio scanDio(HttpClientAdapter adapter) =>
      Dio(
          BaseOptions(
            validateStatus: (_) => true,
            responseType: ResponseType.plain,
          ),
        )
        ..httpClientAdapter = adapter
        ..interceptors.add(MyLogInterceptor());

  // -------------------------------------------------------------------------
  // The executor writes the label (L4)
  // -------------------------------------------------------------------------

  group('the executor labels each call', () {
    test('a per-comic call carries the label the planner produced', () async {
      final source = scan_fakes.makeScanTestSource('label-source');
      final adapter = scan_fakes.FakeScanAdapter(
        sourceKey: source.key,
        comicLoader: (_, __) async => const {
          'observation': {
            'update': {'latestChapterId': 'ch-1'},
          },
        },
      );
      final leases = <ScanCallLease>[];
      final repository = scan_fakes.FakeScanResultRepository();
      final executor = ScanExecutor(
        repository: repository,
        onLeaseCreated: leases.add,
      );
      final work = ScanWorkSpec.comic(
        source: source,
        adapter: adapter,
        comicId: 'comic-1',
        logLabel: comicLabel(source.key, 'One Piece', 'comic-1'),
      ).toWork(_guard(source));

      await executor.execute(
        work,
        emit: (emission, context) => ScanEmissionConsumer(
          repository: repository,
        ).consume(emission, context),
      );

      expect(leases, hasLength(1));
      expect(leases.single.logLabel, 'label-source One Piece');
    });

    test('a per-comic call without a planned label still gets one', () async {
      final source = scan_fakes.makeScanTestSource('label-source');
      final adapter = scan_fakes.FakeScanAdapter(
        sourceKey: source.key,
        comicLoader: (_, __) async => const {
          'observation': {
            'update': {'latestChapterId': 'ch-1'},
          },
        },
      );
      final leases = <ScanCallLease>[];
      final repository = scan_fakes.FakeScanResultRepository();
      final executor = ScanExecutor(
        repository: repository,
        onLeaseCreated: leases.add,
      );
      final work = ScanWorkSpec.comic(
        source: source,
        adapter: adapter,
        comicId: 'comic-1234567890',
      ).toWork(_guard(source));

      await executor.execute(
        work,
        emit: (emission, context) => ScanEmissionConsumer(
          repository: repository,
        ).consume(emission, context),
      );

      // Falls back to the identity prefix rather than emitting an anonymous
      // line: "which source, which comic" stays answerable.
      expect(leases.single.logLabel, 'label-source comic-1234');
    });

    test('each collection page carries its own ordinal, from 1', () async {
      final source = scan_fakes.makeScanTestSource('collection-source');
      final adapter = scan_fakes.FakeScanAdapter(
        sourceKey: source.key,
        collectionLoader: (_, cursor, __) async => cursor == null
            ? const {
                'items': [
                  {
                    'comicId': 'a',
                    'observation': {
                      'update': {'latestChapterId': 'ch-1'},
                    },
                  },
                ],
                'next': 'page-2',
              }
            : const {
                'items': [
                  {
                    'comicId': 'b',
                    'observation': {'sourceUnread': true},
                  },
                ],
              },
      );
      final leases = <ScanCallLease>[];
      final repository = scan_fakes.FakeScanResultRepository();
      final executor = ScanExecutor(
        repository: repository,
        onLeaseCreated: leases.add,
      );
      final work = ScanWorkSpec.collection(
        source: source,
        adapter: adapter,
        collectionKey: 'default',
      ).toWork(_guard(source));

      await executor.execute(
        work,
        emit: (emission, context) => ScanEmissionConsumer(
          repository: repository,
        ).consume(emission, context),
      );

      expect(leases.map((lease) => lease.logLabel), [
        'collection-source p1',
        'collection-source p2',
      ]);
      // Data pages are not marked as re-checks; the verify marker exists so a
      // future re-check call cannot be confused with them (L4).
      for (final label in leases.map((lease) => lease.logLabel!)) {
        expect(label, isNot(contains('verify')));
      }
    });
  });

  // -------------------------------------------------------------------------
  // The interceptor prints it (L4, L6, L8)
  // -------------------------------------------------------------------------

  group('the scan log line carries the prefix', () {
    test('a labelled request prints "source + comic / page"', () async {
      final dio = scanDio(_RecordingAdapter(body: 'ok'));

      await dio.get<Object?>(
        'https://private.example.invalid/path',
        options: Options(
          extra: const {
            'veneraScan': true,
            'veneraScanContext': 'manwa One Piece',
          },
        ),
      );

      final output = logs();
      expect(output, contains('Scan manwa One Piece GET started'));
      expect(output, contains('Scan manwa One Piece GET status=200'));
    });

    test('an unlabelled request is unchanged', () async {
      final dio = scanDio(_RecordingAdapter(body: 'ok'));

      await dio.get<Object?>(
        'https://private.example.invalid/path',
        options: Options(extra: const {'veneraScan': true}),
      );

      final output = logs();
      expect(output, contains('Scan GET started'));
      expect(output, contains('Scan GET status=200'));
    });

    test('the error branch is prefixed too, and leaks nothing', () async {
      // The third branch is the one that matters most when a scan misbehaves, so
      // it gets its own assertion rather than riding on the success path.
      final dio = scanDio(_FailingAdapter());

      await expectLater(
        dio.get<Object?>(
          'https://private.example.invalid/path?token=query-secret',
          options: Options(
            headers: const {
              'authorization': 'Bearer header-secret',
              'cookie': 'session=cookie-secret',
            },
            extra: const {'veneraScan': true, 'veneraScanContext': 'manwa p3'},
          ),
        ),
        throwsA(isA<DioException>()),
      );

      final output = logs();
      expect(output, contains('manwa p3'));
      for (final secret in [
        'private.example.invalid',
        'query-secret',
        'header-secret',
        'cookie-secret',
      ]) {
        expect(output, isNot(contains(secret)));
      }
    });
  });

  // -------------------------------------------------------------------------
  // The JS engine passes the label as host-owned metadata (L7)
  // -------------------------------------------------------------------------

  test('the label travels in Dio extra, never in a header', () async {
    final adapter = _RecordingAdapter(body: 'remote-response');
    final dio = scanDio(adapter);
    final engine = JsEngine();
    engine.setDioForTesting(dio);
    final context = _publishedContext('host-appdio');
    final lease = ScanCallLease(
      guard: _keyGuard('host-appdio'),
      logLabel: 'host-app comic-1',
      timeout: const Duration(seconds: 1),
    );

    final result = await engine.requestForScan(
      {
        'method': 'GET',
        'url': 'https://host.example.invalid/scan',
        'headers': const {
          'authorization': 'Bearer header-secret',
          'cookie': 'session=cookie-secret',
        },
      },
      context,
      lease: lease,
      limits: const ScanLimits(requestTimeout: Duration(seconds: 1)),
    );
    lease.close();

    expect(result['ok'], isTrue);
    final request = adapter.requests.single;
    expect(request.extra['veneraScan'], isTrue);
    expect(request.extra['veneraScanContext'], 'host-app comic-1');
    // The extra map is Dio-local metadata, so the label cannot reach the wire.
    expect(request.headers.toString(), isNot(contains('host-app comic-1')));
    expect(request.headers.toString(), isNot(contains('veneraScanContext')));

    final output = logs();
    expect(output, contains('host-app comic-1'));
    for (final secret in [
      'host.example.invalid',
      'header-secret',
      'cookie-secret',
      'remote-response',
    ]) {
      expect(output, isNot(contains(secret)));
    }
  });

  // -------------------------------------------------------------------------
  // The plan overview (L1, L3, L8)
  // -------------------------------------------------------------------------

  group('the plan overview', () {
    test('is emitted once, in two constant lines, with skip classes', () async {
      final source = scan_fakes.makeScanTestSource(
        'plan-source',
        favoriteData: const FavoriteData(
          key: 'plan-source',
          title: 'Plan',
          multiFolder: false,
          loadComic: null,
          loadNext: null,
        ),
        scan: ScanCapabilities.supported(
          primary: ScanProducer.comic,
          comic: ScanCapability.comic((_, __) async => const {}),
        ),
      );
      final cache = _LabelCache(
        <NetworkFavoriteFolder>[_folder('plan-source', 'default')],
        {
          'default': ['a', 'b', 'c'],
        },
      );
      final provider = ScanTargetProvider(
        cache: cache,
        sources: () => [source],
        sourceEnabled: (_) => true,
        favoriteSettingReader: () => const ['plan-source'],
        adapterFactory: (s) => scan_fakes.FakeScanAdapter(sourceKey: s.key),
      );

      Log.clear();
      final snapshot = await provider.snapshot();
      final planLines = Log.logs
          .map((item) => item.content)
          .where((line) => line.startsWith('scan plan'))
          .toList();

      expect(planLines, hasLength(2));
      expect(planLines.first, contains('sources=1'));
      expect(planLines.first, contains('works=3/3'));
      expect(planLines.first, contains('plan-source comic x3'));
      expect(planLines[1], contains('total=0'));

      // The labels the planner produced use the cache entry's name.
      expect(snapshot.works.map((work) => work.logLabel).toList(), [
        'plan-source Comic a',
        'plan-source Comic b',
        'plan-source Comic c',
      ]);
    });

    test('a scoped round visits only its sources and says so (F1.4)', () async {
      ComicSource planSource(String key) => scan_fakes.makeScanTestSource(
        key,
        favoriteData: FavoriteData(
          key: key,
          title: key,
          multiFolder: false,
          loadComic: null,
          loadNext: null,
        ),
        scan: ScanCapabilities.supported(
          primary: ScanProducer.collection,
          collection: ScanCapability.collection((_, __, ___) async => const {}),
        ),
      );
      final cache = _LabelCache(
        <NetworkFavoriteFolder>[
          _folder('changed', 'default'),
          _folder('untouched', 'default'),
        ],
        {
          'default': ['a'],
        },
      );
      final provider = ScanTargetProvider(
        cache: cache,
        sources: () => [planSource('changed'), planSource('untouched')],
        sourceEnabled: (_) => true,
        favoriteSettingReader: () => const ['changed', 'untouched'],
        adapterFactory: (s) => scan_fakes.FakeScanAdapter(sourceKey: s.key),
      );

      Log.clear();
      final snapshot = await provider.snapshot(
        scopeSourceKeys: const {'changed'},
        roundLabel: 'cacheChanged',
      );

      // A second source's collection work is what the due rule cannot drop, so
      // being out of scope has to mean "never built", not "filtered later".
      expect(snapshot.works.map((work) => work.sourceKey).toSet(), {'changed'});
      final plan = Log.logs
          .map((item) => item.content)
          .firstWhere((line) => line.startsWith('scan plan:'));
      expect(plan, contains('trigger=cacheChanged'));
      expect(plan, contains('scope=changed'));
      expect(plan, isNot(contains('scope=changed,untouched')));

      // Out of scope is not a defect of the source: the skip classes stay for
      // the sources that really were skipped (L3).
      final skipped = Log.logs
          .map((item) => item.content)
          .firstWhere((line) => line.startsWith('scan plan skipped'));
      expect(skipped, contains('total=0'));
    });

    test('names the skipped sources by reason class', () async {
      final present = scan_fakes.makeScanTestSource(
        'present',
        favoriteData: const FavoriteData(
          key: 'present',
          title: 'Present',
          multiFolder: false,
          loadComic: null,
          loadNext: null,
        ),
        scan: ScanCapabilities.supported(
          primary: ScanProducer.comic,
          comic: ScanCapability.comic((_, __) async => const {}),
        ),
      );
      final absent = scan_fakes.makeScanTestSource('absent');
      final disabled = scan_fakes.makeScanTestSource(
        'disabled',
        favoriteData: const FavoriteData(
          key: 'disabled',
          title: 'Disabled',
          multiFolder: false,
          loadComic: null,
          loadNext: null,
        ),
        scan: ScanCapabilities.supported(
          primary: ScanProducer.comic,
          comic: ScanCapability.comic((_, __) async => const {}),
        ),
      );
      final provider = ScanTargetProvider(
        cache: _LabelCache(const [], const {}),
        sources: () => [present, absent, disabled],
        sourceEnabled: (key) => key != 'disabled',
        favoriteSettingReader: () => const ['present', 'absent', 'disabled'],
        adapterFactory: (s) => scan_fakes.FakeScanAdapter(sourceKey: s.key),
      );

      Log.clear();
      await provider.snapshot();
      final skipped = Log.logs
          .map((item) => item.content)
          .firstWhere((line) => line.startsWith('scan plan skipped'));

      expect(skipped, contains('absent=1'));
      expect(skipped, contains('absent: absent'));
      expect(skipped, contains('disabled=1'));
      expect(skipped, contains('disabled: disabled'));
      expect(skipped, contains('invalid=0'));
      expect(skipped, contains('notLoggedIn=0'));
      // The one source that can contribute is not in the skipped list.
      expect(skipped, isNot(contains('present')));
    });

    test('stays within three lines at 700 comics', () async {
      final source = scan_fakes.makeScanTestSource(
        'big-source',
        favoriteData: const FavoriteData(
          key: 'big-source',
          title: 'Big',
          multiFolder: false,
          loadComic: null,
          loadNext: null,
        ),
        scan: ScanCapabilities.supported(
          primary: ScanProducer.comic,
          comic: ScanCapability.comic((_, __) async => const {}),
        ),
      );
      final ids = [for (var i = 0; i < 700; i++) 'c$i'];
      final provider = ScanTargetProvider(
        cache: _LabelCache(
          <NetworkFavoriteFolder>[_folder('big-source', 'default')],
          {'default': ids},
        ),
        sources: () => [source],
        sourceEnabled: (_) => true,
        favoriteSettingReader: () => const ['big-source'],
        adapterFactory: (s) => scan_fakes.FakeScanAdapter(sourceKey: s.key),
      );

      Log.clear();
      final snapshot = await provider.snapshot();
      final planLines = Log.logs
          .map((item) => item.content)
          .where((line) => line.startsWith('scan plan'))
          .toList();

      expect(snapshot.works, hasLength(700));
      expect(
        planLines,
        hasLength(2),
        reason: 'the overview is constant-sized, not one line per comic',
      );
      expect(planLines.first, contains('works=700/700'));
    });

    test('reports the narrowing when the due rule drops work', () async {
      final source = scan_fakes.makeScanTestSource(
        'narrow-source',
        favoriteData: const FavoriteData(
          key: 'narrow-source',
          title: 'Narrow',
          multiFolder: false,
          loadComic: null,
          loadNext: null,
        ),
        scan: ScanCapabilities.supported(
          primary: ScanProducer.comic,
          comic: ScanCapability.comic((_, __) async => const {}),
        ),
      );
      final provider = ScanTargetProvider(
        cache: _LabelCache(
          <NetworkFavoriteFolder>[_folder('narrow-source', 'default')],
          {
            'default': ['a', 'b', 'c', 'd'],
          },
        ),
        sources: () => [source],
        sourceEnabled: (_) => true,
        favoriteSettingReader: () => const ['narrow-source'],
        adapterFactory: (s) => scan_fakes.FakeScanAdapter(sourceKey: s.key),
      );

      Log.clear();
      await provider.snapshot(
        dueComicIdsBySource: const {
          'narrow-source': {'a'},
        },
      );
      final line = Log.logs
          .map((item) => item.content)
          .firstWhere((entry) => entry.startsWith('scan plan:'));

      expect(line, contains('works=1/4'));
    });
  });

  // -------------------------------------------------------------------------
  // The settlement overview (L2, L8)
  // -------------------------------------------------------------------------

  test('a round settles with exactly one overview line', () async {
    final judgment = JudgmentService(
      repository: tracking_fakes.InMemoryJudgmentRepository(),
      scanRepository: tracking_fakes.InMemoryScanItemStore(),
      clock: () => DateTime.utc(2026, 9, 13),
    );
    final scan = _StubScanService();
    final coordinator = FollowUpdateCoordinator(
      followUpdatesEnabledReader: () => true,
      judgmentService: judgment,
      scanService: scan,
      scanRepository: tracking_fakes.InMemoryScanItemStore(),
      favoriteCache: NetworkFavoriteCacheManager.forTesting(),
      criterionSourceKeys: () => const <String>{},
      completeSourceKeys: () => const <String>{},
      clock: () => DateTime.utc(2026, 9, 13),
    );
    addTearDown(coordinator.dispose);

    Log.clear();
    await coordinator.runRound(FollowUpdateTrigger.manual);

    final settled = Log.logs
        .map((item) => item.content)
        .where((line) => line.startsWith('scan round settled'))
        .toList();
    expect(settled, hasLength(1));
    expect(settled.single, contains('discovered=7'));
    expect(settled.single, contains('succeeded=5'));
    expect(settled.single, contains('failed=1'));
    expect(settled.single, contains('canceled=1'));
    expect(settled.single, contains('persisted=5'));
    expect(settled.single, contains('elapsed='));
    expect(settled.single, contains('disposition=completed'));
    // The settlement is one line, so a round adds at most three overview lines
    // in total (two plan + one settlement) regardless of how much work it did.
    expect(
      Log.logs
          .map((item) => item.content)
          .where((line) => line.startsWith('scan '))
          .length,
      lessThanOrEqualTo(3),
    );
  });

  // -------------------------------------------------------------------------
  // The forbidden-content guard (L7)
  // -------------------------------------------------------------------------

  test('hostile names and values never reach the scan log lines', () async {
    final hostileNames = <String>[
      'https://evil.example/steal?token=secret-url-token',
      'evil.example.com',
      'cookie=secret-cookie-value',
      'authorization: Bearer secret-bearer-value',
      'line\nbreak secret-second-line',
      'control\u0000char secret-control',
      'x' * 400,
    ];
    final dio = scanDio(_RecordingAdapter(body: 'secret-body'));

    for (final name in hostileNames) {
      // The label is built the way the planner builds it: the hostile name goes
      // through `comicLabel`, which sanitizes it.
      final label = comicLabel('hostile', name, 'comic-1234567890');
      await dio.get<Object?>(
        'https://private.example.invalid/path?token=secret-query',
        options: Options(
          headers: const {
            'authorization': 'Bearer secret-header',
            'cookie': 'session=secret-cookie',
          },
          extra: {'veneraScan': true, 'veneraScanContext': label},
        ),
      );
    }

    final output = logs();
    for (final forbidden in [
      'evil.example',
      'private.example.invalid',
      'secret-url-token',
      'secret-cookie-value',
      'secret-bearer-value',
      'secret-second-line',
      'secret-control',
      'secret-body',
      'secret-query',
      'secret-header',
      'secret-cookie',
      '://',
      'Bearer',
      'cookie=',
      'authorization',
    ]) {
      expect(
        output,
        isNot(contains(forbidden)),
        reason: '"$forbidden" must never appear in a scan log line',
      );
    }
    // The hostile inputs were dropped, so the fallback identity is what the log
    // carries — a line that still answers "which comic".
    expect(output, contains('hostile comic-1234'));
    // And the structure is intact: one start line and one response line per
    // request, not one extra line per embedded newline.
    final lines = output
        .split('\n')
        .where((line) => line.contains('Scan '))
        .toList();
    expect(lines, hasLength(hostileNames.length * 2));
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({String? body})
    : bodyBytes = Uint8List.fromList(utf8.encode(body ?? ''));

  final Uint8List bodyBytes;
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromBytes(
      bodyBytes,
      200,
      headers: const {
        // A scan response body is source-defined text, not a JSON document; the
        // content type says so, which also keeps Dio from trying to decode a
        // deliberately hostile body.
        'content-type': ['text/plain'],
      },
    );
  }
}

/// An adapter whose transfer fails, so the interceptor's `onError` branch runs.
class _FailingAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      message: 'transport down',
    );
  }
}

NetworkFavoriteFolder _folder(String sourceKey, String folderId) =>
    NetworkFavoriteFolder(
      sourceKey: sourceKey,
      folderId: folderId,
      title: folderId,
      updatedAt: DateTime.utc(2026, 9, 10),
    );

/// A cache whose entries carry a **name distinct from the identity**, so a test
/// can prove the label uses the name rather than the id.
class _LabelCache extends NetworkFavoriteCacheManager {
  _LabelCache(this.folders, this.items) : super.forTesting();

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
            name: 'Comic $id',
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

/// A round-shaped round: no acquisition, a fixed summary.
///
/// The point is the **close-out**, which is where the settlement overview is
/// emitted; the acquisition itself is covered by the scan kernel's own tests.
class _StubScanService extends ScanDebugService {
  _StubScanService()
    : super(repository: tracking_fakes.InMemoryScanItemStore());

  @override
  Future<FullScanSummary> startFullScan({
    Map<String, Set<String>>? dueComicIdsBySource,
    Set<String>? scopeSourceKeys,
    String? roundLabel,
  }) async => FullScanSummary(
    disposition: FullScanDisposition.completed,
    progress: ScanProgress(
      discoveredWorks: 7,
      activeWorks: 0,
      succeededWorks: 5,
      failedWorks: 1,
      canceledWorks: 1,
      persistedItems: 5,
      phase: ScanProgressPhase.finished,
    ),
  );
}

ManagedSourceContext _publishedContext(String key) {
  final snapshot = CatalogSnapshot(
    manifest: CatalogSnapshotManifest(
      pointer: CatalogPointer(
        catalogId: 'owner/repo',
        revision: 'a' * 40,
        indexUrl:
            'https://raw.githubusercontent.com/owner/repo/${'a' * 40}/index.json',
      ),
      indexSha256: '0' * 64,
      files: const [],
    ),
    indexBytes: const [],
    index: CatalogIndex.fromJson([]),
    rootPath: Directory.systemTemp.path,
  );
  final context = ManagedSourceContext(snapshot: snapshot, sourceKey: key);
  context.publish();
  return context;
}

ScanExecutionGuard _guard(ComicSource source) => ScanExecutionGuard(
  sourceKey: source.key,
  sourceInstance: source,
  cacheGeneration: 0,
);

/// A guard for a source key that has no `ComicSource` behind it.
ScanExecutionGuard _keyGuard(String sourceKey) => ScanExecutionGuard(
  sourceKey: sourceKey,
  sourceInstance: Object(),
  cacheGeneration: 0,
);
